import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../common/poster_card.dart';

final itemDetailProvider =
    FutureProvider.family<BaseItem, String>((ref, itemId) async {
  final client = ref.watch(embyClientProvider);
  if (client == null) throw StateError('未登录');
  return client.itemDetail(itemId);
});

final seasonsProvider =
    FutureProvider.family<List<BaseItem>, String>((ref, seriesId) async {
  final client = ref.watch(embyClientProvider);
  if (client == null) return const [];
  return (await client.seasons(seriesId)).items;
});

/// key = "seriesId/seasonId"（family 需要可比较的简单 key）。
final episodesProvider =
    FutureProvider.family<List<BaseItem>, String>((ref, key) async {
  final client = ref.watch(embyClientProvider);
  if (client == null) return const [];
  final parts = key.split('/');
  return (await client.episodes(parts[0], parts[1])).items;
});

class DetailPage extends ConsumerWidget {
  final String itemId;

  const DetailPage({super.key, required this.itemId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(itemDetailProvider(itemId));
    return Scaffold(
      appBar: AppBar(title: Text(detail.valueOrNull?.name ?? '详情')),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ErrorRetry(
          error: error,
          onRetry: () => ref.invalidate(itemDetailProvider(itemId)),
        ),
        data: (item) => item.type == 'Series'
            ? _SeriesBody(series: item)
            : _MovieBody(item: item),
      ),
    );
  }
}

/// 电影 / 单集：背景图 + 简介 + 播放按钮。
class _MovieBody extends ConsumerWidget {
  final BaseItem item;

  const _MovieBody({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(embyClientProvider)!;
    final backdropTag = item.imageTags['Backdrop'] ?? item.imageTags['Primary'];
    return ListView(
      children: [
        if (backdropTag != null)
          AspectRatio(
            aspectRatio: 16 / 9,
            child: CachedNetworkImage(
              imageUrl: client.imageUrl(item.id,
                  type: item.imageTags.containsKey('Backdrop')
                      ? 'Backdrop'
                      : 'Primary',
                  tag: backdropTag,
                  maxWidth: 1280),
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.name,
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 6),
              Text(
                [
                  if (item.subtitle.isNotEmpty) item.subtitle,
                  if (item.runtime.inMinutes > 0) '${item.runtime.inMinutes} 分钟',
                ].join(' · '),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  FilledButton.icon(
                    icon: const Icon(Icons.play_arrow),
                    label: Text(item.canResume ? '继续观看' : '播放'),
                    onPressed: () => context.push(
                      '/player/${item.id}'
                      '?ticks=${item.canResume ? item.userData.playbackPositionTicks : 0}',
                    ),
                  ),
                  if (item.canResume) ...[
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('从头播放'),
                      onPressed: () => context.push('/player/${item.id}'),
                    ),
                  ],
                ],
              ),
              if (item.overview.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text('简介', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 6),
                Text(item.overview,
                    style: Theme.of(context).textTheme.bodyMedium),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 剧集：季下拉 + 集列表。
class _SeriesBody extends ConsumerStatefulWidget {
  final BaseItem series;

  const _SeriesBody({required this.series});

  @override
  ConsumerState<_SeriesBody> createState() => _SeriesBodyState();
}

class _SeriesBodyState extends ConsumerState<_SeriesBody> {
  String? _seasonId;

  @override
  Widget build(BuildContext context) {
    final seasons = ref.watch(seasonsProvider(widget.series.id));
    return seasons.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => ErrorRetry(
        error: error,
        onRetry: () => ref.invalidate(seasonsProvider(widget.series.id)),
      ),
      data: (list) {
        if (list.isEmpty) return const Center(child: Text('没有季信息'));
        final seasonId = _seasonId ?? list.first.id;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.series.overview.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Text(widget.series.overview,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: DropdownButtonFormField<String>(
                initialValue: seasonId,
                decoration: const InputDecoration(labelText: '季'),
                items: [
                  for (final season in list)
                    DropdownMenuItem(
                        value: season.id, child: Text(season.name)),
                ],
                onChanged: (value) => setState(() => _seasonId = value),
              ),
            ),
            Expanded(
              child: _EpisodeList(
                  seriesId: widget.series.id, seasonId: seasonId),
            ),
          ],
        );
      },
    );
  }
}

class _EpisodeList extends ConsumerWidget {
  final String seriesId;
  final String seasonId;

  const _EpisodeList({required this.seriesId, required this.seasonId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = '$seriesId/$seasonId';
    final episodes = ref.watch(episodesProvider(key));
    final client = ref.watch(embyClientProvider);
    return episodes.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => ErrorRetry(
        error: error,
        onRetry: () => ref.invalidate(episodesProvider(key)),
      ),
      data: (list) => ListView.separated(
        itemCount: list.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, index) {
          final episode = list[index];
          final tag = episode.imageTags['Primary'];
          return ListTile(
            leading: SizedBox(
              width: 96,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: tag != null && client != null
                    ? CachedNetworkImage(
                        imageUrl: client.imageUrl(episode.id,
                            tag: tag, maxWidth: 240),
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => const ColoredBox(
                            color: Colors.white10, child: SizedBox()),
                      )
                    : const ColoredBox(
                        color: Colors.white10, child: SizedBox()),
              ),
            ),
            title: Text(
              episode.indexNumber != null
                  ? '${episode.indexNumber}. ${episode.name}'
                  : episode.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: episode.overview.isEmpty
                ? null
                : Text(episode.overview,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
            onTap: () => context.push(
              '/player/${episode.id}'
              '?ticks=${episode.canResume ? episode.userData.playbackPositionTicks : 0}',
            ),
          );
        },
      ),
    );
  }
}
