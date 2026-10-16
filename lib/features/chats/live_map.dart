import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../net/live_loc.dart';
import '../../net/views.dart';
import '../../state/live_share.dart';
import '../../state/providers.dart';

const _tiles = 'https://basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png';

double _zoomFor(LiveFix fix) {
  final acc = fix.acc;
  if (acc == null || acc < 80) return 16;
  if (acc < 400) return 14;
  return 12;
}

/// Small map inside a chat bubble. Tap opens the full map.
class LiveMapCard extends ConsumerStatefulWidget {
  const LiveMapCard({super.key, required this.scope, required this.messageId, required this.fix, required this.mine});

  final String scope;
  final String messageId;
  final LiveFix fix;
  final bool mine;

  @override
  ConsumerState<LiveMapCard> createState() => _LiveMapCardState();
}

class _LiveMapCardState extends ConsumerState<LiveMapCard> {
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

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final fix = widget.fix;
    final sharing = widget.mine && widget.fix.active;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: SizedBox(
        width: 248,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Radii.md),
          child: Material(
            color: p.raised,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 132,
                  child: Stack(
                    children: [
                      _MapView(fix: fix, interactive: false),
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            Navigator.of(context).push(MaterialPageRoute<void>(
                              builder: (_) => LiveMapPage(scope: widget.scope, messageId: widget.messageId),
                            ));
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                  child: Row(
                    children: [
                      Icon(Icons.location_on_rounded, size: 15, color: fix.active ? p.accent : p.faint),
                      const SizedBox(width: 4),
                      Expanded(child: Text(liveLeft(fix), style: Txt.small(fix.active ? p.ink : p.muted))),
                      if (sharing)
                        TextButton(
                          onPressed: () => ref.read(liveShareProvider).end(
                            widget.messageId,
                            scope: widget.scope,
                            current: widget.fix,
                          ),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            foregroundColor: p.danger,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          child: const Text('Stop'),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class LiveMapPage extends ConsumerStatefulWidget {
  const LiveMapPage({super.key, required this.scope, required this.messageId});
  final String scope;
  final String messageId;

  @override
  ConsumerState<LiveMapPage> createState() => _LiveMapPageState();
}

class _LiveMapPageState extends ConsumerState<LiveMapPage> {
  bool _follow = true;
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

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final e = ref.watch(engineProvider);
    final messages = ref.watch(messagesProvider(widget.scope)).value ?? const <MessageView>[];
    MessageView? m;
    for (final x in messages) {
      if (x.id == widget.messageId) {
        m = x;
        break;
      }
    }
    final fix = m?.loc;
    final name = m == null ? 'Location' : e.nameOf(m.author);
    final sharing = m != null && m.mine && fix != null && fix.active;
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: Txt.body(p.ink).copyWith(fontWeight: FontWeight.w600)),
            if (fix != null) Text(liveLeft(fix), style: Txt.mono(fix.active ? p.accent : p.muted, size: 11)),
          ],
        ),
        actions: [
          if (sharing)
            TextButton(
              onPressed: () => ref.read(liveShareProvider).end(widget.messageId, scope: widget.scope, current: fix),
              child: Text('Stop', style: Txt.body(p.danger)),
            ),
        ],
      ),
      body: fix == null
          ? Center(child: Text('This location is gone.', style: Txt.body(p.muted)))
          : Column(
              children: [
                Expanded(
                  child: _MapView(fix: fix, interactive: true, follow: _follow),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Space.gutter, 12, Space.gutter, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(_detail(fix), style: Txt.small(p.muted)),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => setState(() => _follow = !_follow),
                              child: Text(_follow ? 'Following' : 'Follow'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton(
                              onPressed: () => _openExternal(fix),
                              child: const Text('Open in maps'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

String _detail(LiveFix fix) {
  final ago = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(fix.ts));
  final when = ago.inSeconds < 5
      ? 'Updated just now'
      : ago.inMinutes < 1
          ? 'Updated ${ago.inSeconds}s ago'
          : ago.inHours < 1
              ? 'Updated ${ago.inMinutes}m ago'
              : 'Updated ${ago.inHours}h ago';
  final acc = fix.acc == null ? '' : ' · ±${fix.acc!.round()} m';
  final spd = fix.speed == null || fix.speed! < 0.5 ? '' : ' · ${(fix.speed! * 3.6).toStringAsFixed(0)} km/h';
  return '$when$acc$spd';
}

class _MapView extends StatefulWidget {
  const _MapView({required this.fix, required this.interactive, this.follow = true});
  final LiveFix fix;
  final bool interactive;
  final bool follow;

  @override
  State<_MapView> createState() => _MapViewState();
}

class _MapViewState extends State<_MapView> {
  final _map = MapController();
  var _ready = false;

  @override
  void didUpdateWidget(covariant _MapView old) {
    super.didUpdateWidget(old);
    if (!_ready || !widget.follow) return;
    if (old.fix.lat == widget.fix.lat && old.fix.lng == widget.fix.lng) return;
    _map.move(LatLng(widget.fix.lat, widget.fix.lng), _map.camera.zoom);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final fix = widget.fix;
    final here = LatLng(fix.lat, fix.lng);
    final trail = [for (final pt in fix.trail) LatLng(pt.$1, pt.$2)];
    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: here,
            initialZoom: _zoomFor(fix),
            interactionOptions: InteractionOptions(
              flags: widget.interactive ? InteractiveFlag.all : InteractiveFlag.none,
            ),
            onMapReady: () => _ready = true,
            onPositionChanged: (camera, hasGesture) {
              if (hasGesture && widget.follow && widget.interactive) {
                final page = context.findAncestorStateOfType<_LiveMapPageState>();
                if (page != null && page._follow) page.setState(() => page._follow = false);
              }
            },
          ),
          children: [
            TileLayer(urlTemplate: _tiles, userAgentPackageName: 'mentos', maxZoom: 20),
            if (fix.acc != null)
              CircleLayer(circles: [
                CircleMarker(
                  point: here,
                  radius: fix.acc!.clamp(8, 400).toDouble(),
                  useRadiusInMeter: true,
                  color: p.accent.withValues(alpha: .18),
                  borderStrokeWidth: 1,
                  borderColor: p.accent.withValues(alpha: .45),
                ),
              ]),
            if (trail.length > 1)
              PolylineLayer(polylines: [
                Polyline(points: trail, strokeWidth: 4, color: p.accent, borderStrokeWidth: 1, borderColor: p.bg),
              ]),
            MarkerLayer(markers: [
              Marker(
                point: here,
                width: 36,
                height: 36,
                alignment: Alignment.center,
                child: Transform.rotate(
                  angle: ((fix.heading ?? 0) * math.pi / 180),
                  child: Icon(
                    fix.heading == null ? Icons.location_on_rounded : Icons.navigation_rounded,
                    color: p.accent,
                    size: 32,
                  ),
                ),
              ),
            ]),
            RichAttributionWidget(attributions: [
              TextSourceAttribution('OpenStreetMap', onTap: () => launchUrl(Uri.parse('https://www.openstreetmap.org/copyright'), mode: LaunchMode.externalApplication)),
              TextSourceAttribution('CARTO', onTap: () => launchUrl(Uri.parse('https://carto.com/attributions'), mode: LaunchMode.externalApplication)),
            ]),
          ],
        ),
      ],
    );
  }
}

Future<void> _openExternal(LiveFix fix) async {
  final geo = Uri.parse('geo:${fix.lat},${fix.lng}?q=${fix.lat},${fix.lng}');
  if (await canLaunchUrl(geo)) {
    await launchUrl(geo);
    return;
  }
  final web = Uri.parse('https://www.openstreetmap.org/?mlat=${fix.lat}&mlon=${fix.lng}#map=16/${fix.lat}/${fix.lng}');
  await launchUrl(web, mode: LaunchMode.externalApplication);
}
