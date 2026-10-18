import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../core/crypto/crypto.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../state/accounts.dart';
import '../../state/session.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';

enum _Step { welcome, name, phrase, restore }

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  _Step _step = _Step.welcome;
  Identity? _identity;
  final _name = TextEditingController();
  final _phrase = TextEditingController();
  bool _confirmed = false;
  bool _busy = false;
  String? _error;
  String? _vault;

  /// Set when this is an extra account being added; lets the person go back.
  AccountEntry? _back;

  @override
  void initState() {
    super.initState();
    ref.read(sessionProvider.notifier).returnTarget().then((t) {
      if (mounted && t != null) setState(() => _back = t);
    });
  }

  Future<void> _generate() async {
    setState(() => _busy = true);
    final id = await Identity.generate();
    setState(() {
      _identity = id;
      _busy = false;
      _step = _Step.phrase;
    });
  }

  Future<void> _finish() async {
    setState(() => _busy = true);
    try {
      await ref.read(sessionProvider.notifier).signIn(_identity!, name: _name.text);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await Identity.fromPhrase(_phrase.text);
      if (_vault != null) {
        await ref.read(sessionProvider.notifier).importVault(_vault!, id);
      }
      if (!mounted) return;
      await ref.read(sessionProvider.notifier).signIn(id);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is FormatException ? e.message : '$e';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return PopScope(
      canPop: _step == _Step.welcome,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _step = _step == _Step.phrase ? _Step.name : _Step.welcome);
      },
      child: Scaffold(
        body: SafeArea(
          child: AnimatedSwitcher(
            duration: Motion.base,
            switchInCurve: Motion.curve,
            child: KeyedSubtree(
              key: ValueKey(_step),
              child: switch (_step) {
                _Step.welcome => _welcome(p),
                _Step.name => _nameStep(p),
                _Step.phrase => _phraseStep(p),
                _Step.restore => _restoreStep(p),
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _welcome(Palette p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.xl, Space.xl, Space.xl, Space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const MentosMark(size: 34),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: p.accent.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: p.accent.withValues(alpha: .3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: p.accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'P2P · Encrypted · Serverless',
                      style: Txt.label(p.accent).copyWith(
                        fontWeight: FontWeight.w600,
                        letterSpacing: .3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const Spacer(),
          Text('Your social life,\nheld in your hand.', style: Txt.display(p.ink).copyWith(fontSize: 34)),
          const SizedBox(height: Space.lg),
          Text(
            'Mentos has no accounts. Posts and messages stay on this phone and go to the people you choose. '
            'When two phones cannot reach each other directly, a relay helps them connect. Relays do not keep an account for you. '
            'A hidden profile is offered only to people you follow.',
            style: Txt.body(p.muted),
          ),
          const SizedBox(height: Space.xl),
          const _Principle(
            icon: Icons.phone_android_rounded,
            title: 'Stored on your device',
            body: 'Others see your posts and messages while you are online.',
          ),
          const _Principle(
            icon: Icons.handshake_outlined,
            title: 'Kept only with consent',
            body: 'A copy lives on someone else\'s phone only if you allow it and they agree.',
          ),
          const _Principle(
            icon: Icons.key_rounded,
            title: 'You are a key',
            body: 'No email, no number. A key on this device is your identity.',
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => setState(() => _step = _Step.name),
              child: const Text('Create identity'),
            ),
          ),
          const SizedBox(height: Space.sm),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => setState(() => _step = _Step.restore),
              child: Text('Restore from recovery phrase', style: Txt.bodyStrong(p.muted)),
            ),
          ),
          if (_back != null)
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: () => ref.read(sessionProvider.notifier).cancelAddAccount(_back!),
                icon: const Icon(Icons.arrow_back_rounded, size: 18),
                label: Text('Back to ${_back!.name.isEmpty ? 'your account' : _back!.name}'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _nameStep(Palette p) {
    return Padding(
      padding: const EdgeInsets.all(Space.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconBtn(Icons.arrow_back_rounded, onTap: () => setState(() => _step = _Step.welcome)),
          const SizedBox(height: Space.lg),
          Text('What should people\ncall you?', style: Txt.display(p.ink)),
          const SizedBox(height: Space.md),
          Text('Optional. Leave it empty and you\'ll appear under an alias drawn from your key.',
              style: Txt.body(p.muted)),
          const SizedBox(height: Space.xl),
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: 40,
            textCapitalization: TextCapitalization.words,
            style: Txt.title(p.ink),
            decoration: const InputDecoration(hintText: 'Display name', counterText: ''),
            onSubmitted: (_) => _generate(),
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _busy ? null : _generate,
              child: _busy ? const _Spinner() : const Text('Generate my key'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _phraseStep(Palette p) {
    final id = _identity!;
    final words = id.phrase.split(' ');
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(Space.xl),
            children: [
              Row(
                children: [
                  Sigil(id: id.id, size: 52),
                  const SizedBox(width: Space.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_name.text.trim().isEmpty ? alias(id.id) : _name.text.trim(), style: Txt.heading(p.ink)),
                        const SizedBox(height: 2),
                        Text(shortId(id.id), style: Txt.mono(p.muted)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Space.xl),
              Text('Your recovery phrase', style: Txt.title(p.ink)),
              const SizedBox(height: Space.sm),
              Text(
                'These 24 words are your identity. Write them down and keep them offline. '
                'Anyone with them becomes you; without them, a lost phone means a lost account.',
                style: Txt.body(p.muted),
              ),
              const SizedBox(height: Space.lg),
              Container(
                padding: const EdgeInsets.all(Space.lg),
                decoration: BoxDecoration(
                  color: p.surface,
                  borderRadius: BorderRadius.circular(Radii.lg),
                  border: Border.all(color: p.line),
                ),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 10,
                  children: [
                    for (var i = 0; i < words.length; i++)
                      SizedBox(
                        width: 96,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 22,
                              child: Text('${i + 1}'.padLeft(2, '0'), style: Txt.mono(p.faint, size: 11)),
                            ),
                            Text(words[i], style: Txt.mono(p.ink, size: 13, w: FontWeight.w500)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: Space.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: id.phrase));
                    toast(context, 'Copied. Clear your clipboard once it\'s stored safely.');
                  },
                  icon: Icon(Icons.copy_rounded, size: 16, color: p.muted),
                  label: Text('Copy', style: Txt.small(p.muted)),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.xl, 0, Space.xl, Space.lg),
          child: Column(
            children: [
              InkWell(
                onTap: () => setState(() => _confirmed = !_confirmed),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      AnimatedContainer(
                        duration: Motion.fast,
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: _confirmed ? p.ink : Colors.transparent,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: _confirmed ? p.ink : p.faint, width: 1.5),
                        ),
                        child: _confirmed ? Icon(Icons.check_rounded, size: 14, color: p.bg) : null,
                      ),
                      const SizedBox(width: Space.md),
                      Expanded(child: Text('I wrote my recovery phrase down', style: Txt.body(p.ink))),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Space.sm),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _confirmed && !_busy ? _finish : null,
                  child: _busy ? const _Spinner() : const Text('Start Mentos'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _restoreStep(Palette p) {
    return Padding(
      padding: const EdgeInsets.all(Space.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconBtn(Icons.arrow_back_rounded, onTap: () => setState(() => _step = _Step.welcome)),
          const SizedBox(height: Space.lg),
          Text('Restore your identity', style: Txt.display(p.ink)),
          const SizedBox(height: Space.md),
          Text(
            'Enter your 24 words. They open this identity and any chats or files you saved from it. '
            'Posts others kept also come back when those people are online.',
            style: Txt.body(p.muted),
          ),
          const SizedBox(height: Space.xl),
          TextField(
            controller: _phrase,
            minLines: 4,
            maxLines: 6,
            autocorrect: false,
            enableSuggestions: false,
            style: Txt.mono(p.ink, size: 14),
            decoration: InputDecoration(hintText: 'word word word …', errorText: _error),
          ),
          const SizedBox(height: Space.md),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () async {
                    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Saved Mentos data');
                    if (dir != null) setState(() => _vault = dir);
                  },
            child: Text(_vault == null ? 'Choose saved chats and files' : 'Saved copy selected'),
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _busy ? null : _restore,
              child: _busy ? const _Spinner() : const Text('Restore'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Principle extends StatelessWidget {
  const _Principle({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(11)),
            child: Icon(icon, size: 18, color: p.ink),
          ),
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
        ],
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: context.pal.bg),
      );
}
