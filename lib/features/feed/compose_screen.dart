import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/views.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/media.dart';
import '../../widgets/ui.dart';
import '../common/attach.dart';
import 'post_card.dart';

class ComposeScreen extends ConsumerStatefulWidget {
  const ComposeScreen({super.key, this.spaceId, this.boardId, this.channelId, this.bcastId, this.repostId});
  final String? spaceId;
  final String? boardId;
  final String? channelId;
  final String? bcastId;
  final String? repostId;

  @override
  ConsumerState<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends ConsumerState<ComposeScreen> {
  final _text = TextEditingController();
  final _title = TextEditingController();
  final _attachments = <Pending>[];
  List<TextEditingController>? _poll;
  final _question = TextEditingController();
  late bool _keep = ref.read(settingsProvider).keepPosts;
  bool _ai = false;
  bool _nsfw = false;
  bool _busy = false;

  bool get _canPost =>
      !_busy &&
      (_text.text.trim().isNotEmpty ||
          _title.text.trim().isNotEmpty ||
          _attachments.isNotEmpty ||
          widget.repostId != null ||
          (_poll != null && _poll!.where((c) => c.text.trim().isNotEmpty).length >= 2));

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
    _title.addListener(() => setState(() {}));
  }

  Future<void> _add(Future<List<Pending>> f) async {
    final picked = await f;
    if (picked.isEmpty) return;
    setState(() => _attachments.addAll(picked.take(10 - _attachments.length)));
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    final e = ref.read(engineProvider);
    final scope = widget.bcastId != null
        ? Scope.bcast(e.me.id, widget.bcastId!)
        : widget.channelId != null && widget.spaceId != null
            ? Scope.channel(widget.spaceId!, widget.channelId!)
            : widget.boardId != null && widget.spaceId != null
                ? Scope.forum(widget.spaceId!, widget.boardId!)
                : widget.spaceId == null
                    ? Scope.feed(e.me.id)
                    : Scope.spaceFeed(widget.spaceId!);
    final media = <MediaRef>[];
    for (final a in _attachments) {
      media.add(await importPending(e, a, scope: scope));
    }
    Poll? poll;
    if (_poll != null) {
      final opts = _poll!.map((c) => c.text.trim()).where((t) => t.isNotEmpty).toList();
      if (opts.length >= 2) poll = Poll(_question.text.trim(), opts);
    }
    Map<String, dynamic>? repost;
    if (widget.repostId != null) {
      final orig = e.post(widget.repostId!);
      if (orig != null) {
        repost = {
          'id': orig.id,
          'author': orig.author,
          'text': orig.text.length > 280 ? '${orig.text.substring(0, 280)}…' : orig.text,
        };
      }
    }
    try {
    await e.createPost(
      text: _text.text.trim(),
      media: media,
      poll: poll,
      keep: _keep,
      spaceId: widget.spaceId,
      boardId: widget.boardId,
      channelId: widget.channelId,
      bcastId: widget.bcastId,
      title: _title.text.trim(),
      repost: repost,
      ai: _ai,
      nsfw: _nsfw,
    );
    if (mounted) context.pop();
    } catch (err) {
      if (mounted) {
        setState(() => _busy = false);
        toast(context, 'Could not post: $err');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final space = widget.spaceId == null ? null : ref.watch(spaceProvider(widget.spaceId!)).value;
    final repost = widget.repostId == null ? null : ref.watch(postProvider(widget.repostId!)).value;

    return Scaffold(
      appBar: AppBar(
        leading: IconBtn(Icons.close_rounded, onTap: () => context.pop()),
        title: Text(
          widget.boardId != null
              ? 'New thread'
              : widget.channelId != null || widget.bcastId != null
                  ? 'Broadcast'
                  : space == null
                      ? 'New post'
                      : 'Post in ${space.name}',
          style: Txt.heading(p.ink),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: Space.md),
            child: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 38)),
              onPressed: _canPost ? _submit : null,
              child: Text(_busy ? 'Posting…' : 'Post'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, Space.xl),
              children: [
                if (widget.boardId != null)
                  TextField(
                    controller: _title,
                    style: Txt.heading(p.ink),
                    decoration: const InputDecoration(
                      hintText: 'Thread title',
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                    ),
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Avatar(id: e.me.id, size: 38, presence: false),
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: TextField(
                        controller: _text,
                        autofocus: true,
                        maxLines: null,
                        minLines: 3,
                        maxLength: 2000,
                        style: Txt.body(p.ink).copyWith(fontSize: 17),
                        decoration: const InputDecoration(
                          hintText: 'What\'s on your mind?',
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.only(top: 8),
                          counterText: '',
                        ),
                      ),
                    ),
                  ],
                ),
                if (repost != null) ...[
                  const SizedBox(height: Space.md),
                  RepostEmbed(data: {'id': repost.id, 'author': repost.author, 'text': repost.text}),
                ],
                if (_attachments.isNotEmpty) ...[
                  const SizedBox(height: Space.md),
                  SizedBox(
                    height: 110,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _attachments.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (_, i) => _AttachmentPreview(
                        a: _attachments[i],
                        onRemove: () => setState(() => _attachments.removeAt(i)),
                      ),
                    ),
                  ),
                ],
                if (_poll != null) ...[
                  const SizedBox(height: Space.lg),
                  _PollEditor(
                    question: _question,
                    options: _poll!,
                    onChanged: () => setState(() {}),
                    onRemove: () => setState(() => _poll = null),
                  ),
                ],
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(border: Border(top: BorderSide(color: p.line))),
            child: SafeArea(
              top: false,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Space.gutter, 8, Space.md, 4),
                    child: Column(
                      children: [
                        if (widget.spaceId == null)
                          _ToggleRow(
                            icon: _keep ? Icons.cloud_done_outlined : Icons.phone_android_rounded,
                            label: _keep ? 'Followers may keep a copy' : 'Only on this phone',
                            value: _keep,
                            onChanged: (v) => setState(() => _keep = v),
                          ),
                        _ToggleRow(
                          icon: Icons.auto_awesome_outlined,
                          label: 'AI generated',
                          value: _ai,
                          onChanged: (v) => setState(() => _ai = v),
                        ),
                        _ToggleRow(
                          icon: Icons.visibility_off_outlined,
                          label: 'NSFW',
                          value: _nsfw,
                          onChanged: (v) => setState(() => _nsfw = v),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      const SizedBox(width: Space.sm),
                      IconBtn(Icons.photo_outlined, tooltip: 'Photos', onTap: () => _add(pickImages())),
                      IconBtn(Icons.photo_camera_outlined, tooltip: 'Camera', onTap: () async {
                        final x = await takePhoto();
                        if (x != null) setState(() => _attachments.add(x));
                      }),
                      IconBtn(Icons.videocam_outlined, tooltip: 'Video', onTap: () async {
                        final x = await pickVideo();
                        if (x != null) setState(() => _attachments.add(x));
                      }),
                      IconBtn(Icons.attach_file_rounded,
                          tooltip: 'File', onTap: () => _add(pickFiles(ref.read(engineProvider).media))),
                      IconBtn(Icons.poll_outlined, tooltip: 'Poll', active: _poll != null, onTap: () {
                        setState(() => _poll ??= [TextEditingController(), TextEditingController()]);
                      }),
                      const Spacer(),
                      Padding(
                        padding: const EdgeInsets.only(right: Space.gutter),
                        child: Text('${_text.text.length}/2000', style: Txt.mono(p.faint, size: 11)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AttachmentPreview extends StatelessWidget {
  const _AttachmentPreview({required this.a, required this.onRemove});
  final Pending a;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.md),
          child: Container(
            width: a.isImage ? 110 * ((a.width ?? 1) / (a.height ?? 1)).clamp(.6, 1.6) : 140,
            height: 110,
            color: p.raised,
            child: a.isImage
                ? Image.file(a.file, fit: BoxFit.cover)
                : Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(fileIcon(a.mime), color: p.ink),
                        const Spacer(),
                        Text(a.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: Txt.small(p.ink)),
                        FutureBuilder<int>(
                          future: a.file.length(),
                          builder: (_, s) => Text(s.hasData ? bytes(s.data!) : '', style: Txt.mono(p.muted, size: 10)),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
        Positioned(
          right: 4,
          top: 4,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              width: 24,
              height: 24,
              decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
              child: const Icon(Icons.close_rounded, size: 15, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({required this.icon, required this.label, required this.value, required this.onChanged});
  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: value ? p.accent : p.muted),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: Txt.small(p.ink).copyWith(fontWeight: FontWeight.w500))),
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ),
    );
  }
}

class _PollEditor extends StatelessWidget {
  const _PollEditor({required this.question, required this.options, required this.onChanged, required this.onRemove});
  final TextEditingController question;
  final List<TextEditingController> options;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(Radii.lg), border: Border.all(color: p.line)),
      child: Column(
        children: [
          Row(
            children: [
              Text('POLL', style: Txt.label(p.muted)),
              const Spacer(),
              GestureDetector(onTap: onRemove, child: Icon(Icons.close_rounded, size: 18, color: p.muted)),
            ],
          ),
          const SizedBox(height: Space.sm),
          TextField(controller: question, decoration: const InputDecoration(hintText: 'Question (optional)')),
          for (var i = 0; i < options.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                controller: options[i],
                onChanged: (_) => onChanged(),
                maxLength: 60,
                decoration: InputDecoration(
                  hintText: 'Option ${i + 1}',
                  counterText: '',
                  suffixIcon: options.length > 2
                      ? GestureDetector(
                          onTap: () {
                            options.removeAt(i);
                            onChanged();
                          },
                          child: Icon(Icons.remove_circle_outline_rounded, size: 18, color: p.faint),
                        )
                      : null,
                ),
              ),
            ),
          if (options.length < 6)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  options.add(TextEditingController());
                  onChanged();
                },
                icon: Icon(Icons.add_rounded, size: 18, color: p.ink),
                label: const Text('Add option'),
              ),
            ),
        ],
      ),
    );
  }
}