import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:pdfrx/pdfrx.dart';
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
  const MediaGrid({super.key, required this.media, required this.item, this.radius = Radii.md, this.maxHeight = 420, this.square = false});
  final List<MediaRef> media;

  /// Feed posts: every layout fills a 1:1 frame, so the feed lines up.
  final bool square;
  final Item item;
  final double radius;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final visual = media.where((m) => m.isImage || m.isVideo).toList();
    if (visual.isEmpty) return const SizedBox.shrink();
    // The same post can sit twice on one screen (a feed and a pinned copy,
    // a repost, the same photo attached twice), so tags carry this grid's
    // own identity and the index. Duplicate tags crash the page transition.
    final gridId = identityHashCode(context);
    final tags = <Object>[for (var i = 0; i < visual.length; i++) 'media-$gridId-${item.id}-$i'];
    void open(int i) => Navigator.of(context).push(PageRouteBuilder(
          opaque: false,
          barrierColor: Colors.black,
          pageBuilder: (_, _, _) => MediaViewer(media: visual, item: item, initial: i, heroTags: tags),
          transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
        ));

    Widget tile(int i, {double? aspect}) {
      final m = visual[i];
      final child = Hero(
        tag: tags[i],
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
    if (visual.length == 1 && square) {
      grid = AspectRatio(aspectRatio: 1, child: tile(0));
    } else if (visual.length == 1) {
      final a = (visual.first.aspect ?? 4 / 3).clamp(.6, 2.2);
      grid = ConstrainedBox(constraints: BoxConstraints(maxHeight: maxHeight), child: tile(0, aspect: a));
    } else if (visual.length == 2) {
      grid = AspectRatio(
        aspectRatio: square ? 1 : 16 / 10,
        child: Row(children: [
          Expanded(child: tile(0)),
          const SizedBox(width: 2),
          Expanded(child: tile(1)),
        ]),
      );
    } else {
      grid = AspectRatio(
        aspectRatio: square ? 1 : 1.2,
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
  const MediaViewer({super.key, required this.media, required this.item, this.initial = 0, this.heroTags});
  final List<MediaRef> media;
  final Item item;
  final int initial;

  /// The tags the opening grid used, one per item, so the photo flies in.
  final List<Object>? heroTags;

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
            tag: widget.heroTags?[i] ?? '${widget.item.id}-${ref.hash}-$i',
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

enum _Viewer { image, video, audio, pdf, table, text, none }

class _FilePageState extends State<FilePage> {
  String? _text;
  List<List<String>>? _rows;
  bool _tooBig = false;
  AudioPlayer? _player;

  String get _lower => widget.name.toLowerCase();

  _Viewer get _kind {
    final m = widget.mime;
    if (m.startsWith('image/')) return _Viewer.image;
    if (m.startsWith('video/')) return _Viewer.video;
    if (m.startsWith('audio/') || _lower.endsWith('.mp3') || _lower.endsWith('.m4a')) return _Viewer.audio;
    if (m.contains('pdf') || _lower.endsWith('.pdf')) return _Viewer.pdf;
    if (_lower.endsWith('.csv') || m == 'text/csv') return _Viewer.table;
    if (m.startsWith('text/') || m.contains('json') || m.contains('xml') ||
        const ['.md', '.txt', '.log', '.yaml', '.yml', '.dart', '.py', '.js', '.ts', '.html', '.css', '.ini', '.toml']
            .any(_lower.endsWith)) {
      return _Viewer.text;
    }
    return _Viewer.none;
  }

  @override
  void initState() {
    super.initState();
    final kind = _kind;
    if (kind == _Viewer.text || kind == _Viewer.table) {
      if (widget.file.lengthSync() > 2 * 1024 * 1024) {
        _tooBig = true;
      } else {
        final raw = widget.file.readAsStringSync();
        if (kind == _Viewer.table) {
          _rows = _csv(raw);
        } else {
          _text = raw;
        }
      }
    }
    if (kind == _Viewer.audio) {
      _player = AudioPlayer();
      unawaited(_player!.setFilePath(widget.file.path));
    }
  }

  /// A small CSV reader: quoted fields, escaped quotes, commas or semicolons.
  static List<List<String>> _csv(String raw) {
    final sep = raw.split('\n').first.contains(';') && !raw.split('\n').first.contains(',') ? ';' : ',';
    final rows = <List<String>>[];
    var row = <String>[];
    final cell = StringBuffer();
    var quoted = false;
    for (var i = 0; i < raw.length; i++) {
      final ch = raw[i];
      if (quoted) {
        if (ch == '"' && i + 1 < raw.length && raw[i + 1] == '"') {
          cell.write('"');
          i++;
        } else if (ch == '"') {
          quoted = false;
        } else {
          cell.write(ch);
        }
      } else if (ch == '"') {
        quoted = true;
      } else if (ch == sep) {
        row.add(cell.toString());
        cell.clear();
      } else if (ch == '\n' || ch == '\r') {
        if (ch == '\r' && i + 1 < raw.length && raw[i + 1] == '\n') i++;
        row.add(cell.toString());
        cell.clear();
        rows.add(row);
        row = <String>[];
        if (rows.length >= 2000) break;
      } else {
        cell.write(ch);
      }
    }
    if (cell.isNotEmpty || row.isNotEmpty) {
      row.add(cell.toString());
      rows.add(row);
    }
    return rows.where((r) => r.any((c) => c.trim().isNotEmpty)).toList();
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Scaffold(
      appBar: AppBar(title: Text(widget.name, overflow: TextOverflow.ellipsis)),
      body: Column(
        children: [
          Expanded(child: _viewer(p)),
          Padding(
            padding: const EdgeInsets.all(Space.gutter),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => OpenFilex.open(widget.file.path, type: widget.mime),
                    child: const Text('Open in another app'),
                  ),
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

  Widget _viewer(Palette p) {
    if (_tooBig) {
      return _note(p, Icons.description_outlined, 'This file is too large to preview here.');
    }
    switch (_kind) {
      case _Viewer.image:
        return InteractiveViewer(maxScale: 6, child: Center(child: Image.file(widget.file)));
      case _Viewer.video:
        return VideoView(file: widget.file);
      case _Viewer.audio:
        return _AudioPanel(player: _player!, name: widget.name);
      case _Viewer.pdf:
        return PdfViewer.file(
          widget.file.path,
          params: PdfViewerParams(
            backgroundColor: p.raised,
            margin: 12,
            errorBannerBuilder: (context, error, _, _) =>
                _note(p, Icons.picture_as_pdf_outlined, 'This PDF could not be shown here. Open it in another app.'),
          ),
        );
      case _Viewer.table:
        final rows = _rows ?? const <List<String>>[];
        if (rows.isEmpty) return _note(p, Icons.table_chart_outlined, 'This table is empty.');
        final width = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
        return Scrollbar(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Space.md),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowColor: WidgetStatePropertyAll(p.raised),
                columns: [
                  for (var i = 0; i < width; i++)
                    DataColumn(label: Text(i < rows.first.length ? rows.first[i] : '', style: Txt.bodyStrong(p.ink))),
                ],
                rows: [
                  for (final r in rows.skip(1).take(1000))
                    DataRow(cells: [
                      for (var i = 0; i < width; i++) DataCell(Text(i < r.length ? r[i] : '', style: Txt.small(p.ink))),
                    ]),
                ],
              ),
            ),
          ),
        );
      case _Viewer.text:
        return SingleChildScrollView(
          padding: const EdgeInsets.all(Space.gutter),
          child: SelectableText(_text ?? '', style: Txt.mono(p.ink, size: 12)),
        );
      case _Viewer.none:
        return _note(p, Icons.insert_drive_file_outlined,
            'There is no preview for this kind of file. Open it in another app.');
    }
  }

  Widget _note(Palette p, IconData icon, String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(Space.gutter),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: p.faint),
          const SizedBox(height: Space.md),
          Text(text, textAlign: TextAlign.center, style: Txt.body(p.muted)),
        ],
      ),
    ),
  );
}

