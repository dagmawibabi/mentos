import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../state/accounts.dart';
import '../../state/session.dart';
import '../../widgets/ui.dart';

/// Identities on this device. Only one runs at a time: switching closes the
/// open account's node and opens the other, each with its own keys,
/// encrypted database and files.
class AccountsScreen extends ConsumerStatefulWidget {
  const AccountsScreen({super.key});

  @override
  ConsumerState<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends ConsumerState<AccountsScreen> {
  late Future<({List<AccountEntry> accounts, String active})> _list = ref.read(sessionProvider.notifier).accounts();

  void _reload() => setState(() => _list = ref.read(sessionProvider.notifier).accounts());

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final session = ref.read(sessionProvider.notifier);
    return Scaffold(
      appBar: AppBar(title: const Text('Accounts')),
      body: FutureBuilder(
        future: _list,
        builder: (context, snap) {
          final data = snap.data;
          if (data == null) return const Loading();
          final ready = data.accounts.where((a) => a.id.isNotEmpty || a.dir == data.active).toList();
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
                child: Text(
                  'Each account is a separate key with its own chats, posts and files. '
                  'Only the open one is online, so the others do not receive messages until you switch to them.',
                  style: Txt.small(p.muted),
                ),
              ),
              SectionLabel('On this device'),
              for (final a in ready)
                ListTile(
                  leading: _Initial(name: a.name.isEmpty ? (a.id.isEmpty ? '?' : alias(a.id)) : a.name, on: a.dir == data.active),
                  title: Text(a.name.isNotEmpty ? a.name : (a.id.isEmpty ? 'New account' : alias(a.id))),
                  subtitle: Text(a.id.isEmpty ? 'not set up' : shortId(a.id), style: Txt.mono(p.muted, size: 11)),
                  trailing: a.dir == data.active
                      ? Icon(Icons.check_circle_rounded, color: p.accent)
                      : IconBtn(Icons.more_vert_rounded, tooltip: 'Account options', onTap: () => _options(a)),
                  onTap: a.dir == data.active
                      ? null
                      : () async {
                          Navigator.of(context).popUntil((r) => r.isFirst);
                          await session.switchAccount(a.dir);
                        },
                ),
              const SizedBox(height: Space.md),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.person_add_alt_rounded, size: 18),
                  label: const Text('Add an account'),
                  onPressed: () async {
                    final ok = await confirm(
                      context,
                      title: 'Add an account?',
                      body: 'This account goes offline while you create or restore the new one. You can switch back any time.',
                      action: 'Continue',
                    );
                    if (!ok || !context.mounted) return;
                    Navigator.of(context).popUntil((r) => r.isFirst);
                    await session.addAccount();
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _options(AccountEntry a) async {
    final session = ref.read(sessionProvider.notifier);
    await showActions(context, [
      SheetAction(Icons.swap_horiz_rounded, 'Switch to this account', () async {
        Navigator.of(context).popUntil((r) => r.isFirst);
        await session.switchAccount(a.dir);
      }),
      SheetAction(Icons.delete_forever_outlined, 'Erase from this device', () async {
        final ok = await confirm(
          context,
          title: 'Erase ${a.name.isEmpty ? 'this account' : a.name}?',
          body: 'Deletes its key, chats, posts and files from this phone. Without its recovery phrase it cannot come back.',
          action: 'Erase',
          danger: true,
        );
        if (!ok) return;
        await session.removeAccount(a.dir);
        _reload();
      }, danger: true),
    ]);
  }
}

class _Initial extends StatelessWidget {
  const _Initial({required this.name, required this.on});
  final String name;
  final bool on;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return CircleAvatar(
      backgroundColor: on ? p.accentSoft : p.raised,
      child: Text(name.characters.first.toUpperCase(), style: Txt.bodyStrong(on ? p.accent : p.inkSoft)),
    );
  }
}
