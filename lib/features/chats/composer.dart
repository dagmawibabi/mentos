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
import '../../net/views.dart';
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
  });

  final String scope;
  final MessageView? replyTo;
  final MessageView? editing;
  final VoidCallback onCancelReply;
  final VoidCallback onCancelEdit;
  final bool enabled;

  @override
  ConsumerState<Composer> createState() => ComposerState();
}

class ComposerState extends ConsumerState<Composer> {
  final _c = TextEditingController();
  final focus = FocusNode();
  final _rec = AudioRecorder();
  bool _recording = false;
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
    if (widget.replyTo != null && widget.replyTo != oldWidget.replyTo) focus.requestFocus();
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
      if (text != widget.editing!.text) await e.edit(widget.scope, widget.editing!.id, text);
      _c.clear();
      widget.onCancelEdit();
      return;
    }
    _c.clear();
    final reply = widget.replyTo?.id;
    widget.onCancelReply();
    HapticFeedback.lightImpact();
    try {
      await e.sendMessage(widget.scope, text: text, replyTo: reply, nsfw: _nsfw);
      if (mounted) setState(() => _nsfw = false);
    } catch (err) {
      if (mounted) toast(context, 'Couldn\'t send: $err');
    }
  }

  Future<void> _sendMedia(List<Pending> picked, {String text = ''}) async {
    if (picked.isEmpty) return;
    setState(() => _busy = true);
    final e = ref.read(engineProvider);
    try {
      final refs = <MediaRef>[];
      for (final x in picked) {
        refs.add(await importPending(e, x, scope: widget.scope));
      }
      final reply = widget.replyTo?.id;
      widget.onCancelReply();
      await e.sendMessage(widget.scope, media: refs, text: text, replyTo: reply, nsfw: _nsfw);
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
      SheetAction(Icons.photo_outlined, 'Photos', () async => _sendMedia(await pickImages())),
      SheetAction(Icons.photo_camera_outlined, 'Camera', () async {
        final x = await takePhoto();
        if (x != null) await _sendMedia([x]);
      }),
      SheetAction(Icons.videocam_outlined, 'Video', () async {
        final x = await pickVideo();
        if (x != null) await _sendMedia([x]);
      }),
      SheetAction(Icons.attach_file_rounded, 'File', () async => _sendMedia(await pickFiles(e.media))),
      SheetAction(Icons.poll_outlined, 'Poll', _newPoll),
    ], title: 'ATTACH');
  }

  Future<void> _newPoll() async {
    final q = TextEditingController();
    final opts = [TextEditingController(), TextEditingController()];
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final p = ctx.pal;
        return Padding(
          padding: EdgeInsets.fromLTRB(
              Space.gutter, 0, Space.gutter, Space.lg + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('New poll', style: Txt.heading(p.ink)),
              const SizedBox(height: Space.md),
              TextField(controller: q, autofocus: true, decoration: const InputDecoration(hintText: 'Question')),
              for (var i = 0; i < opts.length; i++)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TextField(controller: opts[i], decoration: InputDecoration(hintText: 'Option ${i + 1}')),
                ),
              if (opts.length < 6)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => set(() => opts.add(TextEditingController())),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Add option'),
                  ),
                ),
              const SizedBox(height: Space.sm),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Send poll')),
            ],
          ),
        );
      }),
    );
    if (ok != true) return;
    final options = opts.map((c) => c.text.trim()).where((t) => t.isNotEmpty).toList();
    if (options.length < 2) return;
    await ref.read(engineProvider).sendMessage(widget.scope, poll: Poll(q.text.trim(), options), nsfw: _nsfw);
    if (mounted) setState(() => _nsfw = false);
  }

  Future<void> _startRecording() async {
    if (!await _rec.hasPermission()) {
      if (mounted) toast(context, 'Microphone permission is needed for voice messages.');
      return;
    }
    final e = ref.read(engineProvider);
    _recPath = e.media.newTmpPath('.m4a');
    await _rec.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000, sampleRate: 44100), path: _recPath!);
    HapticFeedback.mediumImpact();
    _levels.clear();
    _amp = _rec.onAmplitudeChanged(const Duration(milliseconds: 90)).listen((a) {
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
    final ms = DateTime.now().difference(_recStart ?? DateTime.now()).inMilliseconds;
    setState(() => _recording = false);
    if (!send || path == null || ms < 700) {
      if (path != null) await File(path).delete().catchError((_) => File(path));
      return;
    }
    const bars = 40;
    final wave = List<int>.generate(bars, (i) {
      if (_levels.isEmpty) return 10;
      final start = (i * _levels.length / bars).floor();
      final end = math.max(start + 1, ((i + 1) * _levels.length / bars).floor());
      final slice = _levels.sublist(start, math.min(end, _levels.length));
      final avg = slice.isEmpty ? 0.0 : slice.reduce((a, b) => a + b) / slice.length;
      return (8 + avg * 92).round();
    });
    await _sendMedia([
      Pending(File(path), 'voice-${DateTime.now().millisecondsSinceEpoch}.m4a', durationMs: ms, wave: wave, temp: true),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final hasText = _c.text.trim().isNotEmpty;

    return Container(
      decoration: BoxDecoration(color: p.bg, border: Border(top: BorderSide(color: p.line))),
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
                    Container(width: 2.5, height: 32, color: widget.editing != null ? p.ink : p.accent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.editing != null ? 'Editing' : 'Replying to ${e.nameOf(widget.replyTo!.author)}',
                            style: Txt.small(p.ink).copyWith(fontWeight: FontWeight.w600),
                          ),
                          Text(previewOf(widget.editing ?? widget.replyTo!),
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.small(p.muted)),
                        ],
                      ),
                    ),
                    IconBtn(Icons.close_rounded, size: 18, color: p.muted, onTap: () {
                      if (widget.editing != null) {
                        _c.clear();
                        widget.onCancelEdit();
                      } else {
                        widget.onCancelReply();
                      }
                    }),
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
        IconBtn(Icons.add_rounded, tooltip: 'Attach', onTap: widget.enabled && !_busy ? _attach : null),
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
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
              disabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
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
                    decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle),
                    child: Icon(widget.editing != null ? Icons.check_rounded : Icons.arrow_upward_rounded,
                        color: p.accentInk, size: 22),
                  ),
                )
              : GestureDetector(
                  key: const ValueKey('mic'),
                  onTap: widget.enabled && !_busy ? _startRecording : null,
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Icon(Icons.mic_none_rounded, color: widget.enabled ? p.ink : p.faint),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _recordingBar(Palette p) {
    final ms = DateTime.now().difference(_recStart ?? DateTime.now()).inMilliseconds;
    final recent = _levels.length > 32 ? _levels.sublist(_levels.length - 32) : _levels;
    return Row(
      children: [
        IconBtn(Icons.delete_outline_rounded, color: p.danger, onTap: () => _stopRecording(send: false)),
        Container(width: 8, height: 8, decoration: BoxDecoration(color: p.danger, shape: BoxShape.circle)),
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
                    decoration: BoxDecoration(color: p.ink, borderRadius: BorderRadius.circular(2)),
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
            child: Icon(Icons.arrow_upward_rounded, color: p.accentInk, size: 22),
          ),
        ),
      ],
    );
  }
}
