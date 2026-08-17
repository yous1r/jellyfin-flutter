import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/api/emby_api_client.dart';
import '../../core/models/models.dart';

/// 海报卡片：首页横排、媒体库网格、搜索结果共用。
///
/// 没有 Primary 图（很多剧集只有缩略图）时退化成纯文字占位，避免一片破图。
class PosterCard extends StatelessWidget {
  final BaseItem item;
  final EmbyApiClient client;
  final VoidCallback onTap;

  /// 剧集用 16:9 缩略图，电影/剧集海报用 2:3。
  final bool wide;

  const PosterCard({
    super.key,
    required this.item,
    required this.client,
    required this.onTap,
    this.wide = false,
  });

  @override
  Widget build(BuildContext context) {
    final imageType = wide && item.imageTags.containsKey('Thumb')
        ? 'Thumb'
        : 'Primary';
    final tag = item.imageTags[imageType];
    final progress = item.userData.playedPercentage;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: wide ? 16 / 9 : 2 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (tag != null)
                    CachedNetworkImage(
                      imageUrl: client.imageUrl(item.id,
                          type: imageType, tag: tag, maxWidth: wide ? 480 : 360),
                      fit: BoxFit.cover,
                      placeholder: (_, __) => const _Placeholder(),
                      errorWidget: (_, __, ___) => _Fallback(name: item.name),
                    )
                  else
                    _Fallback(name: item.name),
                  // 继续观看进度条：直接画在海报底部，和 Emby 客户端一致。
                  if (progress > 0 && progress < 100)
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: LinearProgressIndicator(
                        value: progress / 100,
                        minHeight: 3,
                        backgroundColor: Colors.black45,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (item.subtitle.isNotEmpty)
            Text(
              item.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).hintColor,
                  ),
            ),
        ],
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) =>
      Container(color: Colors.white.withValues(alpha: 0.05));
}

class _Fallback extends StatelessWidget {
  final String name;

  const _Fallback({required this.name});

  @override
  Widget build(BuildContext context) => Container(
        color: Colors.white.withValues(alpha: 0.06),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(8),
        child: Text(
          name,
          textAlign: TextAlign.center,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
}

/// 居中的错误态 + 重试按钮，列表页共用。
class ErrorRetry extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const ErrorRetry({super.key, required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 40),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text('$error', textAlign: TextAlign.center),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      );
}
