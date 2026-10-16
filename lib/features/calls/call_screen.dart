import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../net/call/calls.dart';
import '../../state/calls.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';
import 'devices.dart';

final _routeLock = <String>{};

/// Pushes [path] unless that screen is already open or a push is in flight.
Future<void> openOnce(BuildContext context, String path) {
  if (!context.mounted || !_routeLock.add(path)) return Future.value();
  final router = GoRouter.of(context);
  if (router.state.uri.path == path) {
    _routeLock.remove(path);
    return Future.value();
  }
  return router.push(path).whenComplete(() => _routeLock.remove(path));
}

/// Voice or video, from the call button.
Future<void> showCallMenu(BuildContext context, WidgetRef ref, List<String> peers) async {
  final box = context.findRenderObject() as RenderBox?;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (box == null || overlay == null || !box.hasSize) return;
  final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
  final video = await showMenu<bool>(
    context: context,
    position: RelativeRect.fromRect(
      topLeft & box.size,
      Offset.zero & overlay.size,
    ),
    items: const [
      PopupMenuItem(
        value: false,
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.call_outlined),
          title: Text('Voice call'),
        ),
      ),
      PopupMenuItem(
        value: true,
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.videocam_outlined),
          title: Text('Video call'),
        ),
      ),
    ],
  );
  if (video == null || !context.mounted) return;
  await startCall(context, ref, peers, video: video);
}

/// Starts a call and opens the call screen, explaining failures.
Future<void> startCall(BuildContext context, WidgetRef ref, List<String> peers, {required bool video}) async {
  final m = ref.read(callManagerProvider);
  if (m == null) {
    toast(context, 'Calls need the network library, which this build does not have.');
    return;
  }
  try {
    await m.start(peers, video: video);
    if (context.mounted) unawaited(openOnce(context, '/call'));
  } catch (e) {
    if (context.mounted) toast(context, e is StateError ? e.message : '$e');
  }
}

/// The in-call screen: ringing, connecting and talking, for one or a group.
class CallScreen extends ConsumerStatefulWidget {
  const CallScreen({super.key});

  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends ConsumerState<CallScreen> {
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
    super.dispose();
  }

  String _status(CallState c) => switch (c.phase) {
        CallPhase.outgoing => 'Ringing…',
        CallPhase.incoming => 'Incoming ${c.video ? 'video' : 'voice'} call',
        CallPhase.connecting => 'Connecting…',
        CallPhase.active => duration(c.elapsed.inMilliseconds),
        CallPhase.ended => switch (c.reason) {
            'declined' => 'Declined',
            'busy' => 'Busy on another call',
            'no answer' => 'No answer',
            'missed' => 'Missed call',
            'failed' => 'Could not connect',
            'cancelled' => 'Cancelled',
            _ => 'Call ended',
          },
      };

