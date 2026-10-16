import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/call/live.dart';
import '../../state/calls.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';
import 'devices.dart';

/// Goes live on [channel] after asking voice or video.
Future<void> goLive(BuildContext context, WidgetRef ref, Bcast channel) async {
  final m = ref.read(liveManagerProvider);
  if (m == null) {
    toast(context, 'Live streams need the network library, which this build does not have.');
    return;
  }
  bool? video;
  await showActions(context, [
    SheetAction(Icons.videocam_rounded, 'Video', () => video = true, subtitle: 'Camera and microphone'),
    SheetAction(Icons.mic_rounded, 'Audio only', () => video = false, subtitle: 'Like a radio show'),
  ], title: 'GO LIVE ON ${channel.name.toUpperCase()}');
  if (video == null || !context.mounted) return;
  try {
    await m.start(channel, video: video!);
    if (context.mounted) unawaited(context.push('/live'));
  } catch (e) {
    if (context.mounted) toast(context, e is StateError ? e.message : '$e');
  }
}

/// Joins someone's live stream from its announcement post.
Future<void> joinLive(BuildContext context, WidgetRef ref, Item post) async {
  final m = ref.read(liveManagerProvider);
  final live = post.body['live'];
  final chan = Scope.parts(post.e.scope).elementAtOrNull(2);
  if (m == null || live is! Map || live['id'] is! String || chan == null) return;
  try {
    await m.watch(post.author, chan, live['id'] as String, video: live['video'] != false);
    if (context.mounted) unawaited(context.push('/live'));
  } catch (e) {
    if (context.mounted) toast(context, e is StateError ? e.message : '$e');
  }
}

class LiveScreen extends ConsumerStatefulWidget {
  const LiveScreen({super.key});

  @override
  ConsumerState<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends ConsumerState<LiveScreen> {
  final _text = TextEditingController();
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _text.dispose();
    super.dispose();
  }

  String _ended(String? reason) => switch (reason) {
        'full' => 'This stream is full',
        'unreachable' => 'Could not reach the host',
        'lost' => 'Connection to the host was lost',
        _ => 'The stream has ended',
      };

  @override
  Widget build(BuildContext context) {
    final m = ref.watch(liveManagerProvider);
    final s = ref.watch(liveStateProvider).value;
    final e = ref.watch(maybeEngineProvider);
    if (m == null || s == null || e == null) {
      return const Scaffold(backgroundColor: Colors.black, body: Center(child: Text('No live stream')));
    }
    final preview = m.devices is PhoneDevices ? (m.devices as PhoneDevices).preview : null;
    final p = context.pal;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (s.hosting && s.camera && preview != null && preview.value.isInitialized)
            CameraPreview(preview)
          else if (!s.hosting && s.frame != null)
            Image.memory(s.frame!, fit: BoxFit.cover, gaplessPlayback: true)
          else
            Center(
              child: AnimatedScale(
                duration: Motion.fast,
                scale: 1 + s.level * .2,
                child: Avatar(id: s.owner, size: 120, presence: false),
              ),
            ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(Space.md),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: s.live ? p.danger : Colors.white24,
                          borderRadius: BorderRadius.circular(Radii.sm),
                        ),
                        child: Text(s.live ? 'LIVE' : 'ENDED', style: Txt.mono(Colors.white, size: 11, w: FontWeight.w500)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          s.hosting ? 'You · ${duration(nowMs() - s.started)}' : e.nameOf(s.owner),
                          style: Txt.bodyStrong(Colors.white),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Icon(Icons.visibility_rounded, size: 16, color: Colors.white70),
                      const SizedBox(width: 4),
                      Text('${s.hosting ? s.viewers.length : s.viewerCount}', style: Txt.mono(Colors.white70, size: 12)),
                      if (s.hearts > 0) ...[
                        const SizedBox(width: 10),
                        const Icon(Icons.favorite_rounded, size: 16, color: Color(0xFFFF5A7A)),
                        const SizedBox(width: 4),
                        Text('${s.hearts}', style: Txt.mono(Colors.white70, size: 12)),
                      ],
                      IconBtn(Icons.close_rounded, color: Colors.white, tooltip: s.hosting ? 'End stream' : 'Leave', onTap: () async {
                        if (s.live && s.hosting) {
                          final ok = await confirm(context, title: 'End the stream?', body: 'Everyone watching is disconnected.', action: 'End', danger: true);
                          if (!ok) return;
                        }
                        await m.stop();
                        if (context.mounted) context.pop();
                      }),
                    ],
                  ),
                ),
                if (!s.live)
                  Padding(
                    padding: const EdgeInsets.all(Space.lg),
                    child: Text(_ended(s.reason), style: Txt.heading(Colors.white)),
                  )
                else if (!s.hosting && !s.joined)
                  Padding(
                    padding: const EdgeInsets.all(Space.lg),
                    child: Text('Joining…', style: Txt.body(Colors.white70)),
                  ),
                const Spacer(),
                SizedBox(
                  height: 220,
                  child: ShaderMask(
                    shaderCallback: (r) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.white],
                      stops: [0, .25],
                    ).createShader(r),
                    blendMode: BlendMode.dstIn,
                    child: ListView(
                      reverse: true,
                      padding: const EdgeInsets.symmetric(horizontal: Space.md),
                      children: [
                        for (final c in s.chat.reversed.take(60))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text.rich(
                              TextSpan(children: [
                                TextSpan(text: '${e.nameOf(c.from)}  ', style: Txt.bodyStrong(Colors.white70)),
                                TextSpan(text: c.text, style: Txt.body(Colors.white)),
                              ]),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (s.live)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.md),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _text,
                            style: Txt.body(Colors.white),
                            decoration: InputDecoration(
                              hintText: 'Say something',
                              hintStyle: Txt.body(Colors.white54),
                              filled: true,
                              fillColor: Colors.white12,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            ),
                            onSubmitted: (t) {
                              m.sendChat(t);
                              _text.clear();
                            },
                          ),
                        ),
                        if (s.hosting) ...[
                          IconBtn(s.mic ? Icons.mic_rounded : Icons.mic_off_rounded, color: Colors.white, tooltip: 'Microphone', onTap: () => m.setMic(!s.mic)),
                          if (s.video)
                            IconBtn(s.camera ? Icons.videocam_rounded : Icons.videocam_off_rounded,
                                color: Colors.white, tooltip: 'Camera', onTap: () => m.setCamera(!s.camera)),
                        ] else
                          IconBtn(Icons.favorite_rounded, color: const Color(0xFFFF5A7A), tooltip: 'Send a heart', onTap: m.sendHeart),
                      ],
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
