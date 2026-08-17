import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/providers.dart';
import '../../core/strm/strm_api_client.dart';
import 'media_kit_adapter.dart';
import 'playback_controller.dart';
import 'player_adapter.dart';

/// 播放页：画面 + 进度条 + 多视频流画质菜单。
class PlayerPage extends ConsumerStatefulWidget {
  final String itemId;
  final int startTicks;

  const PlayerPage({super.key, required this.itemId, this.startTicks = 0});

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  late final MediaKitAdapter _adapter;
  PlaybackController? _playback;

  @override
  void initState() {
    super.initState();
    // 沉浸播放：进入播放页即隐藏系统状态栏与导航栏，全屏观影。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _adapter = MediaKitAdapter();
    final emby = ref.read(embyClientProvider);
    if (emby != null) {
      _playback = PlaybackController(
        emby: emby,
        strm: ref.read(strmClientProvider),
        store: ref.read(sessionStoreProvider),
        adapter: _adapter,
        itemId: widget.itemId,
        startAt: Duration(microseconds: widget.startTicks ~/ 10),
      )..load();
    }
  }

  @override
  void dispose() {
    _playback?.dispose();
    // 离开播放页恢复系统 UI（状态栏 + 导航栏）。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playback = _playback;
    if (playback == null) return const Scaffold();

    return StreamBuilder<PlaybackState>(
      stream: playback.states,
      initialData: playback.state,
      builder: (context, snapshot) {
        final state = snapshot.data ?? playback.state;
        return Scaffold(
          backgroundColor: Colors.black,
          appBar: state.loading || (state.error != null && state.streams.isEmpty)
              ? AppBar(
                  backgroundColor: Colors.black,
                  title: Text(state.item?.name ?? '播放'),
                  actions: [
                    if (state.streams.length > 1)
                      _QualityMenu(state: state, onSelected: playback.switchTo),
                  ],
                )
              : null, // 播放中隐藏 AppBar，全屏沉浸
          extendBodyBehindAppBar: true,
          body: state.loading
              ? const Center(child: CircularProgressIndicator())
              : state.error != null && state.streams.isEmpty
                  ? _ErrorBody(
                      error: state.error!, onRetry: () => playback.load())
                  : _PlayerBody(
                      adapter: _adapter,
                      switching: state.switching,
                      error: state.error,
                      itemName: state.item?.name ?? '',
                      streams: state.streams,
                      currentResolution: state.currentResolution,
                      onSwitch: playback.switchTo,
                    ),
        );
      },
    );
  }
}

class _PlayerBody extends StatefulWidget {
  final MediaKitAdapter adapter;
  final bool switching;
  final Object? error;
  final String itemName;
  final List<PlaybackStream> streams;
  final String currentResolution;
  final ValueChanged<String> onSwitch;

  const _PlayerBody({
    required this.adapter,
    required this.switching,
    this.error,
    required this.itemName,
    required this.streams,
    required this.currentResolution,
    required this.onSwitch,
  });

  @override
  State<_PlayerBody> createState() => _PlayerBodyState();
}

class _PlayerBodyState extends State<_PlayerBody> {
  bool _controlsVisible = true;

  @override
  void initState() {
    super.initState();
    _scheduleAutoHide();
  }

