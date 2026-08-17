import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../common/poster_card.dart';
import 'library_controller.dart';

/// 媒体库海报墙：响应式网格 + 触底加载下一页。
class LibraryPage extends ConsumerWidget {
  final String parentId;
  final String title;

  const LibraryPage({super.key, required this.parentId, required this.title});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(embyClientProvider);
    final state = ref.watch(libraryControllerProvider(parentId));
    final controller = ref.read(libraryControllerProvider(parentId).notifier);

    if (client == null) return const Scaffold();

    if (state.items.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: state.error != null
            ? ErrorRetry(error: state.error!, onRetry: controller.retry)
            : const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text('$title（${state.total}）')),
      body: NotificationListener<ScrollNotification>(
        // 距底部 600px 就预取下一页，滚动不会卡在加载圈上。
        onNotification: (notification) {
          final metrics = notification.metrics;
          if (metrics.pixels >= metrics.maxScrollExtent - 600) {
            controller.loadMore();
          }
          return false;
        },
        child: GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 160,
            childAspectRatio: 0.52,
            crossAxisSpacing: 12,
            mainAxisSpacing: 16,
          ),
          itemCount: state.items.length + (state.loading ? 1 : 0),
          itemBuilder: (_, index) {
            if (index >= state.items.length) {
              return const Center(child: CircularProgressIndicator());
            }
            final item = state.items[index];
            return PosterCard(
              item: item,
              client: client,
              onTap: () => context.push('/detail/${item.id}'),
            );
          },
        ),
      ),
      bottomNavigationBar: state.error == null
          ? null
          : Material(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                title: const Text('加载下一页失败'),
                trailing: TextButton(
                  onPressed: controller.retry,
                  child: const Text('重试'),
                ),
              ),
            ),
    );
  }
}
