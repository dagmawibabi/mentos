import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../core/format.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/tokens.dart';
import '../data/models.dart';
import '../state/providers.dart';
import 'ui.dart';

/// Loads a decrypted file for [media] belonging to [item].
class MediaLoader extends ConsumerStatefulWidget {
  const MediaLoader({super.key, required this.media, required this.item, required this.builder, this.placeholder});
  final MediaRef media;
  final Item item;
  final Widget Function(BuildContext, File) builder;
  final Widget Function(BuildContext, bool failed)? placeholder;

  @override
  ConsumerState<MediaLoader> createState() => _MediaLoaderState();
}

class _MediaLoaderState extends ConsumerState<MediaLoader> {
  File? _file;
  bool _failed = false;
  bool _hold = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant MediaLoader old) {
    super.didUpdateWidget(old);
    if (old.media.hash != widget.media.hash) {
      _file = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load({bool force = false}) async {
    final e = ref.read(engineProvider);
    final hit = e.media.cached(widget.media);
    if (hit != null) {
      setState(() {
        _file = hit;
        _hold = false;
      });
      return;
    }
    if (!force && !ref.read(settingsProvider).autoDownload) {
      setState(() {
        _hold = true;
        _failed = false;
      });
      return;
    }
    setState(() => _hold = false);
    final f = await e.openMedia(widget.media, widget.item);
    if (!mounted) return;
    setState(() {
      _file = f;
      _failed = f == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_file != null) return widget.builder(context, _file!);
    return widget.placeholder?.call(context, _failed) ?? _Placeholder(failed: _failed, held: _hold, onRetry: _retry);
  }

  void _retry() {
    setState(() => _failed = false);
    _load(force: true);
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.failed, this.held = false, this.onRetry});
  final bool failed;
  final bool held;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return GestureDetector(
      onTap: (failed || held) ? onRetry : null,
      child: Container(
        color: p.raised,
        alignment: Alignment.center,
        child: failed
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_off_outlined, color: p.faint, size: 22),
                  const SizedBox(height: 6),
                  Text('Not reachable', style: Txt.mono(p.faint, size: 11)),
                  Text('tap to retry', style: Txt.mono(p.faint, size: 10)),
                ],
              )
            : held
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.download_outlined, color: p.faint, size: 22),
                      const SizedBox(height: 6),
                      Text('Tap to download', style: Txt.mono(p.faint, size: 11)),
                    ],
                  )
                : SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.6, color: p.faint)),
      ),
    );
  }
}

/// Image/video grid used in posts and messages.
class MediaGrid extends StatelessWidget {
  const MediaGrid({super.key, required this.media, required this.item, this.radius = Radii.md, this.maxHeight = 420});
  final List<MediaRef> media;
  final Item item;
  final double radius;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final visual = media.where((m) => m.isImage || m.isVideo).toList();
    if (visual.isEmpty) return const SizedBox.shrink();
    void open(int i) => Navigator.of(context).push(PageRouteBuilder(
          opaque: false,
          barrierColor: Colors.black,
          pageBuilder: (_, _, _) => MediaViewer(media: visual, item: item, initial: i),
          transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
        ));

    Widget tile(int i, {double? aspect}) {
      final m = visual[i];
      final child = Hero(
        tag: '${item.id}-${m.hash}',
        child: MediaLoader(
          media: m,
          item: item,
              builder: (_, f) => m.isImage
              ? Image.file(f, fit: BoxFit.cover, width: double.infinity, height: double.infinity, gaplessPlayback: true)
              : _VideoThumb(file: f, media: m),
        ),
      );
      return GestureDetector(
        onTap: () => open(i),
        child: aspect == null ? child : AspectRatio(aspectRatio: aspect, child: child),
      );
    }

