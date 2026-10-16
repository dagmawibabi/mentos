import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';

/// Picks which transports the iroh endpoint binds. Changing it restarts the node.
class PrivacyScreen extends ConsumerStatefulWidget {
  const PrivacyScreen({super.key});

  @override
  ConsumerState<PrivacyScreen> createState() => _PrivacyScreenState();
}

class _PrivacyScreenState extends ConsumerState<PrivacyScreen> {
  late final TextEditingController _proxy;

  @override
  void initState() {
    super.initState();
    _proxy = TextEditingController(text: ref.read(settingsProvider).proxyUrl);
  }

  @override
  void dispose() {
    _proxy.dispose();
    super.dispose();
  }

  String? _proxyError(String v) {
    final u = Uri.tryParse(v.trim());
    if (u == null || !u.hasScheme || u.host.isEmpty) return 'Use a URL like http://127.0.0.1:8118';
    if (u.scheme != 'http' && u.scheme != 'https') return 'Needs an HTTP CONNECT proxy (Orbot: port 8118), not SOCKS';
    return null;
  }

  void _choose(String mode) {
    final n = ref.read(settingsProvider.notifier);
    if (mode == 'tor') {
      final err = _proxyError(_proxy.text);
      if (err != null) {
        toast(context, err);
        return;
      }
      n.update((s) => s.copyWith(privacy: mode, proxyUrl: _proxy.text.trim()));
    } else {
      n.update((s) => s.copyWith(privacy: mode));
    }
    toast(context, 'Restarting your node with the new transports');
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final s = ref.watch(settingsProvider);
    final e = ref.watch(maybeEngineProvider);
    final err = e?.netOptionsError;

    return Scaffold(
      appBar: AppBar(title: const Text('Privacy and transports')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
            child: Text(
              'Everything Mentos sends is end-to-end encrypted either way. These modes decide who can see '
              'your IP address: the people you connect to, and the relay that introduces you.',
              style: Txt.small(p.muted),
            ),
          ),
          SectionLabel('Mode'),
          _Mode(
            selected: s.privacy == 'standard',
            icon: Icons.bolt_rounded,
            title: 'Standard',
            body: 'Direct connections when possible, relay otherwise. Fastest; peers you connect to can see your IP.',
            onTap: () => _choose('standard'),
          ),
          _Mode(
            selected: s.privacy == 'relay',
            icon: Icons.visibility_off_outlined,
            title: 'Hide my IP',
            body: 'No direct connections. Every link goes through an iroh relay, so peers only ever see the relay. '
                'The relay sees your IP but only ciphertext.',
            onTap: () => _choose('relay'),
          ),
          _Mode(
            selected: s.privacy == 'tor',
            icon: Icons.security_rounded,
            title: 'Tor',
            body: 'Like Hide my IP, and the relay is reached through Tor. Neither peers nor the relay see your IP. '
                'Needs Orbot (or another Tor HTTP proxy) running on this phone. Slowest.',
            onTap: () => _choose('tor'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
            child: TextField(
              controller: _proxy,
              keyboardType: TextInputType.url,
              style: Txt.mono(p.ink, size: 13),
              decoration: InputDecoration(
                labelText: 'Tor HTTP proxy',
                helperText: 'Orbot: enable its HTTP proxy, default ${Settings.defaultProxy}',
                errorText: _proxy.text.isEmpty ? null : _proxyError(_proxy.text),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (s.privacy == 'tor') _choose('tor');
              },
            ),
          ),
          if (err != null)
            Container(
              margin: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, 0),
              padding: const EdgeInsets.all(Space.md),
              decoration: BoxDecoration(color: p.dangerSoft, borderRadius: BorderRadius.circular(Radii.md)),
              child: Text('The node refused these options: $err', style: Txt.small(p.danger)),
            ),
          SectionLabel('What each mode hides'),
          const _Matrix(),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, 0),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.monitor_heart_outlined, size: 18),
              label: const Text('Check it in diagnostics'),
              onPressed: () => context.push('/diagnostics'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Mode extends StatelessWidget {
  const _Mode({required this.selected, required this.icon, required this.title, required this.body, required this.onTap});
  final bool selected;
  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.sm),
      child: Pressable(
        onTap: selected ? null : onTap,
        child: AnimatedContainer(
          duration: Motion.fast,
          padding: const EdgeInsets.all(Space.lg),
          decoration: BoxDecoration(
            color: selected ? p.accentSoft : p.surface,
            borderRadius: BorderRadius.circular(Radii.lg),
            border: Border.all(color: selected ? p.accent : p.line),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: selected ? p.accent : p.inkSoft),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Txt.bodyStrong(p.ink)),
                    const SizedBox(height: 2),
                    Text(body, style: Txt.small(p.muted)),
                  ],
                ),
              ),
              if (selected) Icon(Icons.check_rounded, color: p.accent, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _Matrix extends StatelessWidget {
  const _Matrix();

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    const rows = [
      ('', 'Standard', 'Hide IP', 'Tor'),
      ('Peers see your IP', 'yes', 'no', 'no'),
      ('Relay sees your IP', 'yes', 'yes', 'no'),
      ('Anyone reads content', 'no', 'no', 'no'),
      ('Works without internet', 'LAN', 'no', 'no'),
      ('Speed', 'fast', 'ok', 'slow'),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
      child: Table(
        columnWidths: const {0: FlexColumnWidth(2.2)},
        children: [
          for (final (i, r) in rows.indexed)
            TableRow(
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.line))),
              children: [
                for (final (j, c) in [r.$1, r.$2, r.$3, r.$4].indexed)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      c,
                      textAlign: j == 0 ? TextAlign.left : TextAlign.center,
                      style: i == 0
                          ? Txt.mono(p.muted, size: 10.5, w: FontWeight.w500)
                          : Txt.mono(j == 0 ? p.inkSoft : (c == 'no' ? p.accent : p.ink), size: 11),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
