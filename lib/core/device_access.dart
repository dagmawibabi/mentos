import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';

import '../widgets/ui.dart';

/// Android runtime prompts for photos, video, audio, and older storage.
/// Other platforms return true; their pickers ask on their own.
Future<bool> allowMedia({
  bool images = false,
  bool videos = false,
  bool audio = false,
}) async {
  if (kIsWeb || !Platform.isAndroid) return true;
  final wanted = <Permission>[
    if (images) Permission.photos,
    if (videos) Permission.videos,
    if (audio) Permission.audio,
  ];
  if (wanted.isEmpty) return true;
  try {
    final modern = await wanted.request();
    if (wanted.any((p) => _open(modern[p]))) return true;
    // Android 12 and below have no photos, video, or audio runtime
    // permission. Those come back denied without a dialog, and storage
    // is the prompt the system actually shows.
    return _open(await Permission.storage.request());
  } catch (_) {
    return false;
  }
}

/// Asks before writing into shared storage. On Android 13+ this permission
/// is not runtime, so a denial here must not block the save.
Future<void> askToSaveFiles() async {
  if (kIsWeb || !Platform.isAndroid) return;
  try {
    await Permission.storage.request();
  } catch (_) {}
}

bool _open(PermissionStatus? status) =>
    status != null && (status.isGranted || status.isLimited);

/// Shared by the pickers so a refusal explains itself when a screen is around.
Future<bool> allowMediaOrTell(
  BuildContext? context, {
  bool images = false,
  bool videos = false,
  bool audio = false,
  required String message,
}) async {
  if (await allowMedia(images: images, videos: videos, audio: audio)) return true;
  if (context != null && context.mounted) toast(context, message);
  return false;
}
