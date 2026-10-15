import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../state/providers.dart';

class CreateSpaceScreen extends ConsumerStatefulWidget {
  const CreateSpaceScreen({super.key});

  @override
  ConsumerState<CreateSpaceScreen> createState() => _CreateSpaceScreenState();
}

class _CreateSpaceScreenState extends ConsumerState<CreateSpaceScreen> {
  final _name = TextEditingController();
  final _about = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    final s = await ref.read(engineProvider).createSpace(_name.text, _about.text);
    if (mounted) context.pushReplacement('/s/${s.id}');
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Scaffold(
      appBar: AppBar(title: const Text('New space')),
      body: ListView(
        padding: const EdgeInsets.all(Space.gutter),
        children: [
          Text('Give it a name', style: Txt.display(p.ink).copyWith(fontSize: 26)),
          const SizedBox(height: Space.sm),
          Text(
            'Everyone who joins gets the space key. Messages are encrypted with it and travel between '
            'members over gossip — no server stores the space.',
            style: Txt.small(p.muted),
          ),
          const SizedBox(height: Space.xl),
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: 48,
            style: Txt.heading(p.ink),
            decoration: const InputDecoration(hintText: 'Space name', counterText: ''),
          ),
          const SizedBox(height: Space.md),
          TextField(
            controller: _about,
            maxLines: 3,
            maxLength: 280,
            decoration: const InputDecoration(hintText: 'What is it about? (optional)'),
          ),
          const SizedBox(height: Space.md),
          Text('Starts with #general and #random. You can add channels and moderators later.',
              style: Txt.mono(p.faint, size: 11)),
          const SizedBox(height: Space.xl),
          FilledButton(
            onPressed: _name.text.trim().isEmpty || _busy ? null : _create,
            child: Text(_busy ? 'Creating…' : 'Create space'),
          ),
        ],
      ),
    );
  }
}