    final Widget grid;
    if (visual.length == 1) {
      final a = (visual.first.aspect ?? 4 / 3).clamp(.6, 2.2);
      grid = ConstrainedBox(constraints: BoxConstraints(maxHeight: maxHeight), child: tile(0, aspect: a));
    } else if (visual.length == 2) {
      grid = AspectRatio(
        aspectRatio: 16 / 10,
        child: Row(children: [
          Expanded(child: tile(0)),
          const SizedBox(width: 2),
          Expanded(child: tile(1)),
        ]),
      );
    } else {
      grid = AspectRatio(
        aspectRatio: 1.2,
        child: Row(children: [
          Expanded(child: tile(0)),
          const SizedBox(width: 2),
          Expanded(
            child: Column(children: [
              Expanded(child: tile(1)),
              const SizedBox(height: 2),
              Expanded(
                child: Stack(fit: StackFit.expand, children: [
                  tile(2),
                  if (visual.length > 3)
                    IgnorePointer(
                      child: Container(
                        color: Colors.black45,
                        alignment: Alignment.center,
                        child: Text('+${visual.length - 3}', style: Txt.title(Colors.white)),
                      ),
                    ),
                ]),
              ),
            ]),
          ),
        ]),
      );
    }
    return ClipRRect(borderRadius: BorderRadius.circular(radius), child: grid);
  }
}

class _VideoThumb extends StatefulWidget {
  const _VideoThumb({required this.file, required this.media});
  final File file;
  final MediaRef media;

  @override
  State<_VideoThumb> createState() => _VideoThumbState();
}

class _VideoThumbState extends State<_VideoThumb> {
  VideoPlayerController? _c;

  @override
  void initState() {
    super.initState();
    final c = VideoPlayerController.file(widget.file);
    _c = c;
    unawaited(c.initialize().then((_) async {
      if (!mounted) return;
      await c.seekTo(const Duration(milliseconds: 120));
      await c.pause();
      if (mounted) setState(() {});
    }, onError: (_) {}));
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final ready = c != null && c.value.isInitialized;
    return Container(
      color: const Color(0xFF0D1110),
      child: Stack(
        alignment: Alignment.center,
        fit: StackFit.expand,
        children: [
          if (ready) FittedBox(fit: BoxFit.cover, child: SizedBox(width: c.value.size.width, height: c.value.size.height, child: VideoPlayer(c))),
          Container(
            width: 48,
            height: 48,
            decoration: const BoxDecoration(color: Colors.white24, shape: BoxShape.circle),
            child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 30),
          ),
          if (widget.media.durationMs != null)
            Positioned(
              right: 8,
              bottom: 8,
              child: Text(duration(widget.media.durationMs!), style: Txt.mono(Colors.white, size: 11)),
            ),
        ],
      ),
    );
  }
}

class MediaViewer extends ConsumerStatefulWidget {
  const MediaViewer({super.key, required this.media, required this.item, this.initial = 0});
  final List<MediaRef> media;
  final Item item;
  final int initial;

  @override
  ConsumerState<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends ConsumerState<MediaViewer> {
  late final _pc = PageController(initialPage: widget.initial);
  late int _i = widget.initial;

  @override
  Widget build(BuildContext context) {
    final m = widget.media[_i];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: widget.media.length > 1
            ? Text('${_i + 1} / ${widget.media.length}', style: Txt.mono(Colors.white70, size: 13))
            : null,
        actions: [
          IconBtn(Icons.ios_share_rounded, color: Colors.white, onTap: () => _share(m)),
          const SizedBox(width: 8),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: PageView.builder(
        controller: _pc,
        itemCount: widget.media.length,
        onPageChanged: (i) => setState(() => _i = i),
        itemBuilder: (_, i) {
          final ref = widget.media[i];
          return Hero(
            tag: '${widget.item.id}-${ref.hash}',
            child: MediaLoader(
              media: ref,
              item: widget.item,
              placeholder: (_, failed) => Center(
                child: failed
                    ? Text('Not reachable right now', style: Txt.mono(Colors.white54))
                    : const CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
              ),
              builder: (_, f) => ref.isVideo
                  ? VideoView(file: f)
                  : InteractiveViewer(maxScale: 5, child: Center(child: Image.file(f))),
            ),
          );
        },
      ),
    );
  }

  Future<void> _share(MediaRef m) async {
    final e = ref.read(engineProvider);
    final f = await e.media.export(m, sources: e.sourcesFor(widget.item));
    if (f == null) return;
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)]));
  }
}

class VideoView extends StatefulWidget {
  const VideoView({super.key, required this.file, this.autoplay = true});
  final File file;
  final bool autoplay;

