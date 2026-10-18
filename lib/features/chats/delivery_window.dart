import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/engine.dart';
import '../../net/transport.dart';
import '../../net/views.dart';
import 'seen_by.dart';

/// Milestones, not a fabricated byte-transfer percentage.
int deliveryMilestone(Delivery state) => switch (state) {
  Delivery.queued ||
  Delivery.sending ||
  Delivery.failed ||
  Delivery.cancelled ||
  Delivery.saved => 1,
  Delivery.sent => 2,
  Delivery.delivered => 3,
  Delivery.read => 4,
};

class MessageDeliveryProgress extends StatelessWidget {
  const MessageDeliveryProgress({
    super.key,
    required this.message,
    required this.onOpen,
  });
  final MessageView message;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final received = message.recipients
        .where((r) => r.state == Delivery.delivered || r.state == Delivery.read)
        .length;
    final caption = !message.mine ? 'Received' : message.delivery.label;
    final color = message.delivery == Delivery.failed ? p.danger : p.accent;
    // Incoming messages are already on this phone, so the meter is full.
    // A fixed 3 of 4 looked like a transfer that had stalled.
    final count = message.mine ? deliveryMilestone(message.delivery) : 4;
    return Semantics(
      button: true,
      label: '$caption${message.recipients.length > 1 ? ', $received of ${message.recipients.length}' : ''}. Open message delivery details',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('delivery-progress:${message.id}'),
          onTap: onOpen,
          borderRadius: BorderRadius.circular(Radii.sm),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 36,
                  child: Row(
                    children: [
                      for (var i = 0; i < 4; i++)
                        Expanded(
                          child: AnimatedContainer(
                            duration: MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : Motion.base,
                            height: 3,
                            margin: const EdgeInsets.symmetric(horizontal: 1),
                            decoration: BoxDecoration(
                              color: i < count ? color : p.line,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right_rounded, size: 14, color: p.faint),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showMessageDelivery(
  BuildContext context,
  Engine engine,
  MessageView message,
) {
  final reduced = MediaQuery.disableAnimationsOf(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close message delivery',
    barrierColor: Colors.black54,
    transitionDuration: reduced
        ? Duration.zero
        : const Duration(milliseconds: 260),
    pageBuilder: (context, _, _) =>
        MessageDeliveryWindow(engine: engine, initial: message),
    transitionBuilder: (context, animation, _, child) {
      final curve = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curve,
        child: ScaleTransition(
          scale: Tween(begin: .97, end: 1.0).animate(curve),
          child: child,
        ),
      );
    },
  );
}

class MessageDeliveryWindow extends StatefulWidget {
  const MessageDeliveryWindow({
    super.key,
    required this.engine,
    required this.initial,
  });
  final Engine engine;
  final MessageView initial;
  @override
  State<MessageDeliveryWindow> createState() => _MessageDeliveryWindowState();
}

class _MessageDeliveryWindowState extends State<MessageDeliveryWindow>
    with WidgetsBindingObserver {
  late MessageView _message = widget.initial;
  NetStatus? _network;
  String? _peer;
  DateTime? _sampled;
  bool _polling = false;
  bool _visible = true;
  bool _removed = false;
  Timer? _timer;
  StreamSubscription<Set<String>>? _changes;
  Engine get engine => widget.engine;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _changes = engine.changes.listen((keys) {
      if (!mounted || !_visible) return;
      if (keys.contains(widget.initial.item.e.scope)) {
        final current = engine
            .messages(widget.initial.item.e.scope)
            .where((m) => m.id == _message.id)
            .firstOrNull;
        setState(() {
          _removed = current == null;
          if (current != null) _message = current;
        });
      }
      if (keys.contains(Ch.net)) _refresh();
    });
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
    _refresh();
  }

  Future<void> _refresh() async {
    if (_polling || !_visible) return;
    _polling = true;
    try {
      final network = await engine.netStatus();
      if (mounted)
        setState(() {
          _network = network;
          _sampled = DateTime.now();
        });
    } finally {
      _polling = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = state == AppLifecycleState.resumed;
    if (mounted) setState(() {});
    if (_visible) _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _changes?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final peers = _message.mine
        ? _message.recipients
              .map((r) => r.peer)
              .where((id) => id != engine.me.id)
              .toList()
        : [_message.author];
    if (peers.isEmpty && _message.mine) {
      final dm = Scope.dmPeer(_message.item.e.scope, engine.me.id);
      if (dm != null) peers.add(dm);
    }
    final selectedPeer = peers.contains(_peer) ? _peer : peers.firstOrNull;
    final recipient = _message.recipients
        .where((r) => r.peer == selectedPeer)
        .firstOrNull;
    final state = recipient?.state ?? _message.delivery;
    final link = _network?.routeTelemetry == true
        ? _network?.links.where((l) => l.peer == selectedPeer).firstOrNull
        : null;
    final selectedPath = link?.paths.where((path) => path.selected).firstOrNull;
    final running = _network?.running == true;
    final active =
        !_removed &&
        _visible &&
        _message.mine &&
        running &&
        state == Delivery.sending;
    final title = _removed
        ? 'Message removed'
        : _message.mine
        ? state.label
        : 'Received on this device';
    final compact = MediaQuery.sizeOf(context).width < 600;
    final content = Material(
      color: p.bg,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Message delivery', style: Txt.heading(p.ink)),
                  ),
                  IconButton(
                    tooltip: 'Close delivery details',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AnimatedSwitcher(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : Motion.base,
                      child: Align(
                        key: ValueKey(title),
                        alignment: Alignment.centerLeft,
                        child: Text(
                          title,
                          style: Txt.title(
                            state == Delivery.failed ? p.danger : p.ink,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _message.text.isEmpty
                          ? 'Message with attachments'
                          : _message.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Txt.small(p.muted),
                    ),
                    if (_message.mine && _message.recipients.length > 1) ...[
                      const SizedBox(height: 16),
                      SeenBy(
                        recipients: _message.recipients.where((r) => r.peer != engine.me.id).toList(),
                        nameOf: engine.nameOf,
                        selected: selectedPeer,
                        onSelect: (id) => setState(() => _peer = id),
                      ),
                    ],
                    if (peers.length > 1) ...[
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        key: ValueKey(peers.join(':')),
                        initialValue: selectedPeer,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Recipient',
                        ),
                        items: [
                          for (final peer in peers)
                            DropdownMenuItem(
                              value: peer,
                              child: Text(
                                engine.nameOf(peer),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (value) => setState(() => _peer = value),
                      ),
                    ],
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
                      decoration: BoxDecoration(
                        color: p.surface,
                        borderRadius: BorderRadius.circular(Radii.lg),
                        border: Border.all(color: p.line),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                running
                                    ? Icons.sensors_rounded
                                    : Icons.sensors_off_rounded,
                                size: 14,
                                color: running ? p.accent : p.muted,
                              ),
                              const SizedBox(width: 7),
                              Expanded(
                                child: Text(
                                  _network == null
                                      ? 'Reading node status…'
                                      : running
                                      ? 'Live connection'
                                      : 'This node is offline',
                                  style: Txt.mono(p.muted, size: 11),
                                ),
                              ),
                              if (link?.latencyMs != null)
                                Text(
                                  '${link!.latencyMs} ms RTT',
                                  style: Txt.mono(p.muted, size: 11),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          _RouteDiagram(
                            local: shortId(engine.me.id),
                            remote: selectedPeer == null
                                ? 'No recipients'
                                : engine.nameOf(selectedPeer),
                            path: selectedPath,
                            active: active,
                            incoming: !_message.mine,
                            confirmed:
                                !_message.mine ||
                                state == Delivery.delivered ||
                                state == Delivery.read,
                          ),
                          Text(
                            selectedPath == null
                                ? 'The route is not available yet.'
                                : selectedPath.kind == LinkKind.direct
                                ? 'Direct connection · no relay selected for data.'
                                : 'Relay connection · encrypted between devices.',
                            style: Txt.small(p.muted),
                          ),
                          const SizedBox(height: 6),
                          if (_message.hops.isEmpty)
                            Text(
                              'The hop-by-hop trace is saved the next time this message is sent or received.',
                              style: Txt.mono(p.faint, size: 10.5),
                            )
                          else
                            for (var i = 0; i < _message.hops.length; i++)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text('${i + 1}. ${_message.hops[i]}', style: Txt.mono(p.inkSoft, size: 11)),
                              ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Delivery steps',
                      style: Txt.small(p.ink)
                          .copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    if (_message.mine) ...[
                      for (final (index, label) in [
                        'Saved on this device',
                        'Sent to the connection',
                        'Recipient confirmed receipt',
                        'Recipient marked it read',
                      ].indexed)
                        _Step(
                          label: label,
                          done: index < deliveryMilestone(state),
                          active: active && index == 1,
                        ),
                    ] else
                      const _Step(
                        label: 'Accepted on this device',
                        done: true,
                        active: false,
                      ),
                    if (recipient?.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          recipient!.error!,
                          style: Txt.small(p.muted),
                        ),
                      ),
                    if (!_removed &&
                        (_message.canRetry || _message.canCancel)) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        children: [
                          if (_message.canRetry)
                            FilledButton.tonalIcon(
                              onPressed: () => engine.retryMessage(_message.id),
                              icon: const Icon(Icons.refresh_rounded, size: 17),
                              label: const Text('Retry'),
                            ),
                          if (_message.canCancel)
                            TextButton(
                              onPressed: () =>
                                  engine.cancelMessage(_message.id),
                              child: const Text('Stop retrying'),
                            ),
                        ],
                      ),
                      Text(
                        'Stopping retries cannot recall a message. An in-progress send may still arrive.',
                        style: Txt.small(p.muted),
                      ),
                    ],
                    const SizedBox(height: 20),
                    _Detail(label: 'This node', value: engine.me.id),
                    if (selectedPeer != null)
                      _Detail(
                        label: _message.mine ? 'Recipient node' : 'Sender node',
                        value: selectedPeer,
                      ),
                    _Detail(label: 'Message ID', value: _message.id),
                    _Detail(
                      label: 'Created',
                      value: '${dayLabel(_message.ts)} ${clock(_message.ts)}',
                    ),
                    if (recipient != null)
                      _Detail(
                        label: 'Send attempts',
                        value: '${recipient.attempts}',
                      ),
                    if (recipient != null &&
                        (state == Delivery.queued || state == Delivery.sent) &&
                        recipient.nextAt > 0)
                      _Detail(
                        label: 'Next attempt',
                        value: running
                            ? 'In ${math.max(0, (recipient.nextAt - nowMs()) ~/ 1000)} seconds'
                            : 'When this node reconnects',
                      ),
                    if (_network?.routeTelemetry != true)
                      _Detail(
                        label: 'Route details',
                        value: _network == null
                            ? 'Loading…'
                            : 'Not reported by this transport build.',
                      ),
                    if (link != null) ...[
                      for (final path in link.paths)
                        _Detail(
                          label: path.kind == LinkKind.relay
                              ? (path.selected
                                    ? 'Selected relay'
                                    : 'Available relay path')
                              : (path.selected
                                    ? 'Selected direct path'
                                    : 'Available direct path'),
                          value:
                              '${path.address}${path.latencyMs == null ? '' : ' · ${path.latencyMs} ms RTT'}',
                        ),
                    ],
                    if (_network?.routeTelemetry == true) ...[
                      for (final relay in _network!.relays)
                        _Detail(label: 'This node’s home relay', value: relay),
                      if (_network!.relays.isEmpty)
                        const _Detail(
                          label: 'Home relay',
                          value: 'None reported',
                        ),
                    ],
                    if (_sampled != null)
                      Text(
                        'Connection refreshed at ${clock(_sampled!.millisecondsSinceEpoch)}',
                        style: Txt.mono(p.faint, size: 10.5),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (compact) return Dialog.fullscreen(child: content);
    return Dialog(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: SizedBox(
        width: 640,
        height: math.min(820, MediaQuery.sizeOf(context).height * .88),
        child: content,
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.label, required this.done, required this.active});
  final String label;
  final bool done;
  final bool active;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(
            done
                ? Icons.check_circle_rounded
                : active
                ? Icons.arrow_circle_right_outlined
                : Icons.radio_button_unchecked,
            size: 17,
            color: done || active ? p.accent : p.faint,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: Txt.small(done || active ? p.ink : p.muted),
            ),
          ),
        ],
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Txt.mono(p.muted, size: 10.5)),
          const SizedBox(height: 3),
          SelectableText(value, style: Txt.small(p.ink)),
        ],
      ),
    );
  }
}

class _RouteDiagram extends StatefulWidget {
  const _RouteDiagram({
    required this.local,
    required this.remote,
    required this.path,
    required this.active,
    required this.incoming,
    required this.confirmed,
  });
  final String local;
  final String remote;
  final RoutePath? path;
  final bool active;
  final bool incoming;
  final bool confirmed;
  @override
  State<_RouteDiagram> createState() => _RouteDiagramState();
}

class _RouteDiagramState extends State<_RouteDiagram>
    with SingleTickerProviderStateMixin {
  late final _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _RouteDiagram oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.active &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.of(context)) {
      if (!_motion.isAnimating) _motion.repeat();
    } else {
      _motion.stop();
      _motion.value = 0;
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final direct = widget.path?.kind == LinkKind.direct;
    final middle = widget.path == null
        ? 'Route unknown'
        : Uri.tryParse(widget.path!.address)?.host ?? widget.path!.address;
    final nodes = <({IconData icon, String label, String detail})>[
      (
        icon: widget.incoming
            ? Icons.person_outline_rounded
            : Icons.phone_android_rounded,
        label: widget.incoming ? 'Sender' : 'This device',
        detail: widget.incoming ? widget.remote : widget.local,
      ),
      if (!direct)
        (
          icon: widget.path == null
              ? Icons.more_horiz_rounded
              : Icons.cloud_outlined,
          label: widget.path == null ? 'Finding route' : 'Selected relay',
          detail: middle,
        ),
      (
        icon: widget.incoming
            ? Icons.phone_android_rounded
            : Icons.person_outline_rounded,
        label: widget.incoming
            ? 'This device'
            : widget.confirmed
            ? 'Received'
            : 'Recipient',
        detail: widget.incoming ? widget.local : widget.remote,
      ),
    ];
    return SizedBox(
      height: 134,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth / nodes.length;
          return Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _RoutePainter(
                    animation: _motion,
                    color: p.accent,
                    line: p.line,
                    start: width / 2,
                    end: constraints.maxWidth - width / 2,
                    active: widget.active,
                    known: widget.path != null,
                  ),
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final node in nodes)
                    Expanded(
                      child: Column(
                        children: [
                          const SizedBox(height: 17),
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: p.surface,
                              shape: BoxShape.circle,
                              border: Border.all(color: p.line),
                            ),
                            child: Icon(node.icon, color: p.inkSoft, size: 20),
                          ),
                          const SizedBox(height: 9),
                          Text(
                            node.label,
                            textAlign: TextAlign.center,
                            style: Txt.mono(p.muted, size: 10),
                          ),
                          const SizedBox(height: 3),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Text(
                              node.detail,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: Txt.small(p.ink).copyWith(fontSize: 11),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _RoutePainter extends CustomPainter {
  _RoutePainter({
    required this.animation,
    required this.color,
    required this.line,
    required this.start,
    required this.end,
    required this.active,
    required this.known,
  }) : super(repaint: animation);
  final Animation<double> animation;
  final Color color;
  final Color line;
  final double start;
  final double end;
  final bool active;
  final bool known;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..strokeWidth = 1.5
      ..color = line;
    for (var x = start; x < end; x += 8) {
      canvas.drawLine(Offset(x, 39), Offset(math.min(x + 4, end), 39), paint);
    }
    if (!active) return;
    if (known) {
      final x = start + (end - start) * animation.value;
      canvas.drawCircle(
        Offset(x, 39),
        7,
        Paint()..color = color.withValues(alpha: .12),
      );
      canvas.drawCircle(Offset(x, 39), 3, Paint()..color = color);
    } else {
      canvas.drawCircle(
        Offset(start, 39),
        24 + animation.value * 8,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color.withValues(alpha: (1 - animation.value) * .4),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RoutePainter old) =>
      old.color != color ||
      old.line != line ||
      old.start != start ||
      old.end != end ||
      old.active != active ||
      old.known != known;
}
