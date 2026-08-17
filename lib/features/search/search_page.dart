import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../common/poster_card.dart';

final searchProvider =
    FutureProvider.family<List<BaseItem>, String>((ref, term) async {
  final client = ref.watch(embyClientProvider);
  if (client == null || term.trim().isEmpty) return const [];
  final page = await client.items(
    searchTerm: term.trim(),
    recursive: true,
    includeItemTypes: 'Movie,Series,Episode',
    limit: 60,
  );
  return page.items;
});

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _term = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// 输入防抖：每敲一个字就发请求会把服务端打满，等停顿 350ms 再查。
  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _term = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(embyClientProvider);
    final results = ref.watch(searchProvider(_term));
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: '搜索影片、剧集、单集',
            border: InputBorder.none,
          ),
          onChanged: _onChanged,
          onSubmitted: (value) => setState(() => _term = value),
        ),
      ),
      body: _term.trim().isEmpty
          ? const Center(child: Text('输入关键词开始搜索'))
          : results.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => ErrorRetry(
                error: error,
                onRetry: () => ref.invalidate(searchProvider(_term)),
              ),
              data: (items) => items.isEmpty
                  ? const Center(child: Text('没有匹配结果'))
                  : GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 160,
                        childAspectRatio: 0.52,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 16,
                      ),
                      itemCount: items.length,
                      itemBuilder: (_, index) => PosterCard(
                        item: items[index],
                        client: client!,
                        onTap: () => context.push('/detail/${items[index].id}'),
                      ),
                    ),
            ),
    );
  }
}
