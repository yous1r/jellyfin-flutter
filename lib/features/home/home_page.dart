import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/emby_api_client.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../common/poster_card.dart';

final viewsProvider = FutureProvider<List<LibraryView>>((ref) async {
  final client = ref.watch(embyClientProvider);
  if (client == null) return const [];
  return client.views();
});

final resumeProvider = FutureProvider<List<BaseItem>>((ref) async {
  final client = ref.watch(embyClientProvider);
  if (client == null) return const [];
  return (await client.resume()).items;
});

/// 每个媒体库的「最新入库」。family 的 key 是 ParentId。
final latestProvider =
    FutureProvider.family<List<BaseItem>, String>((ref, parentId) async {
  final client = ref.watch(embyClientProvider);
  if (client == null) return const [];
  return client.latest(parentId: parentId);
});

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(embyClientProvider);
    final views = ref.watch(viewsProvider);
    final resume = ref.watch(resumeProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Jellfin'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: '搜索',
            onPressed: () => context.push('/search'),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: '登出',
            onPressed: () => ref.read(authControllerProvider.notifier).logout(),
          ),
        ],
      ),
      body: client == null
          ? const SizedBox.shrink()
          : RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(viewsProvider);
                ref.invalidate(resumeProvider);
              },
              child: views.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (error, _) => ErrorRetry(
                  error: error,
                  onRetry: () => ref.invalidate(viewsProvider),
                ),
                data: (libraries) => ListView(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  children: [
                    resume.maybeWhen(
                      data: (items) => items.isEmpty
                          ? const SizedBox.shrink()
                          : _Row(
                              title: '继续观看',
                              items: items,
                              client: client,
                              wide: true,
                            ),
                      orElse: () => const SizedBox.shrink(),
                    ),
                    _Libraries(libraries: libraries),
                    for (final view in libraries)
                      _LatestRow(view: view, client: client),
                  ],
                ),
              ),
            ),
    );
  }
}

class _Libraries extends StatelessWidget {
  final List<LibraryView> libraries;

  const _Libraries({required this.libraries});

  @override
  Widget build(BuildContext context) {
    if (libraries.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final view in libraries)
            ActionChip(
              avatar: Icon(_iconFor(view.collectionType), size: 18),
              label: Text(view.name),
              onPressed: () => context.push(
                  '/library/${view.id}?title=${Uri.encodeComponent(view.name)}'),
            ),
        ],
      ),
    );
  }

  static IconData _iconFor(String collectionType) => switch (collectionType) {
        'movies' => Icons.movie_outlined,
        'tvshows' => Icons.live_tv_outlined,
        'music' => Icons.library_music_outlined,
        _ => Icons.folder_outlined,
      };
}

class _LatestRow extends ConsumerWidget {
  final LibraryView view;
  final EmbyApiClient client;

  const _LatestRow({required this.view, required this.client});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final latest = ref.watch(latestProvider(view.id));
    return latest.maybeWhen(
      data: (items) => items.isEmpty
          ? const SizedBox.shrink()
          : _Row(title: '最新 · ${view.name}', items: items, client: client),
      orElse: () => const SizedBox.shrink(),
    );
  }
}

/// 一条横向滚动的海报排。
class _Row extends StatelessWidget {
  final String title;
  final List<BaseItem> items;
  final EmbyApiClient client;
  final bool wide;

  const _Row({
    required this.title,
    required this.items,
    required this.client,
    this.wide = false,
  });

  @override
  Widget build(BuildContext context) {
    final cardWidth = wide ? 210.0 : 124.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
          child:
              Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        SizedBox(
          height: wide ? 172 : 232,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (_, index) {
              final item = items[index];
              return SizedBox(
                width: cardWidth,
                child: PosterCard(
                  item: item,
                  client: client,
                  wide: wide,
                  onTap: () => context.push('/detail/${item.id}'),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