  @override
  Widget build(BuildContext context) {
    final m = ref.watch(callManagerProvider);
    final c = ref.watch(callStateProvider).value;
    final e = ref.watch(maybeEngineProvider);
    if (m == null || c == null || e == null) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
        body: Center(child: Text('No call', style: Txt.body(Colors.white70))),
      );
    }
    if (c.phase == CallPhase.ended) {
      Future<void>.delayed(const Duration(milliseconds: 1500), () {
        if (mounted && ref.read(callStateProvider).value?.phase == CallPhase.ended && context.canPop()) context.pop();
      });
    }
    final others = c.members.where((x) => x != e.me.id).toList();
    final title = others.length == 1 ? e.nameOf(others.first) : others.map(e.nameOf).take(3).join(', ');
    final route = others.map((p) => c.rtt[p]).whereType<double>().toList();

    return Scaffold(
      backgroundColor: const Color(0xFF0B0E0D),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
              child: Row(
                children: [
                  IconBtn(Icons.keyboard_arrow_down_rounded, color: Colors.white, tooltip: 'Minimise', onTap: () => context.pop()),
                  const Spacer(),
                  Icon(Icons.lock_outline_rounded, size: 13, color: Colors.white54),
                  const SizedBox(width: 4),
                  Text(
                    route.isEmpty ? 'end-to-end encrypted' : 'encrypted · ${route.first.toStringAsFixed(0)} ms',
                    style: Txt.mono(Colors.white54, size: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Space.lg),
            Text(title, style: Txt.title(Colors.white), textAlign: TextAlign.center, maxLines: 2),
            const SizedBox(height: 4),
            Text(_status(c), style: Txt.mono(Colors.white70, size: 13)),
            const SizedBox(height: Space.lg),
            Expanded(child: _Grid(c: c, others: others, nameOf: e.nameOf)),
            if (c.camera && m.devices is PhoneDevices)
              ListenableBuilder(
                listenable: m.devices as PhoneDevices,
                builder: (_, _) {
                  final preview = (m.devices as PhoneDevices).preview;
                  if (!cameraPreviewReady(preview)) return const SizedBox.shrink();
                  return Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.only(right: Space.gutter, bottom: Space.md),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(Radii.md),
                        child: SizedBox(width: 96, height: 128, child: CameraPreview(preview!)),
                      ),
                    ),
                  );
                },
              ),
            _Controls(c: c, m: m),
            const SizedBox(height: Space.lg),
          ],
        ),
      ),
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({required this.c, required this.others, required this.nameOf});
  final CallState c;
  final List<String> others;
  final String Function(String) nameOf;

  @override
  Widget build(BuildContext context) {
    final cols = others.length <= 1 ? 1 : 2;
    return GridView.count(
      padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
      crossAxisCount: cols,
      mainAxisSpacing: Space.sm,
      crossAxisSpacing: Space.sm,
      childAspectRatio: cols == 1 ? .8 : .75,
      children: [for (final p in others) _Tile(c: c, peer: p, name: nameOf(p))],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.c, required this.peer, required this.name});
  final CallState c;
  final String peer;
  final String name;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final frame = c.frames[peer];
    final level = c.levels[peer] ?? 0;
    final state = c.remote[peer];
    final connected = c.connected.contains(peer);
    final status = connected
        ? (state?.mic == false ? 'muted' : null)
        : (c.joined.contains(peer) ? 'connecting' : (c.phase == CallPhase.incoming ? null : 'ringing'));
    return AnimatedContainer(
      duration: Motion.fast,
      decoration: BoxDecoration(
        color: const Color(0xFF161B19),
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: level > .08 ? p.accent : Colors.transparent, width: 2.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (frame != null)
            Image.memory(frame, fit: BoxFit.cover, gaplessPlayback: true)
          else
            Center(child: Avatar(id: peer, size: 88, presence: false)),
          Positioned(
            left: 10,
            right: 10,
            bottom: 10,
            child: Row(
              children: [
                Expanded(
                  child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.bodyStrong(Colors.white)),
                ),
                if (status != null) Text(status, style: Txt.mono(Colors.white70, size: 11)),
                if (state?.mic == false) const Icon(Icons.mic_off_rounded, size: 16, color: Colors.white70),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Controls extends StatefulWidget {
  const _Controls({required this.c, required this.m});
  final CallState c;
  final CallManager m;

  @override
  State<_Controls> createState() => _ControlsState();
}

class _ControlsState extends State<_Controls> {
  bool _walkie = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final m = widget.m;
    final p = context.pal;
    if (c.phase == CallPhase.incoming) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _Round(icon: Icons.call_end_rounded, label: 'Decline', color: p.danger, onTap: m.decline),
          _Round(icon: c.video ? Icons.videocam_rounded : Icons.call_rounded, label: 'Answer', color: p.accent, onTap: m.accept),
        ],
      );
    }
    final live = c.phase != CallPhase.ended;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _Round(
          icon: c.mic ? Icons.mic_rounded : Icons.mic_off_rounded,
          label: c.mic ? 'Mute' : 'Unmute',
          onTap: live ? () => m.setMic(!c.mic) : null,
          on: !c.mic,
        ),
        _Round(
          icon: c.camera ? Icons.videocam_rounded : Icons.videocam_off_rounded,
          label: 'Camera',
          onTap: live ? () => m.setCamera(!c.camera) : null,
          on: c.camera,
        ),
        if (c.camera) _Round(icon: Icons.cameraswitch_rounded, label: 'Flip', onTap: live ? m.switchCamera : null),
        _Round(
          icon: Icons.campaign_rounded,
          label: _walkie ? 'Talk' : 'Walkie',
          on: _walkie,
          onTap: live
              ? () {
                  setState(() => _walkie = !_walkie);
                  if (_walkie) m.setMic(false);
                }
              : null,
          onHold: _walkie
              ? (down) {
                  m.setMic(down);
                }
              : null,
        ),
        _Round(icon: Icons.call_end_rounded, label: 'End', color: p.danger, onTap: live ? m.hangUp : null),
      ],
    );
  }
}