/// Play, pause and seek for an audio file.
class _AudioPanel extends StatelessWidget {
  const _AudioPanel({required this.player, required this.name});
  final AudioPlayer player;
  final String name;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(32)),
              child: Icon(Icons.graphic_eq_rounded, size: 56, color: p.accent),
            ),
            const SizedBox(height: Space.lg),
            Text(name, textAlign: TextAlign.center, style: Txt.heading(p.ink)),
            const SizedBox(height: Space.lg),
            StreamBuilder<Duration>(
              stream: player.positionStream,
              builder: (context, snap) {
                final pos = snap.data ?? Duration.zero;
                final total = player.duration ?? Duration.zero;
                final max = total.inMilliseconds <= 0 ? 1.0 : total.inMilliseconds.toDouble();
                return Column(
                  children: [
                    Slider(
                      value: pos.inMilliseconds.clamp(0, max.toInt()).toDouble(),
                      max: max,
                      onChanged: (v) => player.seek(Duration(milliseconds: v.round())),
                    ),
                    Row(
                      children: [
                        Text(duration(pos.inMilliseconds), style: Txt.mono(p.muted, size: 11)),
                        const Spacer(),
                        Text(duration(total.inMilliseconds), style: Txt.mono(p.muted, size: 11)),
                      ],
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: Space.md),
            StreamBuilder<PlayerState>(
              stream: player.playerStateStream,
              builder: (context, snap) {
                final playing = snap.data?.playing ?? false;
                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      iconSize: 32,
                      onPressed: () => player.seek((player.position) - const Duration(seconds: 10)),
                      icon: const Icon(Icons.replay_10_rounded),
                    ),
                    const SizedBox(width: Space.md),
                    IconButton.filled(
                      iconSize: 40,
                      onPressed: () => playing ? player.pause() : player.play(),
                      icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                    ),
                    const SizedBox(width: Space.md),
                    IconButton(
                      iconSize: 32,
                      onPressed: () => player.seek(player.position + const Duration(seconds: 10)),
                      icon: const Icon(Icons.forward_10_rounded),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
