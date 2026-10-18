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
import '../../widgets/profile_header.dart';
import '../../widgets/ui.dart';

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
  XFile? _cover;
  bool _removePhoto = false;
  bool _removeCover = false;
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

  Future<XFile?> _pick({required double maxWidth}) async {
    if (!await allowMediaOrTell(context, images: true, message: 'Photo access is needed to choose a picture.')) return null;
    return ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: maxWidth, imageQuality: 85);
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final e = ref.read(engineProvider);
    try {
      var avatar = _removePhoto ? null : _me.avatar;
      if (_photo != null) {
        avatar = await e.media.import(File(_photo!.path), name: 'avatar.jpg', scope: Scope.profile(e.me.id));
      }
      var cover = _removeCover ? null : _me.cover;
      if (_cover != null) {
        cover = await e.media.import(File(_cover!.path), name: 'cover.jpg', scope: Scope.profile(e.me.id));
      }
      await e.updateProfile(name: _name.text, bio: _bio.text, avatar: avatar, cover: cover);
      if (mounted) {
        toast(context, 'Profile saved');
        context.pop();
      }
    } catch (err) {
      if (mounted) {
        setState(() => _busy = false);
        toast(context, 'Couldn\'t save: $err');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final hasCover = _cover != null || (!_removeCover && _me.cover != null);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit profile'),
        actions: [
          FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Saving…' : 'Save')),
          const SizedBox(width: Space.gutter),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          // Header image with the avatar overlapping it.
          SizedBox(
            height: 196,
            child: Stack(
              children: [
                Positioned(
                  left: Space.gutter,
                  right: Space.gutter,
                  top: Space.sm,
                  height: 140,
                  child: GestureDetector(
                    onTap: () async {
                      final x = await _pick(maxWidth: 1600);
                      if (mounted && x != null) {
                        setState(() {
                          _cover = x;
                          _removeCover = false;
                        });
                      }
                    },
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (_cover != null)
                            Image.file(File(_cover!.path), fit: BoxFit.cover)
                          else if (hasCover)
                            ProfileCover(id: e.me.id, cover: _me.cover)
                          else
                            const ProfileCover(id: '', cover: null),
                          Container(color: Colors.black.withValues(alpha: .18)),
                          Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                              decoration: BoxDecoration(color: Colors.black.withValues(alpha: .45), borderRadius: BorderRadius.circular(Radii.pill)),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.add_photo_alternate_outlined, color: Colors.white, size: 16),
                                  const SizedBox(width: 6),
                                  Text(hasCover ? 'Change header' : 'Add a header image', style: Txt.small(Colors.white).copyWith(fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: Space.gutter + Space.lg,
                  bottom: 0,
                  child: GestureDetector(
                    onTap: () async {
                      final x = await _pick(maxWidth: 512);
                      if (mounted && x != null) {
                        setState(() {
                          _photo = x;
                          _removePhoto = false;
                        });
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(color: p.bg, borderRadius: BorderRadius.circular(34)),
                      child: Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(30),
                            child: _photo != null
                                ? Image.file(File(_photo!.path), width: 92, height: 92, fit: BoxFit.cover)
                                : _removePhoto
                                ? Sigil(id: e.me.id, size: 92)
                                : Avatar(id: e.me.id, size: 92, presence: false),
                          ),
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 30,
                              height: 30,
                              decoration: BoxDecoration(color: p.ink, shape: BoxShape.circle, border: Border.all(color: p.bg, width: 2)),
                              child: Icon(Icons.photo_camera_outlined, size: 15, color: p.bg),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
            child: Wrap(
              spacing: Space.sm,
              children: [
                if (_me.avatar != null || _photo != null)
                  TextButton(
                    onPressed: () => setState(() {
                      _photo = null;
                      _removePhoto = true;
                    }),
                    child: Text('Use my sigil', style: Txt.small(p.muted)),
                  ),
                if (hasCover)
                  TextButton(
                    onPressed: () => setState(() {
                      _cover = null;
                      _removeCover = true;
                    }),
                    child: Text('Remove header', style: Txt.small(p.muted)),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: Space.md),
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
                  'Whether they may remember it while you\'re offline is set in Settings › Privacy.',
                  style: Txt.mono(p.faint, size: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