class _Round extends StatelessWidget {
  const _Round({required this.icon, required this.label, this.onTap, this.color, this.on = false, this.onHold});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? color;
  final bool on;
  final void Function(bool down)? onHold;

  @override
  Widget build(BuildContext context) {
    final bg = color ?? (on ? Colors.white : Colors.white12);
    final fg = color != null ? Colors.white : (on ? Colors.black : Colors.white);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          label: label,
          child: Material(
            color: onTap == null ? Colors.white10 : bg,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onHold == null ? onTap : null,
              onTapDown: onHold == null ? null : (_) => onHold!(true),
              onTapUp: onHold == null ? null : (_) => onHold!(false),
              onTapCancel: onHold == null ? null : () => onHold!(false),
              child: SizedBox(width: 64, height: 64, child: Icon(icon, color: fg, size: 28)),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: Txt.mono(Colors.white70, size: 11)),
      ],
    );
  }
}

/// Recent calls, newest first, with call-back buttons.
class CallLogScreen extends ConsumerWidget {
  const CallLogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final m = ref.watch(callManagerProvider);
    ref.watch(callStateProvider);
    final e = ref.watch(maybeEngineProvider);
    final log = m?.history() ?? const <CallRecord>[];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Calls'),
        actions: [
          if (log.isNotEmpty)
            TextButton(
              onPressed: () async {
                if (await confirm(context, title: 'Clear call history?', body: 'Removes the list from this phone.', action: 'Clear')) {
                  m?.clearHistory();
                  ref.invalidate(callStateProvider);
                }
              },
              child: const Text('Clear'),
            ),
        ],
      ),
      body: log.isEmpty || e == null
          ? const EmptyState(
              icon: Icons.call_outlined,
              title: 'No calls yet',
              body: 'Voice and video calls go straight between phones, encrypted, with no server in the middle.',
            )
          : ListView(
              children: [
                for (final r in log)
                  ListTile(
                    leading: r.peers.length == 1 ? Avatar(id: r.peers.first, size: 40) : CircleAvatar(child: Text('${r.peers.length}')),
                    title: Text(r.peers.map(e.nameOf).join(', '), maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Row(
                      children: [
                        Icon(
                          r.outgoing ? Icons.call_made_rounded : Icons.call_received_rounded,
                          size: 14,
                          color: r.result == 'answered' ? p.muted : p.danger,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            '${r.result == 'answered' ? duration(r.seconds * 1000) : r.result} · ${timeAgo(r.at)}',
                            style: Txt.mono(r.result == 'answered' ? p.muted : p.danger, size: 11),
                          ),
                        ),
                      ],
                    ),
                    trailing: IconBtn(
                      r.video ? Icons.videocam_outlined : Icons.call_outlined,
                      tooltip: 'Call back',
                      onTap: () => startCall(context, ref, r.peers, video: r.video),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// Opens the call screen when a call starts ringing.
class CallHost extends ConsumerWidget {
  const CallHost({super.key, required this.router, required this.child});
  final GoRouter router;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(callStateProvider, (prev, next) {
      final c = next.value;
      final before = prev?.value;
      if (c != null && c.phase == CallPhase.incoming && (before?.id != c.id || before?.phase != CallPhase.incoming)) {
        final here = router.routerDelegate.currentConfiguration.uri.path;
        if (here != '/call') router.push('/call');
      }
    });
    return child;
  }
}
