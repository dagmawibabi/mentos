import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';

class NewGroupScreen extends ConsumerStatefulWidget {
  const NewGroupScreen({super.key});

  @override
  ConsumerState<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends ConsumerState<NewGroupScreen> {
  final _name = TextEditingController();
  final _picked = <String>{};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  Future<void> _create() async {
    if (_name.text.trim().isEmpty) {
      toast(context, 'Give the group a name');
      return;
    }
    setState(() => _busy = true);
    final g = await ref.read(engineProvider).createGroup(_name.text, _picked.toList());
    if (mounted) context.pushReplacement('/g/${g.id}');
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final people = ref.watch(peopleProvider).value ?? const <Peer>[];
    return Scaffold(
      appBar: AppBar(title: const Text('New group')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, 0),
            child: TextField(
              controller: _name,
              autofocus: true,
              maxLength: 48,
              decoration: const InputDecoration(hintText: 'Group name', counterText: ''),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
            child: Text(
              "Invite people now or later from the group's info. Anyone you pick gets an invite first and can accept or decline before joining the sealed chat.",
              style: Txt.small(p.muted),
            ),
          ),
          SectionLabel('Invite (optional)', trailing: _picked.isEmpty ? null : Text('${_picked.length} picked', style: Txt.mono(p.muted, size: 11))),
          if (people.where((x) => !x.blocked).isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
              child: Text('No contacts yet. Create the group and share an invite later.', style: Txt.small(p.muted)),
            ),
          for (final x in people.where((x) => !x.blocked))
            CheckboxListTile(
              value: _picked.contains(x.id),
              onChanged: (v) => setState(() => v == true ? _picked.add(x.id) : _picked.remove(x.id)),
              secondary: Avatar(id: x.id, size: 38),
              title: Text(x.name),
              controlAffinity: ListTileControlAffinity.trailing,
            ),
          const SizedBox(height: Space.xl),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: FilledButton(
              onPressed: _name.text.trim().isEmpty || _busy ? null : _create,
              child: Text(_busy ? 'Creating…' : (_picked.isEmpty ? 'Create group' : 'Create and invite ${_picked.length}')),
            ),
          ),
        ],
      ),
    );
  }
}
