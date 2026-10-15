import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../state/providers.dart';
import '../../state/session.dart';
import '../../widgets/ui.dart';

class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final words = ref.read(engineProvider).me.phrase.split(' ');
    return Scaffold(
      appBar: AppBar(title: const Text('Recovery phrase')),
      body: ListView(
        padding: const EdgeInsets.all(Space.gutter),
        children: [
          Text(
            'These words restore your identity. A saved copy of your chats and files opens with the same words. Never type them into a website or send them to anyone.',
            style: Txt.body(p.muted),
          ),
          const SizedBox(height: Space.xl),
          GestureDetector(
            onTap: () => setState(() => _revealed = !_revealed),
            child: Container(
              padding: const EdgeInsets.all(Space.lg),
              decoration: BoxDecoration(
                color: p.surface,
                borderRadius: BorderRadius.circular(Radii.lg),
                border: Border.all(color: p.line),
              ),
              child: Stack(
                children: [
                  ImageFiltered(
                    enabled: !_revealed,
                    imageFilter: ImageFilter.blur(sigmaX: 7, sigmaY: 7),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 10,
                      children: [
                        for (var i = 0; i < words.length; i++)
                          SizedBox(
                            width: 96,
                            child: Row(children: [
                              SizedBox(width: 22, child: Text('${i + 1}'.padLeft(2, '0'), style: Txt.mono(p.faint, size: 11))),
                              Text(words[i], style: Txt.mono(p.ink, size: 13, w: FontWeight.w500)),
                            ]),
                          ),
                      ],
                    ),
                  ),
                  if (!_revealed)
                    Positioned.fill(
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(color: p.ink, borderRadius: BorderRadius.circular(Radii.pill)),
                          child: Text('Tap to reveal', style: Txt.small(p.bg)),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: Space.md),
          if (_revealed)
            OutlinedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: words.join(' ')));
                toast(context, 'Copied. Clear your clipboard after storing it.');
              },
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copy phrase'),
            ),
          const SizedBox(height: Space.md),
          FilledButton(
            onPressed: () async {
              final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Where to save chats and files');
              if (dir == null || !context.mounted) return;
              try {
                await ref.read(sessionProvider.notifier).exportVault(dir);
                if (context.mounted) toast(context, 'Saved. Restore it with your phrase.');
              } catch (e) {
                if (context.mounted) toast(context, '$e');
              }
            },
            child: const Text('Save chats and files'),
          ),
        ],
      ),
    );
  }
}
