import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/device_access.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';

class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  late final Profile _me;
  late final TextEditingController _name;
  late final TextEditingController _bio;
  XFile? _photo;
  bool _removePhoto = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _me = ref.read(engineProvider).myProfile;
    _name = TextEditingController(text: _me.name);
    _bio = TextEditingController(text: _me.bio);
  }

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final e = ref.read(engineProvider);
    MediaRef? avatar = _removePhoto ? null : _me.avatar;
    if (_photo != null) {
      avatar = await e.media.import(File(_photo!.path), name: 'avatar.jpg', scope: Scope.profile(e.me.id));
    }
    await e.updateProfile(name: _name.text, bio: _bio.text, avatar: avatar);
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit profile'),
        actions: [
          TextButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Saving…' : 'Save')),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(Space.gutter),
        children: [
          Center(
            child: GestureDetector(
              onTap: () async {
                if (!await allowMediaOrTell(context, images: true, message: 'Photo access is needed to choose a picture.')) {
                  return;
                }
                final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 512, imageQuality: 85);
                if (!mounted || x == null) return;
                setState(() => _photo = x);
              },
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(30),
                    child: _photo != null
                        ? Image.file(File(_photo!.path), width: 100, height: 100, fit: BoxFit.cover)
                        : _removePhoto
                            ? Sigil(id: e.me.id, size: 100)
                            : Avatar(id: e.me.id, size: 100, presence: false),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(color: p.ink, shape: BoxShape.circle, border: Border.all(color: p.bg, width: 2)),
                      child: Icon(Icons.photo_camera_outlined, size: 16, color: p.bg),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_me.avatar != null || _photo != null)
            Center(
              child: TextButton(
                onPressed: () => setState(() {
                  _photo = null;
                  _removePhoto = true;
                }),
                child: Text('Use my sigil instead', style: Txt.small(p.muted)),
              ),
            ),
          const SizedBox(height: Space.xl),
          Text('NAME', style: Txt.label(p.muted)),
          const SizedBox(height: 6),
          TextField(
            controller: _name,
            maxLength: 40,
            decoration: InputDecoration(hintText: alias(e.me.id), counterText: ''),
          ),
          const SizedBox(height: Space.lg),
          Text('BIO', style: Txt.label(p.muted)),
          const SizedBox(height: 6),
          TextField(controller: _bio, maxLines: 4, maxLength: 200, decoration: const InputDecoration(hintText: 'A line or two about you')),
          const SizedBox(height: Space.lg),
          Text(
            'Your profile is signed with your key and sent to people you talk to. '
            'Whether they may remember it while you\'re offline is set in Settings → Privacy.',
            style: Txt.mono(p.faint, size: 11),
          ),
        ],
      ),
    );
  }
}
