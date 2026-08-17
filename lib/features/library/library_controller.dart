import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/emby_api_client.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';

/// 海报墙分页状态。
class LibraryState {
  final List<BaseItem> items;
  final int total;
  final bool loading;
  final Object? error;

  const LibraryState({
    this.items = const [],
    this.total = 0,
    this.loading = false,
    this.error,
  });

  /// 已加载条数 < 总数时还有下一页。首次加载（total=0 且没数据）也算有。
  bool get hasMore => items.isEmpty ? error == null : items.length < total;

  LibraryState copyWith({
    List<BaseItem>? items,
    int? total,
    bool? loading,
    Object? error,
    bool clearError = false,
  }) =>
      LibraryState(
        items: items ?? this.items,
        total: total ?? this.total,
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
      );
}

/// 分页加载器：滚到底部调 [loadMore]，失败可 [retry]。
///
/// 关键约束：任一时刻只允许一个在途请求，否则快速滚动会重复拉同一页并插入重复条目。
class LibraryController extends StateNotifier<LibraryState> {
  final EmbyApiClient? _client;
  final String parentId;
  final int pageSize;

  /// 构造时就发起的首屏加载。单测 await 它以避免依赖固定延时。
  late final Future<void> initialLoad;

  LibraryController(this._client, this.parentId, {this.pageSize = 60})
      : super(const LibraryState()) {
    initialLoad = loadMore();
  }

  Future<void> loadMore() async {
    if (_client == null || state.loading || !state.hasMore) return;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final page = await _client.items(
        parentId: parentId,
        startIndex: state.items.length,
        limit: pageSize,
      );
      state = LibraryState(
        items: [...state.items, ...page.items],
        // 服务端偶尔不回 TotalRecordCount：用已加载数兜底，避免 hasMore 永真死循环。
        total: page.totalRecordCount > 0
            ? page.totalRecordCount
            : state.items.length + page.items.length,
        loading: false,
      );
    } catch (error) {
      state = state.copyWith(loading: false, error: error);
    }
  }

  /// 失败后重试当前页（保留已加载内容）。
  Future<void> retry() async {
    state = state.copyWith(clearError: true);
    await loadMore();
  }
}

final libraryControllerProvider = StateNotifierProvider.family<
    LibraryController, LibraryState, String>((ref, parentId) {
  return LibraryController(ref.watch(embyClientProvider), parentId);
});
