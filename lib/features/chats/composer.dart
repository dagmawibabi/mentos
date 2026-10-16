import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:record/record.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/link_preview.dart';
import '../../net/views.dart';
import '../../state/live_share.dart';
import '../../state/providers.dart';
import '../../widgets/ui.dart';
import '../common/attach.dart';
import 'bubble.dart';

class Composer extends ConsumerStatefulWidget {
  const Composer({
    super.key,
    required this.scope,
    this.replyTo,
    this.editing,
    required this.onCancelReply,
    required this.onCancelEdit,
    this.enabled = true,
    this.publishPost,
  });

  final String scope;
  final MessageView? replyTo;
  final MessageView? editing;
  final VoidCallback onCancelReply;
  final VoidCallback onCancelEdit;
  final bool enabled;
  final Future<void> Function(String text, List<MediaRef> media, Poll? poll)?
  publishPost;

  @override
  ConsumerState<Composer> createState() => ComposerState();
}

class ComposerState extends ConsumerState<Composer> {
  final _c = TextEditingController();
  final focus = FocusNode();
  final _rec = AudioRecorder();
  bool _recording = false;
  bool _paused = false;
  Duration _pausedFor = Duration.zero;
  DateTime? _pausedAt;
  bool _busy = false;
  DateTime? _recStart;
  final _levels = <double>[];
  StreamSubscription? _amp;
  Timer? _ticker;
  String? _recPath;
  bool _nsfw = false;

  void _onText() {
    if (!mounted) return;
    setState(() {});
    if (_c.text.isNotEmpty) ref.read(engineProvider).typing(widget.scope, true);
    if (firstHttpUrl(_c.text) != null) unawaited(warmPreview(_c.text));
  }

  @override
  void initState() {
    super.initState();
    _c.addListener(_onText);
  }

