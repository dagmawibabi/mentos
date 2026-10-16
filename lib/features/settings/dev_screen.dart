import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../state/providers.dart';
import '../../widgets/ui.dart';
import 'dev_api.dart';

class DevScreen extends ConsumerWidget {
  const DevScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final settings = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final api = ref.watch(devApiProvider);
    final e = ref.watch(maybeEngineProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Developer')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          SwitchTile(
            icon: Icons.terminal_rounded,
            title: 'Developer mode',
            subtitle: 'Keeps a localhost API open and shows node detail',
            value: settings.devMode,
            onChanged: (v) => n.update((x) => x.copyWith(devMode: v)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
            child: Text(
              settings.devMode
                  ? 'Listening on http://127.0.0.1:${api.port}. Only this computer can call it.'
                  : 'Turn developer mode on to open the API.',
              style: Txt.small(p.muted),
            ),
          ),
          SectionLabel('API'),
          for (final line in const [
            'GET /v1/me',
            'GET /v1/balance',
            'GET /v1/status',
            'GET /v1/chats',
            'POST /v1/message  {scope, text}',
            'POST /v1/pay  {to, amount, memo}',
          ])
            ListTile(
              dense: true,
              title: Text(line, style: Txt.mono(p.ink, size: 12)),
              onTap: () {
                Clipboard.setData(ClipboardData(text: line.split(' ').first.contains('/') ? 'http://127.0.0.1:8787${line.split(' ').first.substring(line.split(' ').first.indexOf('/'))}' : line));
                toast(context, 'Copied');
              },
            ),
          SectionLabel('This node'),
          if (e == null)
            const Padding(padding: EdgeInsets.all(Space.gutter), child: Text('No identity is open.'))
          else ...[
            _line(p, 'id', e.me.id),
            _line(p, 'status', e.status),
            _line(p, 'relay', e.preferredRelay ?? 'automatic'),
            _line(p, 'balance', '${e.coin?.balance() ?? 0} minor'),
          ],
        ],
      ),
    );
  }

  Widget _line(Palette p, String k, String v) => Padding(
        padding: const EdgeInsets.fromLTRB(Space.gutter, 4, Space.gutter, 4),
        child: Text('$k  $v', style: Txt.mono(p.inkSoft, size: 11)),
      );
}
