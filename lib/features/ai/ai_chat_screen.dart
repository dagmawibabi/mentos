import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../ai/ai.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../state/providers.dart';
import '../../widgets/ui.dart';
import 'ai_sheets.dart';

/// The identity's AI settings and chats.
final aiStoreProvider = Provider<AiStore?>((ref) {
  final e = ref.watch(maybeEngineProvider);
  if (e == null) return null;
  final store = AiStore(e.db);
  ref.onDispose(store.dispose);
  return store;
});

const _suggestions = [
  'Summarize the main ideas of peer-to-peer networking',
  'Write a friendly message inviting friends to Mentos',
  'Explain end-to-end encryption like I am twelve',
  'Plan a weekend trip to Lalibela on a budget',
  'Draft a product description for a handmade coffee mug',
  'What questions should I ask before renting out storage?',
  'Give me five creative post ideas for this week',
];

class AiChatScreen extends ConsumerStatefulWidget {
  const AiChatScreen({super.key, this.conversation});
  final String? conversation;

  @override
  ConsumerState<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends ConsumerState<AiChatScreen> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _pending = <AiAttachment>[];
  late AiConversation _conv;
  AiClient? _client;
  bool _streaming = false;
  bool _follow = true;
  Timer? _paint;

  @override
  void initState() {
    super.initState();
    final store = ref.read(aiStoreProvider);
    final id = widget.conversation;
    _conv = (id == null ? null : store?.conversation(id)) ?? AiConversation(id: _newId());
    _input.addListener(() => setState(() {}));
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      _follow = _scroll.position.pixels >= _scroll.position.maxScrollExtent - 80;
    });
    // Warm the model list so the picker opens instantly.
    if (store != null) unawaited(store.models(store.gateway).then((_) {}, onError: (_) {}));
  }

  @override
  void dispose() {
    _client?.cancel();
    _paint?.cancel();
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  static String _newId() {
    final r = Random.secure();
    return List.generate(12, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  void _toBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      if (animate) {
        _scroll.animateTo(end, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      } else {
        _scroll.jumpTo(end);
      }
    });
  }

  Future<void> _attach({required bool images}) async {
    final store = ref.read(aiStoreProvider);
    if (store == null) return;
    final picked = <(String, String)>[];
    if (images) {
      final xs = await ImagePicker().pickMultiImage(maxWidth: 2048, imageQuality: 88);
      picked.addAll([for (final x in xs) (x.path, x.name)]);
    } else {
      final files = await FilePicker.pickFiles();
      picked.addAll([
        for (final f in files)
          if (f.path != null) (f.path!, f.name),
      ]);
    }
    if (picked.isEmpty) return;
    final dir = Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}ai_files');
    await dir.create(recursive: true);
    for (final (path, name) in picked.take(8)) {
      final src = File(path);
      final size = await src.length();
      if (size > 20 * 1024 * 1024) {
        if (mounted) toast(context, '$name is over 20 MB');
        continue;
      }
      final copy = await src.copy('${dir.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}_$name');
      _pending.add(AiAttachment(path: copy.path, name: name, mime: AiAttachment.mimeOf(name), size: size));
    }
    if (mounted) setState(() {});
  }

  Future<void> _send([String? preset]) async {
    final store = ref.read(aiStoreProvider);
    if (store == null || _streaming) return;
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty && _pending.isEmpty) return;
    if (!store.ready) {
      await showAiSettings(context, store);
      if (!store.ready) return;
    }
    final model = store.find(store.model);
    if (_pending.any((a) => a.isImage) && model != null && !model.images) {
      final ok = await confirm(
        context,
        title: '${model.name} can\'t see images',
        body: 'Send anyway, or pick a model with the image icon.',
        action: 'Send anyway',
      );
      if (!ok) return;
    }
    _conv.messages.add(AiMessage(role: 'user', text: text, attachments: List.of(_pending)));
    _pending.clear();
    _input.clear();
    _follow = true;
    await _run();
  }

  Future<void> _run() async {
    final store = ref.read(aiStoreProvider)!;
    final modelId = store.model ?? store.gateway.autoModel;
    final reply = AiMessage(role: 'assistant', text: '', model: modelId);
    _conv.messages.add(reply);
    setState(() => _streaming = true);
    _toBottom();
    final client = AiClient(gateway: store.gateway, apiKey: store.keyFor(store.gateway));
    _client = client;
    try {
      final history = _conv.messages.where((m) => m != reply && m.error == null).toList();
      final messages = await AiClient.buildMessages(history, system: store.systemPrompt);
      final reasoning = store.find(store.model)?.reasoning ?? false;
      await for (final d in client.stream(model: modelId, messages: messages, reasoning: reasoning)) {
        reply.text += d.text;
        reply.reasoning += d.reasoning;
        if (d.model != null) reply.model = d.model;
        // Repaint at most ~30 times a second while tokens pour in.
        _paint ??= Timer(const Duration(milliseconds: 33), () {
          _paint = null;
          if (!mounted) return;
          setState(() {});
          if (_follow) _toBottom(animate: false);
        });
      }
      if (reply.text.isEmpty && reply.reasoning.isEmpty && _client != null) reply.error = 'The model sent back nothing.';
    } catch (e) {
      reply.error = '$e';
    } finally {
      _client = null;
      _paint?.cancel();
      _paint = null;
      store.save(_conv);
      if (mounted) {
        setState(() => _streaming = false);
        if (_follow) _toBottom();
      }
    }
  }

  void _stop() {
    _client?.cancel();
    _client = null;
  }

  Future<void> _regenerate() async {
    if (_streaming || _conv.messages.isEmpty) return;
    if (_conv.messages.last.role == 'assistant') _conv.messages.removeLast();
    await _run();
  }

  void _newChat() {
    if (_streaming) _stop();
    setState(() {
      _conv = AiConversation(id: _newId());
      _pending.clear();
    });
  }

  Future<void> _history(AiStore store) async {
    final picked = await showAiHistory(context, store, current: _conv.id);
    if (picked == null || !mounted) return;
    final c = store.conversation(picked);
    if (c == null) return;
    if (_streaming) _stop();
    setState(() => _conv = c);
    _toBottom(animate: false);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final store = ref.watch(aiStoreProvider);
    if (store == null) return const Scaffold(body: Loading());
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final model = store.find(store.model);
        final msgs = _conv.messages;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Mentos AI'),
            actions: [
              IconBtn(Icons.history_rounded, tooltip: 'Chats', onTap: () => _history(store)),
              IconBtn(Icons.add_comment_outlined, tooltip: 'New chat', onTap: msgs.isEmpty ? null : _newChat),
              IconBtn(Icons.tune_rounded, tooltip: 'AI settings', onTap: () => showAiSettings(context, store)),
              const SizedBox(width: 6),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: msgs.isEmpty
                    ? _Welcome(ready: store.ready, gateway: store.gateway, onPick: (s) => _send(s), onSettings: () => showAiSettings(context, store))
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, Space.lg),
                        itemCount: msgs.length,
                        itemBuilder: (_, i) {
                          final m = msgs[i];
                          final last = i == msgs.length - 1;
                          return m.role == 'user'
                              ? _UserBubble(m)
                              : _AssistantTurn(
                                  m,
                                  streaming: last && _streaming,
                                  onRegenerate: last && !_streaming ? _regenerate : null,
                                  modelName: store.find(m.model)?.name ?? m.model,
                                );
                        },
                      ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Space.gutter, 4, Space.gutter, Space.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _Chip(
                            icon: Icons.memory_rounded,
                            label: model?.name ?? 'Auto',
                            trailing: Icons.expand_more_rounded,
                            onTap: () => showModelPicker(context, store),
                          ),
                          const SizedBox(width: Space.sm),
                          _Chip(
                            icon: store.ready ? Icons.vpn_key_outlined : Icons.key_off_outlined,
                            label: store.ready ? store.gateway.label : 'Add a key',
                            highlight: !store.ready,
                            onTap: () => showAiSettings(context, store),
                          ),
                        ],
                      ),
                      if (_pending.isNotEmpty) ...[
                        const SizedBox(height: Space.sm),
                        SizedBox(
                          height: 64,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              for (final a in _pending)
                                _AttachmentChip(a, onRemove: () => setState(() => _pending.remove(a))),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: Space.sm),
                      Container(
                        padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
                        decoration: BoxDecoration(
                          color: p.surface,
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(color: _focus.hasFocus ? p.accent.withValues(alpha: .6) : p.line),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(bottom: 13),
                              child: Icon(Icons.auto_awesome_outlined, size: 20, color: p.muted),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Focus(
                                onFocusChange: (_) => setState(() {}),
                                child: TextField(
                                  controller: _input,
                                  focusNode: _focus,
                                  minLines: 1,
                                  maxLines: 6,
                                  textCapitalization: TextCapitalization.sentences,
                                  decoration: const InputDecoration(
                                    hintText: 'Ask anything…',
                                    border: InputBorder.none,
                                    enabledBorder: InputBorder.none,
                                    focusedBorder: InputBorder.none,
                                    filled: false,
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(vertical: 14),
                                  ),
                                  onSubmitted: (_) => _send(),
                                ),
                              ),
                            ),
                            PopupMenuButton<String>(
                              tooltip: 'Attach',
                              icon: Icon(Icons.attach_file_rounded, color: p.inkSoft),
                              onSelected: (v) => _attach(images: v == 'img'),
                              itemBuilder: (_) => const [
                                PopupMenuItem(value: 'img', child: ListTile(dense: true, leading: Icon(Icons.image_outlined), title: Text('Photos'))),
                                PopupMenuItem(value: 'file', child: ListTile(dense: true, leading: Icon(Icons.description_outlined), title: Text('Files'))),
                              ],
                            ),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: _SendButton(
                                streaming: _streaming,
                                enabled: _streaming || _input.text.trim().isNotEmpty || _pending.isNotEmpty,
                                onSend: () => _send(),
                                onStop: _stop,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.ready, required this.gateway, required this.onPick, required this.onSettings});
  final bool ready;
  final AiGateway gateway;
  final ValueChanged<String> onPick;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return ListView(
      padding: const EdgeInsets.fromLTRB(Space.gutter, Space.xl, Space.gutter, Space.lg),
      children: [
        if (!ready)
          Container(
            margin: const EdgeInsets.only(bottom: Space.xl),
            padding: const EdgeInsets.all(Space.lg),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: LinearGradient(colors: [const Color(0xFF6366F1).withValues(alpha: .14), const Color(0xFF0EA5E9).withValues(alpha: .08)]),
              border: Border.all(color: p.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Bring your own key', style: Txt.bodyStrong(p.ink)),
                const SizedBox(height: 4),
                Text(
                  'Paste an OpenRouter or Vercel AI Gateway key to chat with hundreds of models. '
                  'The key stays in this phone\'s encrypted database and is only sent to the gateway you pick.',
                  style: Txt.small(p.inkSoft),
                ),
                const SizedBox(height: Space.md),
                FilledButton.icon(onPressed: onSettings, icon: const Icon(Icons.vpn_key_outlined, size: 18), label: const Text('Add a key')),
              ],
            ),
          ),
        Text('Prompt suggestions…', style: Txt.body(p.muted)),
        const SizedBox(height: Space.md),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in _suggestions)
              Material(
                color: p.surface,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: BorderSide(color: p.line)),
                child: InkWell(
                  customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                  onTap: () => onPick(s),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                    child: Text(s, style: Txt.body(p.ink).copyWith(fontSize: 14.5)),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label, required this.onTap, this.trailing, this.highlight = false});
  final IconData icon;
  final String label;
  final IconData? trailing;
  final VoidCallback onTap;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Flexible(
      child: Material(
        color: highlight ? p.accentSoft : p.surface,
        shape: StadiumBorder(side: BorderSide(color: highlight ? p.accent : p.line)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: highlight ? p.accent : p.inkSoft),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.small(p.ink).copyWith(fontWeight: FontWeight.w600)),
                ),
                if (trailing != null) ...[const SizedBox(width: 2), Icon(trailing, size: 16, color: p.muted)],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.streaming, required this.enabled, required this.onSend, required this.onStop});
  final bool streaming;
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return AnimatedContainer(
      duration: Motion.fast,
      width: 44,
      height: 44,
      decoration: BoxDecoration(shape: BoxShape.circle, color: enabled ? p.ink : p.raised),
      child: IconButton(
        tooltip: streaming ? 'Stop' : 'Send',
        onPressed: !enabled ? null : (streaming ? onStop : onSend),
        icon: Icon(streaming ? Icons.stop_rounded : Icons.arrow_upward_rounded, color: enabled ? p.bg : p.faint),
      ),
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip(this.a, {this.onRemove});
  final AiAttachment a;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: a.isImage ? 64 : 150,
            height: 64,
            decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: p.line)),
            clipBehavior: Clip.antiAlias,
            child: a.isImage
                ? Image.file(File(a.path), fit: BoxFit.cover)
                : Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      children: [
                        Icon(a.isPdf ? Icons.picture_as_pdf_outlined : Icons.description_outlined, color: a.isPdf ? p.danger : p.inkSoft),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.small(p.ink)),
                              Text(_size(a.size), style: Txt.mono(p.muted, size: 10)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
          if (onRemove != null)
            Positioned(
              right: -6,
              top: -6,
              child: GestureDetector(
                onTap: onRemove,
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(color: p.ink, shape: BoxShape.circle, border: Border.all(color: p.bg, width: 2)),
                  child: Icon(Icons.close_rounded, size: 12, color: p.bg),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

String _size(int b) => b < 1024 ? '$b B' : (b < 1048576 ? '${(b / 1024).toStringAsFixed(0)} KB' : '${(b / 1048576).toStringAsFixed(1)} MB');

class _UserBubble extends StatelessWidget {
  const _UserBubble(this.m);
  final AiMessage m;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md, left: 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (m.attachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 6,
                runSpacing: 6,
                children: [for (final a in m.attachments) _AttachmentChip(a)],
              ),
            ),
          if (m.text.isNotEmpty)
            GestureDetector(
              onLongPress: () {
                Clipboard.setData(ClipboardData(text: m.text));
                toast(context, 'Copied');
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: p.bubbleMine,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(20),
                    topRight: Radius.circular(20),
                    bottomLeft: Radius.circular(20),
                    bottomRight: Radius.circular(6),
                  ),
                ),
                child: SelectableText(m.text, style: Txt.body(p.bubbleMineInk)),
              ),
            ),
        ],
      ),
    );
  }
}