  @override
  void didUpdateWidget(covariant Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.editing != null && widget.editing != oldWidget.editing) {
      _c.text = widget.editing!.text;
      focus.requestFocus();
    }
    if (widget.replyTo != null && widget.replyTo != oldWidget.replyTo)
      focus.requestFocus();
  }

  @override
  void dispose() {
    _c.removeListener(_onText);
    _amp?.cancel();
    _ticker?.cancel();
    _rec.dispose();
    _c.dispose();
    focus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _c.text.trim();
    if (text.isEmpty) return;
    final e = ref.read(engineProvider);
    if (widget.editing != null) {
      if (text != widget.editing!.text)
        await e.edit(widget.scope, widget.editing!.id, text);
      _c.clear();
      widget.onCancelEdit();
      return;
    }
    final preview = widget.publishPost == null ? await previewBody(text) : null;
    if (!mounted) return;
    _c.clear();
    final reply = widget.replyTo?.id;
    widget.onCancelReply();
    HapticFeedback.lightImpact();
    try {
      if (widget.publishPost != null) {
        await widget.publishPost!(text, const [], null);
      } else {
        await e.sendMessage(
          widget.scope,
          text: text,
          replyTo: reply,
          nsfw: _nsfw,
          preview: preview,
        );
      }
      if (mounted) setState(() => _nsfw = false);
    } catch (err) {
      if (mounted) {
        if (_c.text.isEmpty) _c.text = text;
        toast(context, 'Couldn\'t send: $err');
      }
    }
  }

  Future<void> _sendMedia(List<Pending> picked, {String text = ''}) async {
    if (picked.isEmpty) return;
    var caption = text;
    if (caption.isEmpty && mounted) {
      final typed = await prompt(
        context,
        title: 'Caption',
        body: picked.length == 1
            ? picked.first.name
            : '${picked.length} files, sent together.',
        hint: 'Optional',
        action: 'Send',
        maxLength: 200,
        multiline: true,
        minLines: 2,
      );
      if (!mounted) return;
      if (typed == null) return;
      caption = typed.trim();
    }
    setState(() => _busy = true);
    final e = ref.read(engineProvider);
    try {
      final refs = <MediaRef>[];
      for (final x in picked) {
        refs.add(await importPending(e, x, scope: widget.scope));
      }
      final reply = widget.replyTo?.id;
      final preview = widget.publishPost == null ? await previewBody(caption) : null;
      if (!mounted) return;
      widget.onCancelReply();
      if (widget.publishPost != null) {
        await widget.publishPost!(caption, refs, null);
      } else {
        await e.sendMessage(
          widget.scope,
          media: refs,
          text: caption,
          replyTo: reply,
          nsfw: _nsfw,
          preview: preview,
        );
      }
      if (mounted) setState(() => _nsfw = false);
    } on FileSystemException {
      if (mounted) toast(context, 'Not enough disk space to send that file.');
    } catch (err) {
      if (mounted) toast(context, 'Couldn\'t send: $err');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _attach() {
    final e = ref.read(engineProvider);
    showActions(context, [
      SheetAction(
        Icons.photo_outlined,
        'Photos',
        () async => _sendMedia(await pickImages(context: context)),
      ),
      SheetAction(Icons.photo_camera_outlined, 'Camera', () async {
        final x = await takePhoto();
        if (x != null) await _sendMedia([x]);
      }),
      SheetAction(Icons.videocam_outlined, 'Video message', () async {
        final x = await pickVideo(context: context);
        if (x != null) await _sendMedia([x]);
      }),
      SheetAction(
        Icons.attach_file_rounded,
        'File',
        () async => _sendMedia(await pickFiles(e.media, context: context)),
      ),
      SheetAction(Icons.emoji_emotions_outlined, 'Sticker', _stickers),
      if (e.installedPhrases().isNotEmpty)
        SheetAction(Icons.notes_rounded, 'Saved phrases', _phrases),
      if (widget.publishPost == null)
        SheetAction(Icons.gif_box_outlined, 'GIF', _gif),
      if (widget.publishPost == null)
        SheetAction(Icons.location_on_outlined, 'Live location', _liveLocation),
      SheetAction(Icons.poll_outlined, 'Poll', _newPoll),
    ], title: 'ATTACH');
  }

  Future<void> _newPoll() async {
    final drafted =
        await showInputSheet<({String question, List<String> options})>(
          context,
          (_) => const _PollSheet(),
        );
    if (drafted == null || drafted.options.length < 2) return;
    final poll = Poll(drafted.question, drafted.options);
    if (widget.publishPost != null) {
      await widget.publishPost!('', const [], poll);
    } else {
      await ref
          .read(engineProvider)
          .sendMessage(widget.scope, poll: poll, nsfw: _nsfw);
    }
    if (mounted) setState(() => _nsfw = false);
  }

  Future<void> _stickers() async {
    const builtIn = [
      '😀',
      '😂',
      '🔥',
      '❤️',
      '👍',
      '🎉',
      '😢',
      '🙏',
      '✨',
      '💯',
      '👀',
      '🤝',
    ];
    final extra = ref.read(engineProvider).installedStickers();
    final stickers = [
      ...extra,
      for (final s in builtIn)
        if (!extra.contains(s)) s,
    ];
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Wrap(
            children: [
              for (final s in stickers)
                IconButton(
                  onPressed: () => Navigator.pop(ctx, s),
                  icon: Text(s, style: const TextStyle(fontSize: 28)),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    if (widget.publishPost != null) {
      await widget.publishPost!(picked, const [], null);
    } else {
      await ref
          .read(engineProvider)
          .sendMessage(widget.scope, text: picked, sticker: true, nsfw: _nsfw);
    }
  }

  Future<void> _phrases() async {
    final packs = ref.read(engineProvider).installedPhrases();
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final pack in packs) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.gutter,
                  Space.sm,
                  Space.gutter,
                  0,
                ),
                child: Text(
                  pack.title,
                  style: Txt.mono(ctx.pal.faint, size: 11),
                ),
              ),
              for (final line in pack.lines)
                ListTile(
                  title: Text(line),
                  onTap: () => Navigator.pop(ctx, line),
                ),
            ],
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    _c.text = _c.text.isEmpty ? picked : '${_c.text} $picked';
    _c.selection = TextSelection.collapsed(offset: _c.text.length);
  }

  Future<void> _gif() async {
    final url = await prompt(
      context,
      title: 'GIF',
      body: 'A direct link. It is sent as the address, not uploaded from this phone.',
      hint: 'https://',
      action: 'Send',
      maxLength: 300,
      allowEmpty: false,
      keyboard: TextInputType.url,
      capitalization: TextCapitalization.none,
      validate: (v) {
        final t = v.trim();
        final u = Uri.tryParse(t);
        if (u == null ||
            (u.scheme != 'https' && u.scheme != 'http') ||
            u.host.isEmpty) {
          return 'Start with https:// and a host';
        }
        return null;
      },
    );
    if (url == null) return;
    await ref
        .read(engineProvider)
        .sendMessage(widget.scope, text: '', gif: url.trim());
  }

  Future<void> _liveLocation() async {
    final place = await showInputSheet<({String label, int minutes})>(
      context,
      (_) => const _PlaceSheet(),
    );
    if (place == null || !mounted) return;
    setState(() => _busy = true);
    final err = await ref.read(liveShareProvider).start(
          widget.scope,
          Duration(minutes: place.minutes),
          text: place.label,
        );
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) toast(context, err);
  }

  Future<void> _togglePause() async {
    if (_paused) {
      _pausedFor += DateTime.now().difference(_pausedAt ?? DateTime.now());
      await _rec.resume();
      _paused = false;
    } else {
      _pausedAt = DateTime.now();
      await _rec.pause();
      _paused = true;
    }
    if (mounted) setState(() {});
  }

  Future<void> _startRecording() async {
    if (!await _rec.hasPermission()) {
      if (mounted)
        toast(context, 'Microphone permission is needed for voice messages.');
      return;
    }
    final e = ref.read(engineProvider);
    _recPath = e.media.newTmpPath('.m4a');
    await _rec.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 64000,
        sampleRate: 44100,
      ),
      path: _recPath!,
    );
    HapticFeedback.mediumImpact();
    _levels.clear();
    _amp = _rec.onAmplitudeChanged(const Duration(milliseconds: 90)).listen((
      a,
    ) {
      final v = ((a.current + 50) / 50).clamp(0.0, 1.0);
      _levels.add(v);
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) setState(() {});
    });
    setState(() {
      _recording = true;
      _recStart = DateTime.now();
    });
  }

  Future<void> _stopRecording({required bool send}) async {
    _amp?.cancel();
    _ticker?.cancel();
    final path = await _rec.stop();
    var held = _pausedFor;
    if (_paused && _pausedAt != null)
      held += DateTime.now().difference(_pausedAt!);
    final ms = (DateTime.now().difference(_recStart ?? DateTime.now()) - held)
        .inMilliseconds;
    setState(() {
      _recording = false;
      _paused = false;
      _pausedFor = Duration.zero;
    });
    if (!send || path == null || ms < 700) {
      if (path != null) await File(path).delete().catchError((_) => File(path));
      return;
    }
    const bars = 40;
    final wave = List<int>.generate(bars, (i) {
      if (_levels.isEmpty) return 10;
      final start = (i * _levels.length / bars).floor();
      final end = math.max(
        start + 1,
        ((i + 1) * _levels.length / bars).floor(),
      );
      final slice = _levels.sublist(start, math.min(end, _levels.length));
      final avg = slice.isEmpty
          ? 0.0
          : slice.reduce((a, b) => a + b) / slice.length;
      return (8 + avg * 92).round();
    });
    await _sendMedia([
      Pending(
        File(path),
        'voice-${DateTime.now().millisecondsSinceEpoch}.m4a',
        durationMs: ms,
        wave: wave,
        temp: true,
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final hasText = _c.text.trim().isNotEmpty;

    return Container(
      decoration: BoxDecoration(
        color: p.bg,
        border: Border(top: BorderSide(color: p.line)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.replyTo != null || widget.editing != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.gutter, 8, 6, 0),
                child: Row(
                  children: [
                    Container(
                      width: 2.5,
                      height: 32,
                      color: widget.editing != null ? p.ink : p.accent,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.editing != null
                                ? 'Editing'
                                : 'Replying to ${e.nameOf(widget.replyTo!.author)}',
                            style: Txt.small(p.ink)
                                .copyWith(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            previewOf(widget.editing ?? widget.replyTo!),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Txt.small(p.muted),
                          ),
                        ],
                      ),
                    ),
                    IconBtn(
                      Icons.close_rounded,
                      size: 18,
                      color: p.muted,
                      onTap: () {
                        if (widget.editing != null) {
                          _c.clear();
                          widget.onCancelEdit();
                        } else {
                          widget.onCancelReply();
                        }
                      },
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
              child: _recording ? _recordingBar(p) : _inputBar(p, hasText),
            ),
          ],
        ),
      ),
    );
  }

  Widget _inputBar(Palette p, bool hasText) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        IconBtn(
          Icons.add_rounded,
          tooltip: 'Attach',
          onTap: widget.enabled && !_busy ? _attach : null,
        ),
        IconBtn(
          _nsfw ? Icons.visibility_off_rounded : Icons.visibility_off_outlined,
          tooltip: 'NSFW',
          active: _nsfw,
          onTap: widget.enabled ? () => setState(() => _nsfw = !_nsfw) : null,
        ),
        Expanded(
          child: TextField(
            controller: _c,
            focusNode: focus,
            enabled: widget.enabled,
            minLines: 1,
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: _busy ? 'Encrypting…' : 'Message',
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 11,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(22),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(22),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(22),
                borderSide: BorderSide.none,
              ),
              disabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(22),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        AnimatedSwitcher(
          duration: Motion.fast,
          transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
          child: hasText || widget.editing != null
              ? GestureDetector(
                  key: const ValueKey('send'),
                  onTap: _send,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: p.accent,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      widget.editing != null
                          ? Icons.check_rounded
                          : Icons.arrow_upward_rounded,
                      color: p.accentInk,
                      size: 22,
                    ),
                  ),
                )
              : GestureDetector(
                  key: const ValueKey('mic'),
                  onTap: widget.enabled && !_busy ? _startRecording : null,
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Icon(
                      Icons.mic_none_rounded,
                      color: widget.enabled ? p.ink : p.faint,
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _recordingBar(Palette p) {
    var held = _pausedFor;
    if (_paused && _pausedAt != null)
      held += DateTime.now().difference(_pausedAt!);
    final ms = (DateTime.now().difference(_recStart ?? DateTime.now()) - held)
        .inMilliseconds;
    final recent = _levels.length > 32
        ? _levels.sublist(_levels.length - 32)
        : _levels;
    return Row(
      children: [
        IconBtn(
          Icons.delete_outline_rounded,
          color: p.danger,
          onTap: () => _stopRecording(send: false),
        ),
        IconBtn(
          _paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          tooltip: _paused ? 'Resume' : 'Pause',
          onTap: _togglePause,
        ),
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: p.danger, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(duration(ms), style: Txt.mono(p.ink, size: 13)),
        const SizedBox(width: 12),
        Expanded(
          child: SizedBox(
            height: 28,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                for (final l in recent)
                  Container(
                    width: 3,
                    height: 4 + l * 24,
                    margin: const EdgeInsets.symmetric(horizontal: 1),
                    decoration: BoxDecoration(
                      color: p.ink,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () => _stopRecording(send: true),
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle),
            child: Icon(
              Icons.arrow_upward_rounded,
              color: p.accentInk,
              size: 22,
            ),
          ),
        ),
      ],
    );
  }
}

class _PollSheet extends StatefulWidget {
  const _PollSheet();

  @override
  State<_PollSheet> createState() => _PollSheetState();
}

class _PollSheetState extends State<_PollSheet> {
  final _q = TextEditingController();
  final _opts = [TextEditingController(), TextEditingController()];

  @override
  void dispose() {
    _q.dispose();
    for (final c in _opts) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> get _filled =>
      _opts.map((c) => c.text.trim()).where((t) => t.isNotEmpty).toList();

  bool get _ok => _q.text.trim().isNotEmpty && _filled.length >= 2;

  void _submit() {
    if (!_ok) return;
    Navigator.pop(context, (question: _q.text.trim(), options: _filled));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return InputSheet(
      title: 'New poll',
      body: 'One question, at least two options, six at most.',
      action: 'Send poll',
      enabled: _ok,
      onAction: _submit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetLabel('Question', trailing: '${_q.text.length}/200'),
          TextField(
            controller: _q,
            autofocus: true,
            maxLength: 200,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'What should they pick?',
              counterText: '',
            ),
          ),
          const SizedBox(height: Space.lg),
          SheetLabel('Options'),
          for (var i = 0; i < _opts.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                controller: _opts[i],
                maxLength: 80,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: i == _opts.length - 1
                    ? TextInputAction.done
                    : TextInputAction.next,
                onChanged: (_) => setState(() {}),
                onSubmitted: i == _opts.length - 1 ? (_) => _submit() : null,
                decoration: InputDecoration(
                  hintText: 'Option ${i + 1}',
                  counterText: '',
                ),
              ),
            ),
          if (_opts.length < 6)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () =>
                    setState(() => _opts.add(TextEditingController())),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Add option'),
              ),
            ),
          if (_q.text.trim().isNotEmpty && _filled.length < 2)
            Text('Add a second option to send.', style: Txt.small(p.muted)),
        ],
      ),
    );
  }
}