  void _scheduleAutoHide() {
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        setState(() {
          _controlsVisible = !_controlsVisible;
        });
      },
      child: OrientationBuilder(
        builder: (context, orientation) {
          final isLandscape = orientation == Orientation.landscape;

          return Stack(
            fit: StackFit.expand,
            children: [
              // 视频画面：填满整个区域
              ValueListenableBuilder<VideoController?>(
                valueListenable: widget.adapter.controller,
                builder: (context, controller, _) {
                  // controller 尚未就位（adapter.open 还没执行完）时显示加载圈；
                  // duration 默认 Duration.zero（isFinite=true），不能用来判断就绪，
                  // 否则刚 open 即渲染 Video，无 surface 时画面卡黑。
                  if (controller == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return Video(
                    controller: controller,
                    controls: NoVideoControls,
                    fill: Colors.black,
                    fit: BoxFit.contain,
                  );
                },
              ),

              // 切换画质时的加载指示器
              if (widget.switching)
                const ColoredBox(
                  color: Colors.black54,
                  child: Center(child: CircularProgressIndicator()),
                ),

              // 错误提示条
              if (widget.error != null)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.9),
                    padding: const EdgeInsets.all(8),
                    child: Text('${widget.error}',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
                  ),
                ),

              // 覆盖层：标题 + 控制栏（点击切换显隐）
              AnimatedOpacity(
                opacity: _controlsVisible ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                child: Column(
                  children: [
                    // 顶部标题栏
                    SafeArea(
                      child: Padding(
                        padding: EdgeInsets.only(
                          top: isLandscape ? 4 : 8,
                          left: 8,
                          right: 8,
                        ),
                        child: Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.arrow_back, color: Colors.white),
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                            Expanded(
                              child: Text(
                                widget.itemName,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: isLandscape ? 14 : 16,
                                  fontWeight: FontWeight.w500,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (widget.streams.length > 1)
                              _QualityMenu(
                                state: PlaybackState(
                                  streams: widget.streams,
                                  currentResolution: widget.currentResolution,
                                ),
                                onSelected: widget.onSwitch,
                              ),
                          ],
                        ),
                      ),
                    ),

                    const Spacer(),

                    // 底部控制栏
                    SafeArea(
                      child: _Controls(
                        adapter: widget.adapter,
                        isLandscape: isLandscape,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  final MediaKitAdapter adapter;
  final bool isLandscape;

  const _Controls({required this.adapter, required this.isLandscape});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlayerAdapterState>(
      stream: adapter.states,
      initialData: adapter.state,
      builder: (context, snapshot) {
        final state = snapshot.data ?? const PlayerAdapterState();
        final total = state.duration.inMilliseconds;
        final position = state.position.inMilliseconds.clamp(0, total).toDouble();
        return Container(
          color: Colors.black.withValues(alpha: 0.6),
          padding: EdgeInsets.symmetric(
            horizontal: isLandscape ? 16 : 12,
            vertical: isLandscape ? 4 : 8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 进度条
              SliderTheme(
                data: SliderThemeData(
                  trackHeight: isLandscape ? 3.0 : 4.0,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                ),
                child: Slider(
                  value: total == 0 ? 0 : position,
                  max: total == 0 ? 1 : total.toDouble(),
                  onChanged: total == 0
                      ? null
                      : (value) =>
                          adapter.seek(Duration(milliseconds: value.round())),
                ),
              ),
              // 控制按钮 + 时间
              Padding(
                padding: EdgeInsets.symmetric(horizontal: isLandscape ? 8 : 4),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        state.playing ? Icons.pause : Icons.play_arrow,
                        color: Colors.white,
                      ),
                      onPressed: () =>
                          state.playing ? adapter.pause() : adapter.play(),
                    ),
                    Text(
                      '${_format(state.position)} / ${_format(state.duration)}',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const Spacer(),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static String _format(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

/// 画质菜单：每一路视频流一项，原画单独标注。
class _QualityMenu extends StatelessWidget {
  final PlaybackState state;
  final ValueChanged<String> onSelected;

  const _QualityMenu({required this.state, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '画质',
      icon: const Icon(Icons.high_quality_outlined, color: Colors.white),
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final stream in state.streams)
          PopupMenuItem(
            value: stream.resolution,
            child: Row(
              children: [
                Icon(
                  stream.resolution == state.currentResolution
                      ? Icons.check
                      : null,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(stream.displayName),
                if (stream.isOriginal) ...[
                  const SizedBox(width: 6),
                  const Icon(Icons.hd_outlined, size: 16),
                ],
                if (stream.resolutionLabel.isNotEmpty) ...[
                  const Spacer(),
                  Text(
                    stream.resolutionLabel,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _ErrorBody extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _ErrorBody({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text('$error', textAlign: TextAlign.center),
            ),
            const SizedBox(height: 14),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      );
}