class _AssistantTurn extends StatefulWidget {
  const _AssistantTurn(this.m, {required this.streaming, this.onRegenerate, this.modelName});
  final AiMessage m;
  final bool streaming;
  final VoidCallback? onRegenerate;
  final String? modelName;

  @override
  State<_AssistantTurn> createState() => _AssistantTurnState();
}

class _AssistantTurnState extends State<_AssistantTurn> {
  bool _showThoughts = false;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final m = widget.m;
    final waiting = widget.streaming && m.text.isEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.modelName ?? 'Assistant', maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.mono(p.muted, size: 11)),
          const SizedBox(height: 6),
          if (m.reasoning.isNotEmpty)
            GestureDetector(
              onTap: () => setState(() => _showThoughts = !_showThoughts),
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(12)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.psychology_outlined, size: 16, color: p.muted),
                        const SizedBox(width: 6),
                        Text(widget.streaming && m.text.isEmpty ? 'Thinking…' : 'Thoughts', style: Txt.small(p.muted).copyWith(fontWeight: FontWeight.w600)),
                        const Spacer(),
                        Icon(_showThoughts ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18, color: p.muted),
                      ],
                    ),
                    if (_showThoughts) ...[
                      const SizedBox(height: 6),
                      Text(m.reasoning, style: Txt.small(p.muted)),
                    ],
                  ],
                ),
              ),
            ),
          if (waiting && m.reasoning.isEmpty)
            const _Typing()
          else if (m.text.isNotEmpty)
            AiMarkdown(widget.streaming ? '${m.text} ▍' : m.text),
          if (m.error != null)
            Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.all(Space.md),
              decoration: BoxDecoration(color: p.dangerSoft, borderRadius: BorderRadius.circular(14)),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline_rounded, size: 18, color: p.danger),
                  const SizedBox(width: 8),
                  Expanded(child: Text(m.error!, style: Txt.small(p.danger))),
                ],
              ),
            ),
          if (!widget.streaming && (m.text.isNotEmpty || m.error != null))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  if (m.text.isNotEmpty)
                    IconBtn(Icons.copy_rounded, size: 16, color: p.muted, tooltip: 'Copy', onTap: () {
                      Clipboard.setData(ClipboardData(text: m.text));
                      toast(context, 'Copied');
                    }),
                  if (widget.onRegenerate != null) IconBtn(Icons.refresh_rounded, size: 17, color: p.muted, tooltip: 'Regenerate', onTap: widget.onRegenerate),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Typing extends StatefulWidget {
  const _Typing();

  @override
  State<_Typing> createState() => _TypingState();
}