class _PlaceSheet extends StatefulWidget {
  const _PlaceSheet();

  @override
  State<_PlaceSheet> createState() => _PlaceSheetState();
}

class _PlaceSheetState extends State<_PlaceSheet> {
  final _c = TextEditingController();
  int _minutes = 15;

  static const _choices = [
    (15, '15 min'),
    (60, '1 hour'),
    (180, '3 hours'),
    (480, '8 hours'),
  ];

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = _c.text.trim();
    final until = _choices.firstWhere((c) => c.$1 == _minutes).$2;
    return InputSheet(
      title: 'Live location',
      body: 'People in this chat see your location move on a map until it ends. You can stop it early.',
      action: 'Share for $until',
      enabled: true,
      onAction: () => Navigator.pop(context, (label: label, minutes: _minutes)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetLabel('Note', trailing: '${_c.text.length}/80'),
          TextField(
            controller: _c,
            autofocus: true,
            maxLength: 80,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => Navigator.pop(context, (label: label, minutes: _minutes)),
            decoration: const InputDecoration(
              hintText: 'Optional',
              counterText: '',
            ),
          ),
          const SizedBox(height: Space.lg),
          const SheetLabel('Visible for'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in _choices)
                SheetChip(
                  c.$2,
                  selected: _minutes == c.$1,
                  onTap: () => setState(() => _minutes = c.$1),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
