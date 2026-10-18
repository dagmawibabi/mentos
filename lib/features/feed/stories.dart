import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/device_access.dart';
import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/views.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/media.dart';
import '../../widgets/nsfw.dart';
import '../../widgets/ui.dart';
import 'story_stickers.dart';

const storyColors = [
  Color(0xFF0D1110),
  Color(0xFF0E9F6E),
  Color(0xFF2B3A55),
  Color(0xFF5B3E2E),
  Color(0xFF4A2E57),
  Color(0xFF7A7F7C),
];

class StoriesBar extends ConsumerWidget {
  const StoriesBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.watch(maybeEngineProvider);
    if (e == null) return const SizedBox.shrink();
    final groups = ref.watch(storiesProvider).value ?? const <StoryGroup>[];
    final hasMine = groups.any((g) => g.author == e.me.id);
    final others = groups.where((g) => g.author != e.me.id).toList();

    return SizedBox(
      height: 104,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, Space.sm),
        children: [
          _Bubble(
            id: e.me.id,
            label: 'Your story',
            // Your own live story gets the same accent ring others see.
            seen: false,
            ring: hasMine,
            add: true,
            onTap: () => context.push(hasMine ? '/story/${e.me.id}' : '/story/new'),
            onLongPress: () => context.push('/story/new'),
          ),
          for (final g in others)
            _Bubble(
              id: g.author,
              label: e.nameOf(g.author),
              seen: g.allSeen,
              ring: true,
              onTap: () => context.push('/story/${g.author}'),
            ),
          if (others.isEmpty)
            Padding(
              padding: const EdgeInsets.only(left: Space.sm, top: 18),
              child: Text('Stories last 24h and\nlive on their author\'s phone',
                  style: Txt.mono(p.faint, size: 11)),
            ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.id,
    required this.label,
    required this.seen,
    required this.onTap,
    this.ring = true,
    this.add = false,
    this.onLongPress,
  });
  final String id;
  final String label;
  final bool seen;
  final bool ring;
  final bool add;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      child: SizedBox(
        width: 70,
        child: Column(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  padding: const EdgeInsets.all(2.5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: !ring ? Colors.transparent : (seen ? p.line : p.accent),
                      width: 2,
                    ),
                  ),
                  child: Avatar(id: id, size: 50, presence: false),
                ),
                if (add)
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: p.ink,
                        shape: BoxShape.circle,
                        border: Border.all(color: p.bg, width: 2),
                      ),
                      child: Icon(Icons.add_rounded, size: 13, color: p.bg),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 5),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.mono(p.muted, size: 10.5)),
          ],
        ),
      ),
    );
  }
}

class StoryViewer extends ConsumerStatefulWidget {
  const StoryViewer({super.key, required this.author});
  final String author;

  @override
  ConsumerState<StoryViewer> createState() => _StoryViewerState();
}