  @override
  State<VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends State<VideoView> {
  late final VideoPlayerController _c = VideoPlayerController.file(widget.file);
  bool _ready = false;
  bool _playing = false;
  bool _fast = false;
  int _shownSecond = -1;

  @override
  void initState() {
    super.initState();
    unawaited(
      _c.initialize().then((_) {
        if (!mounted) return;
        setState(() => _ready = true);
        if (widget.autoplay) _c.play();
      }, onError: (_) {}),
    );
    _c.addListener(() {
      if (!mounted) return;
      final v = _c.value;
      final second = v.position.inSeconds;
      if (v.isPlaying == _playing && second == _shownSecond) return;
      _playing = v.isPlaying;
      _shownSecond = second;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54));
    final v = _c.value;
    return GestureDetector(
      onTap: () => v.isPlaying ? _c.pause() : _c.play(),
      onDoubleTapDown: (d) {
        final box = context.findRenderObject();
        final width = box is RenderBox ? box.size.width : 1;
        final delta = d.localPosition.dx < width / 2 ? -10 : 10;
        var next = v.position + Duration(seconds: delta);
        if (next < Duration.zero) next = Duration.zero;
        if (next > v.duration) next = v.duration;
        _c.seekTo(next);
      },
      onLongPressStart: (d) {
        final box = context.findRenderObject();
        final width = box is RenderBox ? box.size.width : 1;
        final x = d.localPosition.dx;
        if (x < width * .3 || x > width * .7) {
          _c.setPlaybackSpeed(2);
          setState(() => _fast = true);
        }
      },
      onLongPressEnd: (_) {
        _c.setPlaybackSpeed(1);
        if (_fast) setState(() => _fast = false);
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          Center(child: AspectRatio(aspectRatio: v.aspectRatio, child: VideoPlayer(_c))),
          if (!v.isPlaying)
            Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(color: Colors.white24, shape: BoxShape.circle),
              child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 40),
            ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 32,
            child: Row(
              children: [
                Text(duration(v.position.inMilliseconds), style: Txt.mono(Colors.white70, size: 11)),
                const SizedBox(width: 10),
                Expanded(
                  child: VideoProgressIndicator(_c,
                      allowScrubbing: true,
                      colors: const VideoProgressColors(
                          playedColor: Colors.white, bufferedColor: Colors.white24, backgroundColor: Colors.white12)),
                ),
                const SizedBox(width: 10),
                Text(duration(v.duration.inMilliseconds), style: Txt.mono(Colors.white70, size: 11)),
                IconButton(
                  tooltip: 'Full screen',
                  onPressed: () {
                    Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        backgroundColor: Colors.black,
                        body: SafeArea(child: VideoView(file: widget.file)),
                      ),
                    ));
                  },
                  icon: const Icon(Icons.fullscreen_rounded, color: Colors.white),
                ),
                IconButton(
                  tooltip: 'Picture in picture',
                  onPressed: () => _pip(context),
                  icon: const Icon(Icons.picture_in_picture_alt_rounded, color: Colors.white),
                ),
              ],
            ),
          ),
          if (_fast)
            const Positioned(
              top: 24,
              child: Text('2x', style: TextStyle(color: Colors.white, fontSize: 18)),
            ),
        ],
      ),
    );
  }

  void _pip(BuildContext context) {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    final file = widget.file;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => Positioned(
        right: 16,
        bottom: 96,
        width: 180,
        height: 120,
        child: Material(
          color: Colors.black,
          elevation: 8,
          child: Stack(
            fit: StackFit.expand,
            children: [
              VideoView(file: file),
              Align(
                alignment: Alignment.topRight,
                child: IconButton(
                  onPressed: () => entry.remove(),
                  icon: const Icon(Icons.close_rounded, color: Colors.white, size: 18),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    overlay.insert(entry);
  }
}

/// Voice note / audio player with a waveform.
class VoicePlayer extends ConsumerStatefulWidget {
  const VoicePlayer({super.key, required this.media, required this.item, required this.fg, required this.track, this.accent});
  final MediaRef media;
  final Item item;
  final Color fg;
  final Color track;
  final Color? accent;

  @override
  ConsumerState<VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends ConsumerState<VoicePlayer> {
  final _player = AudioPlayer();
  StreamSubscription? _sub;
  bool _loading = false;
  bool _loaded = false;
  bool _failed = false;
  double _speed = 1;

  @override
  void initState() {
    super.initState();
    _sub = _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        _player.pause();
        _player.seek(Duration.zero);
      }
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_player.playing) {
      await _player.pause();
      return;
    }
    if (!_loaded) {
      setState(() => _loading = true);
      final f = await ref.read(engineProvider).openMedia(widget.media, widget.item);
      if (!mounted) return;
      if (f == null) {
        setState(() {
          _loading = false;
          _failed = true;
        });
        return;
      }
      await _player.setFilePath(f.path);
      _loaded = true;
      setState(() {
        _loading = false;
        _failed = false;
      });
    }
    await _player.play();
  }

  @override
  Widget build(BuildContext context) {
    final wave = widget.media.wave ?? List.generate(36, (i) => 30 + (math.sin(i * .7) * 25).round().abs());
    final total = widget.media.durationMs ?? _player.duration?.inMilliseconds ?? 0;
    return StreamBuilder<Duration>(
      stream: _player.positionStream,
      builder: (context, snap) {
        final pos = snap.data?.inMilliseconds ?? 0;
        final progress = total == 0 ? 0.0 : (pos / total).clamp(0.0, 1.0);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: _toggle,
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: widget.fg, shape: BoxShape.circle),
                child: _loading
                    ? Padding(
                        padding: const EdgeInsets.all(10),
                        child: CircularProgressIndicator(strokeWidth: 1.6, color: widget.track),
                      )
                    : Icon(
                        _failed
                            ? Icons.cloud_off_rounded
                            : (_player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                        color: widget.track,
                        size: 22,
                      ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 140,
              height: 30,
              child: GestureDetector(
                onTapDown: (d) {
                  if (!_loaded || total == 0) return;
                  _player.seek(Duration(milliseconds: (d.localPosition.dx / 140 * total).round()));
                },
                child: CustomPaint(painter: _WavePainter(wave, progress, widget.fg, widget.fg.withValues(alpha: .3))),
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(duration(_player.playing || pos > 0 ? pos : total),
                    style: Txt.mono(widget.fg.withValues(alpha: .8), size: 11)),
                if (_loaded)
                  GestureDetector(
                    onTap: () {
                      _speed = _speed == 1 ? 1.5 : (_speed == 1.5 ? 2 : 1);
                      _player.setSpeed(_speed);
                      setState(() {});
                    },
                    child: Text('${_speed}x', style: Txt.mono(widget.fg.withValues(alpha: .6), size: 10)),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.wave, this.progress, this.on, this.off);
  final List<int> wave;
  final double progress;
  final Color on;
  final Color off;

  @override
  void paint(Canvas canvas, Size size) {
    final n = wave.length;
    if (n == 0) return;
    final w = size.width / n;
    final maxV = wave.reduce(math.max).clamp(1, 100);
    for (var i = 0; i < n; i++) {
      final h = math.max(3.0, (wave[i] / maxV) * size.height);
      final x = i * w + w / 2;
      final paint = Paint()
        ..color = (i / n) <= progress ? on : off
        ..strokeWidth = math.max(1.5, w * .55)
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(x, (size.height - h) / 2), Offset(x, (size.height + h) / 2), paint);
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.progress != progress || old.on != on;
}

IconData fileIcon(String mime) {
  if (mime.startsWith('image/')) return Icons.image_outlined;
  if (mime.startsWith('video/')) return Icons.movie_outlined;
  if (mime.startsWith('audio/')) return Icons.graphic_eq_rounded;
  if (mime.contains('pdf')) return Icons.picture_as_pdf_outlined;
  if (mime.contains('zip') || mime.contains('compressed')) return Icons.folder_zip_outlined;
  if (mime.contains('sheet') || mime.contains('excel') || mime.contains('csv')) return Icons.table_chart_outlined;
  if (mime.startsWith('text/') || mime.contains('word') || mime.contains('document')) return Icons.description_outlined;
  return Icons.insert_drive_file_outlined;
}

class FileTile extends ConsumerStatefulWidget {
  const FileTile({super.key, required this.media, required this.item, required this.fg, required this.bg});
  final MediaRef media;
  final Item item;
  final Color fg;
  final Color bg;

  @override
  ConsumerState<FileTile> createState() => _FileTileState();
}

class _FileTileState extends ConsumerState<FileTile> {
  bool _busy = false;

  Future<void> _open() async {
    setState(() => _busy = true);
    final e = ref.read(engineProvider);
    File? f;
    try {
      f = await e.media.export(widget.media, sources: e.sourcesFor(widget.item));
    } catch (_) {
      f = null;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (f == null) {
      toast(context, 'File not reachable — the sender is offline.');
      return;
    }
    if (!mounted) return;
    await showLocalFile(context, f, name: widget.media.name, mime: widget.media.mime);
  }

  Future<void> _save() async {
    final e = ref.read(engineProvider);
    File? f;
    try {
      f = await e.media.saveToDevice(widget.media, sources: e.sourcesFor(widget.item));
    } catch (_) {
      f = null;
    }
    if (mounted) toast(context, f == null ? 'Could not save' : 'Saved to ${f.path}');
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.media;
    return GestureDetector(
      onTap: _busy ? null : _open,
      onLongPress: _busy ? null : _save,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: widget.bg, borderRadius: BorderRadius.circular(Radii.md)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(color: widget.fg.withValues(alpha: .1), borderRadius: BorderRadius.circular(10)),
              child: _busy
                  ? Padding(
                      padding: const EdgeInsets.all(11),
                      child: CircularProgressIndicator(strokeWidth: 1.6, color: widget.fg))
                  : Icon(fileIcon(m.mime), color: widget.fg, size: 20),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.bodyStrong(widget.fg)),
                  Text('${bytes(m.size)} · ${m.name.contains('.') ? m.name.split('.').last.toUpperCase() : 'FILE'}',
                      style: Txt.mono(widget.fg.withValues(alpha: .6), size: 11)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showLocalFile(BuildContext context, File file, {required String name, required String mime}) {
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => FilePage(file: file, name: name, mime: mime),
  ));
}

class FilePage extends StatefulWidget {
  const FilePage({super.key, required this.file, required this.name, required this.mime});
  final File file;
  final String name;
  final String mime;

  @override
  State<FilePage> createState() => _FilePageState();
}

class _FilePageState extends State<FilePage> {
  String? _text;
  final _player = AudioPlayer();

  bool get _audio => widget.mime.startsWith('audio/') || widget.name.toLowerCase().endsWith('.mp3');
  bool get _visual => widget.mime.startsWith('image/') || widget.mime.startsWith('video/');
  bool get _textLike => widget.mime.startsWith('text/') ||
      widget.mime.contains('json') ||
      widget.name.toLowerCase().endsWith('.md') ||
      widget.name.toLowerCase().endsWith('.csv');

  @override
  void initState() {
    super.initState();
    if (_textLike && widget.file.lengthSync() < 400 * 1024) {
      _text = widget.file.readAsStringSync();
    }
    if (_audio) unawaited(_player.setFilePath(widget.file.path));
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Scaffold(
      appBar: AppBar(title: Text(widget.name, overflow: TextOverflow.ellipsis)),
      body: Column(
        children: [
          Expanded(
            child: _visual && widget.mime.startsWith('image/')
                ? InteractiveViewer(child: Image.file(widget.file))
                : _visual
                    ? VideoView(file: widget.file)
                    : _audio
                        ? Center(
                            child: FilledButton.icon(
                              onPressed: () => _player.playing ? _player.pause() : _player.play(),
                              icon: const Icon(Icons.play_arrow_rounded),
                              label: const Text('Play'),
                            ),
                          )
                        : _text != null
                            ? SingleChildScrollView(
                                padding: const EdgeInsets.all(Space.gutter),
                                child: SelectableText(_text!, style: Txt.mono(p.ink, size: 12)),
                              )
                            : Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(Space.gutter),
                                  child: Text(
                                    widget.mime.contains('pdf')
                                        ? 'PDF is ready. Open it with the viewer on this device.'
                                        : 'This file is on the phone. Open it outside Mentos if you need another app.',
                                    textAlign: TextAlign.center,
                                    style: Txt.body(p.muted),
                                  ),
                                ),
                              ),
          ),
          Padding(
            padding: const EdgeInsets.all(Space.gutter),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(onPressed: () => OpenFilex.open(widget.file.path, type: widget.mime), child: const Text('Open')),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: () => SharePlus.instance.share(ShareParams(files: [XFile(widget.file.path)])),
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
