import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../plugins/plugin_providers.dart';
import '../../state/providers.dart';
import '../../widgets/ui.dart';
import 'dev_api.dart';

final _lanAddrsProvider = FutureProvider.autoDispose<List<String>>((ref) => DevApi.lanAddresses());

class DevScreen extends ConsumerStatefulWidget {
  const DevScreen({super.key});

  @override
  ConsumerState<DevScreen> createState() => _DevScreenState();
}

class _DevScreenState extends ConsumerState<DevScreen> {
  var _showCode = false;

  void _copy(String text, [String what = 'Copied']) {
    Clipboard.setData(ClipboardData(text: text));
    toast(context, what);
  }

  Future<void> _setLan(bool on) async {
    if (on) {
      final ok = await confirm(
        context,
        title: 'Allow other devices?',
        body: 'Phones and computers on the same Wi-Fi can open the dashboard and act as you: read chats, send messages and coins. '
            'They still need the access code. Turn this off when you\'re done.',
        action: 'Allow',
      );
      if (!ok) return;
    }
    ref.read(settingsProvider.notifier).update((x) => x.copyWith(devLan: on));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final api = ref.watch(devApiProvider);
    ref.watch(devApiTickProvider);
    ref.watch(pluginTickProvider);
    final e = ref.watch(maybeEngineProvider);
    final plugins = ref.watch(pluginHostProvider);
    final lanAddrs = s.devLan ? (ref.watch(_lanAddrsProvider).value ?? const <String>[]) : const <String>[];
    final local = 'http://127.0.0.1:${api.port}';
    final lanUrls = [for (final a in lanAddrs) 'http://$a:${api.port}'];
    final now = DateTime.now().millisecondsSinceEpoch;

    final lines = <(int, String, bool)>[
      for (final r in api.requests) (r.ts, '${r.method} ${r.path} ${r.status} · ${r.ip}', r.status >= 400),
      for (final ev in api.events) (ev['ts'] as int, '${ev['kind']}  ${ev['text']}', false),
      for (final l in plugins?.logs() ?? const []) (l.ts, '${l.plugin}  ${l.text}', l.level == 'error'),
    ]..sort((a, b) => b.$1.compareTo(a.$1));

    return Scaffold(
      appBar: AppBar(title: const Text('Developer')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          SwitchTile(
            icon: Icons.terminal_rounded,
            title: 'Developer mode',
            subtitle: 'Opens the API and a browser dashboard',
            value: s.devMode,
            onChanged: (v) => n.update((x) => x.copyWith(devMode: v)),
          ),
          if (!s.devMode)
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
              child: Text(
                'Developer mode serves a dashboard you can open in any browser to use Mentos from a computer: chats, network, wallet, '
                'plugins and live logs. Scripts can call the same API. It stays on this device unless you allow others.',
                style: Txt.small(p.muted),
              ),
            )
          else ...[
            // ---------------------------------------------------- dashboard
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
              child: Container(
                padding: const EdgeInsets.all(Space.lg),
                decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(20), border: Border.all(color: p.line)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(shape: BoxShape.circle, color: api.running ? p.accent : p.faint),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            api.running ? (api.lan ? 'Open to your network' : 'Open on this device') : 'Starting…',
                            style: Txt.bodyStrong(p.ink),
                          ),
                        ),
                        Text('${api.clients.values.where((c) => c.authed).length} signed in', style: Txt.mono(p.muted, size: 11)),
                      ],
                    ),
                    const SizedBox(height: Space.md),
                    _UrlRow(url: local, label: 'This device', onCopy: () => _copy(local, 'Link copied')),
                    for (final u in lanUrls) _UrlRow(url: u, label: 'Other devices', onCopy: () => _copy(u, 'Link copied')),
                    const SizedBox(height: Space.md),
                    Text('ACCESS CODE', style: Txt.label(p.muted)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: SelectableText(
                            _showCode ? s.devToken : s.devToken.replaceAll(RegExp(r'[a-z0-9]'), '•'),
                            style: Txt.mono(p.ink, size: 16, w: FontWeight.w600),
                          ),
                        ),
                        IconBtn(_showCode ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20, tooltip: 'Show', onTap: () => setState(() => _showCode = !_showCode)),
                        IconBtn(Icons.copy_rounded, size: 20, tooltip: 'Copy', onTap: () => _copy(s.devToken, 'Access code copied')),
                        IconBtn(
                          Icons.autorenew_rounded,
                          size: 20,
                          tooltip: 'New code',
                          onTap: () async {
                            if (!await confirm(context, title: 'Make a new code?', body: 'Every browser and script signed in with the old one is signed out.', action: 'New code')) return;
                            n.update((x) => x.copyWith(devToken: DevApi.newToken()));
                            api.clients.clear();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: Space.md),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            icon: const Icon(Icons.open_in_browser_rounded, size: 18),
                            label: const Text('Open dashboard'),
                            onPressed: () => launchUrl(Uri.parse(local), mode: LaunchMode.externalApplication),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: Space.sm),
            SwitchTile(
              icon: Icons.wifi_tethering_rounded,
              title: 'Allow other devices',
              subtitle: s.devLan ? 'Anyone on this network with the code can connect' : 'Off: only apps on this device can connect',
              value: s.devLan,
              onChanged: _setLan,
            ),
            if (s.devLan && lanUrls.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
                      child: QrImageView(data: lanUrls.first, size: 112, padding: EdgeInsets.zero),
                    ),
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: Text(
                        'Scan with another phone or open the link on a computer on the same Wi-Fi, then type the access code. The code is not in the QR.',
                        style: Txt.small(p.muted),
                      ),
                    ),
                  ],
                ),
              ),
            if (s.devLan && lanUrls.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
                child: Text('No local network address found. Join Wi-Fi to reach this device.', style: Txt.small(p.muted)),
              ),

            // ---------------------------------------------------- clients
            if (api.clients.isNotEmpty) ...[
              SectionLabel('Connected clients'),
              for (final c in api.clients.values.toList()..sort((a, b) => b.lastSeen.compareTo(a.lastSeen)))
                Padding(
                  padding: const EdgeInsets.fromLTRB(Space.gutter, 4, Space.gutter, 4),
                  child: Row(
                    children: [
                      Icon(c.ip == '127.0.0.1' ? Icons.computer_rounded : Icons.devices_other_rounded, size: 18, color: c.authed ? p.accent : p.muted),
                      const SizedBox(width: Space.md),
                      Expanded(child: Text(c.ip == '127.0.0.1' ? 'This device' : c.ip, style: Txt.mono(p.ink, size: 12.5))),
                      Text('${c.requests} req · ${_ago(now - c.lastSeen)}', style: Txt.mono(p.muted, size: 11)),
                    ],
                  ),
                ),
            ],
          ],

          // ------------------------------------------------------ tools
          SectionLabel('Tools'),
          RowTile(
            icon: Icons.extension_outlined,
            title: 'Plugins',
            subtitle: '${plugins?.installed.length ?? 0} installed · push new ones from the dashboard',
            onTap: () => context.push('/market?tab=plugins'),
          ),
          RowTile(icon: Icons.monitor_heart_outlined, title: 'Network diagnostics', subtitle: 'Links, paths, node and transports', onTap: () => context.push('/diagnostics')),
          RowTile(icon: Icons.travel_explore_rounded, title: 'Network atlas', subtitle: 'Every node and relay announced', onTap: () => context.push('/atlas')),
          RowTile(icon: Icons.storage_rounded, title: 'Data explorer', subtitle: 'What this device stores', onTap: () => context.push('/data')),
          if (e != null)
            RowTile(
              icon: Icons.restart_alt_rounded,
              title: 'Restart node',
              subtitle: e.status,
              onTap: () async {
                await e.disconnectNode();
                await e.connectNode();
                if (context.mounted) toast(context, 'Node restarted');
              },
            ),

          // ------------------------------------------------------ console
          if (s.devMode) ...[
            SectionLabel('Console', trailing: Text('${lines.length}', style: Txt.mono(p.muted, size: 11))),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: Space.gutter),
              padding: const EdgeInsets.all(Space.md),
              height: 220,
              decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: p.line)),
              child: lines.isEmpty
                  ? Text('Requests, node events and plugin logs show up here.', style: Txt.mono(p.muted, size: 11))
                  : ListView.builder(
                      itemCount: lines.length.clamp(0, 200),
                      itemBuilder: (_, i) {
                        final l = lines[i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text('${_hms(l.$1)}  ${l.$2}', style: Txt.mono(l.$3 ? p.danger : p.inkSoft, size: 11)),
                        );
                      },
                    ),
            ),
            SectionLabel('API'),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.sm),
              child: Text('Every call needs the header Authorization: Bearer <access code>. Tap a route to copy a curl command.', style: Txt.small(p.muted)),
            ),
            for (final line in DevApi.routes)
              InkWell(
                onTap: () {
                  final parts = line.split(RegExp(r'\s+'));
                  final path = parts[1].split('?').first.replaceAll('<id>', 'ID');
                  _copy(
                    'curl ${parts[0] == 'GET' ? '' : '-X ${parts[0]} '}-H "Authorization: Bearer ${s.devToken}" $local$path',
                    'curl copied',
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Space.gutter, 6, Space.gutter, 6),
                  child: Text(line, style: Txt.mono(p.ink, size: 11.5)),
                ),
              ),
          ],

          SectionLabel('This node'),
          if (e == null)
            const Padding(padding: EdgeInsets.all(Space.gutter), child: Text('No identity is open.'))
          else ...[
            _line(p, 'id', e.me.id, () => _copy(e.me.id)),
            _line(p, 'status', e.status, null),
            _line(p, 'relay', e.preferredRelay ?? 'automatic', null),
            _line(p, 'privacy', e.settings.privacy, null),
            _line(p, 'balance', '${e.coin?.balance() ?? 0} minor', null),
          ],
        ],
      ),
    );
  }

  Widget _line(Palette p, String k, String v, VoidCallback? onTap) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, 4, Space.gutter, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 72, child: Text(k, style: Txt.mono(p.muted, size: 11))),
          Expanded(child: Text(v, style: Txt.mono(p.inkSoft, size: 11))),
        ],
      ),
    ),
  );
}

class _UrlRow extends StatelessWidget {
  const _UrlRow({required this.url, required this.label, required this.onCopy});
  final String url;
  final String label;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return InkWell(
      onTap: onCopy,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            SizedBox(width: 96, child: Text(label, style: Txt.small(p.muted))),
            Expanded(child: Text(url, style: Txt.mono(p.accent, size: 13, w: FontWeight.w600))),
            Icon(Icons.copy_rounded, size: 15, color: p.faint),
          ],
        ),
      ),
    );
  }
}

String _ago(int ms) {
  final s = ms ~/ 1000;
  if (s < 60) return 'now';
  if (s < 3600) return '${s ~/ 60}m';
  return '${s ~/ 3600}h';
}

String _hms(int ts) {
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}