class _TypingState extends State<_Typing> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return SizedBox(
      height: 22,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => Row(
          children: [
            for (var i = 0; i < 3; i++)
              Container(
                width: 7,
                height: 7,
                margin: const EdgeInsets.only(right: 5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: p.muted.withValues(alpha: .35 + .65 * (sin((_c.value * 2 * pi) - i * .9) + 1) / 2),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Markdown in the app's type and colors, with code blocks you can copy.
class AiMarkdown extends StatelessWidget {
  const AiMarkdown(this.data, {super.key});
  final String data;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final body = Txt.body(p.ink).copyWith(height: 1.5);
    return MarkdownBody(
      data: data,
      selectable: true,
      softLineBreak: true,
      onTapLink: (_, href, _) {
        final u = Uri.tryParse(href ?? '');
        if (u != null && (u.scheme == 'https' || u.scheme == 'http')) launchUrl(u, mode: LaunchMode.externalApplication);
      },
      styleSheet: MarkdownStyleSheet(
        p: body,
        a: body.copyWith(color: p.accent, decoration: TextDecoration.underline),
        strong: body.copyWith(fontWeight: FontWeight.w700),
        em: body.copyWith(fontStyle: FontStyle.italic),
        h1: Txt.title(p.ink).copyWith(fontSize: 22),
        h2: Txt.title(p.ink).copyWith(fontSize: 19),
        h3: Txt.heading(p.ink),
        h4: Txt.bodyStrong(p.ink),
        listBullet: body,
        blockSpacing: 10,
        code: Txt.mono(p.ink, size: 13).copyWith(backgroundColor: p.raised),
        codeblockPadding: const EdgeInsets.all(12),
        codeblockDecoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(12), border: Border.all(color: p.line)),
        blockquote: body.copyWith(color: p.inkSoft),
        blockquoteDecoration: BoxDecoration(border: Border(left: BorderSide(color: p.accent, width: 3))),
        blockquotePadding: const EdgeInsets.only(left: 12),
        tableHead: body.copyWith(fontWeight: FontWeight.w700),
        tableBody: body,
        tableBorder: TableBorder.all(color: p.line),
        tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        horizontalRuleDecoration: BoxDecoration(border: Border(top: BorderSide(color: p.line))),
      ),
    );
  }
}