class _StoryViewerState extends ConsumerState<StoryViewer> with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(vsync: this, duration: const Duration(seconds: 6))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) _next();
    });
  int _i = 0;
  List<Item> _stories = const [];
  bool _reacting = false;

  /// The story question being answered, if the reply came from one.
  String? _asking;
  final _replyFocus = FocusNode();

  @override
  void dispose() {
    _anim.dispose();
    _reply.dispose();
    _replyFocus.dispose();
    super.dispose();
  }

  void _ask(String question) {
    _anim.stop();
    setState(() => _asking = question);
    _replyFocus.requestFocus();
  }

  void _next() {
    if (_i < _stories.length - 1) {
      setState(() => _i++);
      _start();
    } else {
      if (mounted) context.pop();
    }
  }

  void _prev() {
    if (_i > 0) {
      setState(() => _i--);
      _start();
    } else {
      _anim.forward(from: 0);
    }
  }

  final _reply = TextEditingController();

  void _start() {
    if (_stories.isEmpty) return;
    _asking = null;
    _reacting = false;
    final e = ref.read(engineProvider);
    e.markStorySeen(_stories[_i].id);
    e.recordView(_stories[_i]);
    _anim.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final e = ref.read(engineProvider);
    final groups = ref.watch(storiesProvider).value ?? const <StoryGroup>[];
    final g = groups.where((x) => x.author == widget.author).firstOrNull;
    if (g == null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('This story is gone', style: Txt.heading(Colors.white)),
              const SizedBox(height: 8),
              Text('It expired or its author went offline.', style: Txt.small(Colors.white60)),
              const SizedBox(height: 16),
              TextButton(onPressed: () => context.pop(), child: Text('Close', style: Txt.bodyStrong(Colors.white))),
            ],
          ),
        ),
      );
    }
    final first = _stories.isEmpty;
    _stories = g.stories;
    if (_i >= _stories.length) _i = _stories.length - 1;
    if (first) WidgetsBinding.instance.addPostFrameCallback((_) => _start());
    final s = _stories[_i];
    final rawColor = s.body['color'];
    final color = storyColors[((rawColor is num ? rawColor.toInt() : 0)) % storyColors.length];
    final media = MediaRef.listFrom(s.body['media']);
    final text = s.body['text'] is String ? s.body['text'] as String : null;
    final mine = widget.author == e.me.id;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapUp: (d) => d.globalPosition.dx < MediaQuery.of(context).size.width / 3 ? _prev() : _next(),
        onLongPressStart: (_) => _anim.stop(),
        onLongPressEnd: (_) => _anim.forward(),
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 300) context.pop();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            NsfwGate(
              nsfw: s.body['nsfw'] == true,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (media.isNotEmpty)
                    MediaLoader(
                      media: media.first,
                      item: s,
                      placeholder: (_, failed) => Container(color: color),
                      builder: (_, f) => media.first.isVideo ? VideoView(file: f) : Image.file(f, fit: BoxFit.cover),
                    )
                  else
                    Container(color: color),
                  if (text != null && text.isNotEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Container(
                          padding: media.isEmpty ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: media.isEmpty
                              ? null
                              : BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(Radii.md)),
                          child: Text(
                            text,
                            textAlign: TextAlign.center,
                            style: Txt.display(Colors.white).copyWith(fontSize: media.isEmpty ? 28 : 18),
                          ),
                        ),
                      ),
                    ),
                  StickerLayer(
                    stickers: StorySticker.listFrom(s.body['stk']),
                    nameOf: e.nameOf,
                    onAsk: mine ? null : _ask,
                    onPause: _anim.stop,
                  ),
                ],
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Column(
                  children: [
                    Row(
                      children: [
                        for (var k = 0; k < _stories.length; k++)
                          Expanded(
                            child: Container(
                              height: 2.5,
                              margin: const EdgeInsets.symmetric(horizontal: 2),
                              decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                              child: k < _i
                                  ? Container(color: Colors.white)
                                  : k == _i
                                      ? AnimatedBuilder(
                                          animation: _anim,
                                          builder: (_, _) => FractionallySizedBox(
                                            alignment: Alignment.centerLeft,
                                            widthFactor: _anim.value,
                                            child: Container(color: Colors.white),
                                          ),
                                        )
                                      : null,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        GestureDetector(
                          onTap: () => mine ? context.go('/me') : context.push('/u/${widget.author}'),
                          child: Avatar(id: widget.author, size: 32, presence: false),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: GestureDetector(
                            onTap: () => mine ? context.go('/me') : context.push('/u/${widget.author}'),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(mine ? 'Your story' : e.nameOf(widget.author), style: Txt.bodyStrong(Colors.white)),
                                Text(timeAgo(s.ts), style: Txt.mono(Colors.white60, size: 11)),
                              ],
                            ),
                          ),
                        ),
                        if (mine)
                          IconBtn(Icons.delete_outline_rounded, color: Colors.white, onTap: () async {
                            _anim.stop();
                            await e.deleteItem(s);
                            if (context.mounted) context.pop();
                          }),
                        IconBtn(Icons.close_rounded, color: Colors.white, onTap: () => context.pop()),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: MediaQuery.paddingOf(context).bottom + 12,
              child: Builder(builder: (context) {
                final st = e.storyStats(s);
                return Row(
                  children: [
                    if (mine)
                      GestureDetector(
                        onTap: () => showModalBottomSheet(
                          context: context,
                          builder: (ctx) => SafeArea(
                            child: ListView(
                              shrinkWrap: true,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Text('${st.views} views', style: Txt.heading(ctx.pal.ink)),
                                ),
                                if (st.viewers.isEmpty)
                                  const ListTile(title: Text('No views yet'))
                                else
                                  for (final id in st.viewers)
                                    ListTile(
                                      leading: Avatar(id: id, size: 36, presence: false),
                                      title: Text(e.nameOf(id)),
                                      trailing: st.reactions[id] != null ? Text(st.reactions[id]!) : null,
                                      onTap: () => ctx.push('/u/$id'),
                                    ),
                              ],
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.visibility_outlined, color: Colors.white, size: 18),
                            const SizedBox(width: 6),
                            Text('${st.views}', style: Txt.bodyStrong(Colors.white)),
                          ],
                        ),
                      )
                    else
                      Expanded(
                        child: TextField(
                          controller: _reply,
                          style: Txt.body(Colors.white),
                          cursorColor: Colors.white,
                          focusNode: _replyFocus,
                          decoration: InputDecoration(
                            hintText: _asking == null ? 'Reply' : 'Answer: $_asking',
                            hintStyle: Txt.body(Colors.white54),
                            filled: true,
                            fillColor: Colors.white10,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          ),
                          onTap: () => _anim.stop(),
                          onSubmitted: (t) async {
                            if (t.trim().isEmpty) return;
                            await e.storyReply(s, t, prompt: _asking);
                            _reply.clear();
                            setState(() => _asking = null);
                            if (context.mounted) toast(context, 'Sent to their chat');
                          },
                        ),
                      ),
                    const SizedBox(width: 8),
                    IconBtn(
                      st.liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                      color: st.liked ? const Color(0xFFFF5A7A) : Colors.white,
                      onTap: () => e.like(s.e.scope, s.id, !st.liked),
                    ),
                    if (!mine)
                      IconBtn(
                        Icons.add_reaction_outlined,
                        color: Colors.white,
                        tooltip: 'React',
                        onTap: () {
                          _anim.stop();
                          setState(() => _reacting = !_reacting);
                        },
                      ),
                  ],
                );
              }),
            ),
            if (_reacting && !mine)
              Positioned(
                left: 12,
                right: 12,
                bottom: MediaQuery.paddingOf(context).bottom + 68,
                child: Builder(builder: (context) {
                  final current = e.storyStats(s).reactions[e.me.id];
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(Radii.pill)),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        for (final r in storyReactions)
                          GestureDetector(
                            onTap: () {
                              e.react(s.e.scope, s.id, current == r ? null : r);
                              setState(() => _reacting = false);
                              _anim.forward();
                            },
                            child: AnimatedScale(
                              duration: Motion.fast,
                              scale: current == r ? 1.25 : 1,
                              child: Padding(
                                padding: const EdgeInsets.all(4),
                                child: Text(r, style: const TextStyle(fontSize: 30)),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                }),
              ),
          ],
        ),
      ),
    );
  }
}

