import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';

/// Kept for old links; the panel now lives in Network diagnostics.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Privacy and transports')),
    body: const PrivacyPanel(),
  );
}

/// Picks which transports the iroh endpoint binds. Changing it restarts the node.
class PrivacyPanel extends ConsumerStatefulWidget {
  const PrivacyPanel({super.key});

  @override
  ConsumerState<PrivacyPanel> createState() => _PrivacyPanelState();
}

class _PrivacyPanelState extends ConsumerState<PrivacyPanel> {
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
    final (title, line, icon) = switch (s.privacy) {
      'relay' => ('Your IP is hidden from peers', 'Every link goes through a relay.', Icons.visibility_off_rounded),
      'tor' => ('Hidden from peers and relays', 'Relays are reached through Tor at ${s.proxyUrl}.', Icons.security_rounded),
      _ => ('Fastest connections', 'Direct paths when possible; peers can see your IP.', Icons.bolt_rounded),
    };

    return ListView(
      padding: const EdgeInsets.only(bottom: Space.xxl),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
          child: Container(
            padding: const EdgeInsets.all(Space.lg),
            decoration: BoxDecoration(color: p.accentSoft, borderRadius: BorderRadius.circular(20)),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: p.accent, borderRadius: BorderRadius.circular(14)),
                  child: Icon(icon, color: p.accentInk),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: Txt.bodyStrong(p.ink)),
                      const SizedBox(height: 2),
                      Text(line, style: Txt.small(p.inkSoft)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
          child: Text(
            'Everything Mentos sends is end-to-end encrypted in every mode. The mode decides who can see your IP address: '
            'the people you connect to, and the relay that introduces you.',
            style: Txt.small(p.muted),
          ),
        ),
        SectionLabel('Mode'),
        _Mode(
          selected: s.privacy == 'standard',
          icon: Icons.bolt_rounded,
          title: 'Standard',
          tag: 'fast',
          body: 'Direct connections when possible, relay otherwise. Peers you connect to can see your IP.',
          onTap: () => _choose('standard'),
        ),
        _Mode(
          selected: s.privacy == 'relay',
          icon: Icons.visibility_off_outlined,
          title: 'Hide my IP',
          tag: 'balanced',
          body: 'No direct connections. Peers only ever see the relay. The relay sees your IP, but only ciphertext.',
          onTap: () => _choose('relay'),
        ),
        _Mode(
          selected: s.privacy == 'tor',
          icon: Icons.security_rounded,
          title: 'Tor',
          tag: 'private',
          body: 'Like Hide my IP, with the relay reached through Tor. Needs Orbot or another Tor HTTP proxy on this phone.',
          onTap: () => _choose('tor'),
          child: Padding(
            padding: const EdgeInsets.only(top: Space.md),
            child: TextField(
              controller: _proxy,
              keyboardType: TextInputType.url,
              style: Txt.mono(p.ink, size: 13),
              decoration: InputDecoration(
                labelText: 'Tor HTTP proxy',
                helperText: 'Orbot: enable its HTTP proxy, default ${Settings.defaultProxy}',
                errorText: _proxy.text.isEmpty ? null : _proxyError(_proxy.text),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (s.privacy == 'tor') _choose('tor');
              },
            ),
          ),
        ),
        if (err != null)
          Container(
            margin: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
            padding: const EdgeInsets.all(Space.md),
            decoration: BoxDecoration(color: p.dangerSoft, borderRadius: BorderRadius.circular(14)),
            child: Text('The node refused these options: $err', style: Txt.small(p.danger)),
          ),
        SectionLabel('What each mode hides'),
        _Matrix(selected: s.privacy),
      ],
    );
  }
}

class _Mode extends StatelessWidget {
  const _Mode({required this.selected, required this.icon, required this.title, required this.tag, required this.body, required this.onTap, this.child});
  final bool selected;
  final IconData icon;
  final String title;
  final String tag;
  final String body;
  final VoidCallback onTap;
  final Widget? child;

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
            color: p.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: selected ? p.accent : p.line, width: selected ? 1.6 : 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(color: selected ? p.accentSoft : p.raised, borderRadius: BorderRadius.circular(12)),
                    child: Icon(icon, size: 20, color: selected ? p.accent : p.inkSoft),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 6,
                          runSpacing: 2,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(title, style: Txt.bodyStrong(p.ink)),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(Radii.pill)),
                              child: Text(tag, style: Txt.mono(p.muted, size: 10)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(body, style: Txt.small(p.muted)),
                      ],
                    ),
                  ),
                  const SizedBox(width: Space.sm),
                  AnimatedContainer(
                    duration: Motion.fast,
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected ? p.accent : Colors.transparent,
                      border: Border.all(color: selected ? p.accent : p.faint, width: 2),
                    ),
                    child: selected ? Icon(Icons.check_rounded, size: 14, color: p.accentInk) : null,
                  ),
                ],
              ),
              ?child,
            ],
          ),
        ),
      ),
    );
  }
}

/// Side by side, with the mode in use highlighted.
class _Matrix extends StatelessWidget {
  const _Matrix({required this.selected});
  final String selected;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    const modes = ['standard', 'relay', 'tor'];
    const heads = ['Standard', 'Hide IP', 'Tor'];
    // true = protected (good), false = exposed, null = neutral text.
    const rows = <(String, List<Object>)>[
      ('Peers see your IP', [false, true, true]),
      ('Relay sees your IP', [false, false, true]),
      ('Anyone reads content', [true, true, true]),
      ('Works without internet', ['LAN', 'no', 'no']),
      ('Speed', ['fast', 'ok', 'slow']),
    ];
    Widget cell(Object v, bool on) {
      if (v is bool) {
        return Icon(
          v ? Icons.check_circle_rounded : Icons.cancel_rounded,
          size: 18,
          color: v ? p.accent : p.danger.withValues(alpha: on ? 1 : .55),
        );
      }
      return Text('$v', textAlign: TextAlign.center, style: Txt.mono(on ? p.ink : p.muted, size: 11.5, w: FontWeight.w500));
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
      child: Container(
        decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: p.line)),
        clipBehavior: Clip.antiAlias,
        child: Table(
          columnWidths: const {0: FlexColumnWidth(2.2)},
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            TableRow(
              decoration: BoxDecoration(color: p.raised),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Space.md, 10, 4, 10),
                  child: Text('PROTECTS', style: Txt.label(p.muted)),
                ),
                for (var j = 0; j < 3; j++)
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    color: modes[j] == selected ? p.accentSoft : null,
                    child: Text(
                      heads[j],
                      textAlign: TextAlign.center,
                      style: Txt.mono(modes[j] == selected ? p.accent : p.inkSoft, size: 11, w: FontWeight.w600),
                    ),
                  ),
              ],
            ),
            for (final (i, r) in rows.indexed)
              TableRow(
                decoration: BoxDecoration(border: i == 0 ? null : Border(top: BorderSide(color: p.line))),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Space.md, 12, 4, 12),
                    child: Text(r.$1, style: Txt.small(p.inkSoft)),
                  ),
                  for (var j = 0; j < 3; j++)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      color: modes[j] == selected ? p.accentSoft.withValues(alpha: .5) : null,
                      alignment: Alignment.center,
                      child: cell(r.$2[j], modes[j] == selected),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