class StoryComposer extends ConsumerStatefulWidget {
  const StoryComposer({super.key});

  @override
  ConsumerState<StoryComposer> createState() => _StoryComposerState();
}

class _StoryComposerState extends ConsumerState<StoryComposer> {
  final _text = TextEditingController();
  int _color = 0;
  XFile? _image;
  bool _busy = false;
  bool _nsfw = false;
  List<StorySticker> _stickers = const [];

  Future<void> _addSticker() async {
    final e = ref.read(engineProvider);
    final people = [for (final x in e.people().where((x) => !x.blocked)) (x.id, x.name)];
    final st = await pickSticker(context, people);
    if (st == null || !mounted) return;
    if (_stickers.length >= StorySticker.max) {
      toast(context, 'Up to ${StorySticker.max} stickers');
      return;
    }
    setState(() => _stickers = [..._stickers, st]);
  }

  Future<void> _pick(ImageSource src) async {
    if (src == ImageSource.gallery &&
        !await allowMediaOrTell(context, images: true, message: 'Photo access is needed to add a picture.')) {
      return;
    }
    final x = await ImagePicker().pickImage(source: src, maxWidth: 1600, imageQuality: 85);
    if (!mounted || x == null) return;
    setState(() => _image = x);
  }

  Future<void> _post() async {
    if (_text.text.trim().isEmpty && _image == null && _stickers.isEmpty) return;
    setState(() => _busy = true);
    final e = ref.read(engineProvider);
    MediaRef? media;
    if (_image != null) {
      media = await e.media.import(File(_image!.path), name: _image!.name, scope: Scope.story(e.me.id));
    }
    await e.createStory(
      text: _text.text.trim().isEmpty ? null : _text.text.trim(),
      media: media,
      color: _color,
      nsfw: _nsfw,
      stickers: _stickers,
    );
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final bg = storyColors[_color];
    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_image != null) Image.file(File(_image!.path), fit: BoxFit.cover),
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: TextField(
                  controller: _text,
                  textAlign: TextAlign.center,
                  maxLines: null,
                  maxLength: 200,
                  style: Txt.display(Colors.white).copyWith(fontSize: 28),
                  cursorColor: Colors.white,
                  decoration: InputDecoration(
                    filled: _image != null,
                    fillColor: Colors.black45,
                    hintText: 'Say something',
                    hintStyle: Txt.display(Colors.white38).copyWith(fontSize: 28),
                    counterText: '',
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                ),
              ),
            ),
            EditableStickerLayer(
              stickers: _stickers,
              nameOf: (id) => ref.read(engineProvider).nameOf(id),
              onChanged: (next) => setState(() => _stickers = next),
            ),
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: Row(
                children: [
                  IconBtn(Icons.close_rounded, color: Colors.white, onTap: () => context.pop()),
                  const Spacer(),
                  IconBtn(Icons.emoji_emotions_outlined, color: Colors.white, tooltip: 'Stickers', onTap: _addSticker),
                  IconBtn(Icons.photo_outlined, color: Colors.white, onTap: () => _pick(ImageSource.gallery)),
                  IconBtn(Icons.photo_camera_outlined, color: Colors.white, onTap: () => _pick(ImageSource.camera)),
                  if (_image != null)
                    IconBtn(Icons.hide_image_outlined, color: Colors.white, onTap: () => setState(() => _image = null)),
                ],
              ),
            ),
            Positioned(
              bottom: 16,
              left: 16,
              right: 16,
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (var i = 0; i < storyColors.length; i++)
                            GestureDetector(
                              onTap: () => setState(() => _color = i),
                              child: Container(
                                width: 28,
                                height: 28,
                                margin: const EdgeInsets.only(right: 8),
                                decoration: BoxDecoration(
                                  color: storyColors[i],
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: i == _color ? 2.5 : 1),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  IconBtn(
                    _nsfw ? Icons.visibility_off_rounded : Icons.visibility_off_outlined,
                    color: _nsfw ? Colors.white : Colors.white70,
                    tooltip: 'NSFW',
                    onTap: () => setState(() => _nsfw = !_nsfw),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
                    onPressed: _busy ? null : _post,
                    child: Text(_busy ? 'Sharing…' : 'Share 24h'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
