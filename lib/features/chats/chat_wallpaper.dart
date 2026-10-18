import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/device_access.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';

/// Preset definition for chat wallpapers.
class WallpaperPreset {
  const WallpaperPreset({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.icon,
    this.solidColor,
    this.gradientColors,
    this.isPattern = false,
  });

  final String id;
  final String name;
  final String subtitle;
  final IconData icon;
  final Color? solidColor;
  final List<Color>? gradientColors;
  final bool isPattern;
}

const kWallpaperPresets = <WallpaperPreset>[
  WallpaperPreset(
    id: 'default',
    name: 'Default',
    subtitle: 'Clean theme canvas',
    icon: Icons.auto_awesome_mosaic_outlined,
  ),
  WallpaperPreset(
    id: 'mesh',
    name: 'P2P Mesh',
    subtitle: 'Interconnected nodes',
    icon: Icons.hub_outlined,
    isPattern: true,
  ),
  WallpaperPreset(
    id: 'blueprint',
    name: 'Cypher Grid',
    subtitle: 'Technical matrix dots',
    icon: Icons.grid_4x4_rounded,
    isPattern: true,
  ),
  WallpaperPreset(
    id: 'aurora',
    name: 'Aurora',
    subtitle: 'Cosmic ambient glow',
    icon: Icons.blur_on_rounded,
    gradientColors: [Color(0xFF0C251C), Color(0xFF131A2B), Color(0xFF1E1029)],
  ),
  WallpaperPreset(
    id: 'doodle',
    name: 'Cypher Doodles',
    subtitle: 'Locks, nodes & waves',
    icon: Icons.gesture_rounded,
    isPattern: true,
  ),
  WallpaperPreset(
    id: 'midnight',
    name: 'Midnight',
    subtitle: 'Deep obsidian vignette',
    icon: Icons.dark_mode_outlined,
    gradientColors: [Color(0xFF090B0E), Color(0xFF11141A)],
  ),
  WallpaperPreset(
    id: 'sunset',
    name: 'Amber Dusk',
    subtitle: 'Warm evening glow',
    icon: Icons.wb_twilight_rounded,
    gradientColors: [Color(0xFF1F120E), Color(0xFF2E1911), Color(0xFF140D0C)],
  ),
  WallpaperPreset(
    id: 'solid_navy',
    name: 'Deep Navy',
    subtitle: 'Oceanic dark slate',
    icon: Icons.water_drop_outlined,
    solidColor: Color(0xFF0D1B2A),
  ),
  WallpaperPreset(
    id: 'solid_forest',
    name: 'Emerald Pine',
    subtitle: 'Botanical deep green',
    icon: Icons.park_outlined,
    solidColor: Color(0xFF091F18),
  ),
  WallpaperPreset(
    id: 'solid_plum',
    name: 'Dark Plum',
    subtitle: 'Mystic dark amethyst',
    icon: Icons.lens_blur_rounded,
    solidColor: Color(0xFF1C0D24),
  ),
];

String wallpaperName(String? id) {
  if (id == null || id.isEmpty) return 'Default';
  if (id.startsWith('custom_image:')) return 'Custom photo';
  if (id.startsWith('custom_color:')) return 'Custom color';
  for (final p in kWallpaperPresets) {
    if (p.id == id) return p.name;
  }
  return 'Default';
}

/// Renders the chat background layer for a given [scope] or explicit [wallpaperId].
class ChatWallpaperBackground extends ConsumerWidget {
  const ChatWallpaperBackground({
    super.key,
    this.scope,
    this.wallpaperId,
    this.child,
  });

  final String? scope;
  final String? wallpaperId;
  final Widget? child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    String? scopedId;
    if (scope != null) {
      try {
        scopedId = ref.watch(chatWallpaperProvider(scope!)).value;
      } catch (_) {}
    }
    String globalId;
    try {
      globalId = ref.watch(settingsProvider).chatWallpaper ?? 'default';
    } catch (_) {
      globalId = 'default';
    }
    final rawId = wallpaperId ?? scopedId ?? globalId;
    final activeId = (rawId.isEmpty) ? 'default' : rawId;

    final p = context.pal;
    final isDark = p.isDark;

    Widget layer;
    if (activeId.startsWith('custom_image:')) {
      final rawPath = activeId.substring('custom_image:'.length).trim().replaceAll('"', '');
      final file = File(rawPath);
      if (file.existsSync()) {
        layer = Stack(
          fit: StackFit.expand,
          children: [
            Image.file(
              file,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(color: p.bg),
            ),
            Container(
              color: (isDark ? Colors.black : Colors.white).withValues(
                alpha: isDark ? 0.35 : 0.20,
              ),
            ),
          ],
        );
      } else {
        layer = Container(color: p.bg);
      }
    } else if (activeId == 'mesh') {
      layer = CustomPaint(
        painter: _MeshWallpaperPainter(
          accent: p.accent,
          lineColor: p.ink.withValues(alpha: isDark ? 0.08 : 0.06),
          nodeColor: p.accent.withValues(alpha: isDark ? 0.30 : 0.22),
          bg: isDark ? const Color(0xFF0C0F12) : const Color(0xFFF3F5F7),
        ),
      );
    } else if (activeId == 'blueprint') {
      layer = CustomPaint(
        painter: _BlueprintPainter(
          dotColor: p.ink.withValues(alpha: isDark ? 0.09 : 0.08),
          bg: isDark ? const Color(0xFF0B0E14) : const Color(0xFFF0F4F8),
        ),
      );
    } else if (activeId == 'aurora') {
      layer = Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? const [
                    Color(0xFF071B16),
                    Color(0xFF0D1526),
                    Color(0xFF1B0E27),
                  ]
                : const [
                    Color(0xFFE8F5F1),
                    Color(0xFFEAEFFB),
                    Color(0xFFF5EBF9),
                  ],
          ),
        ),
      );
    } else if (activeId == 'doodle') {
      layer = CustomPaint(
        painter: _DoodleWallpaperPainter(
          iconColor: p.ink.withValues(alpha: isDark ? 0.055 : 0.045),
          bg: isDark ? const Color(0xFF0D0F12) : const Color(0xFFF4F6F8),
        ),
      );
    } else if (activeId == 'midnight') {
      layer = Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.1,
            colors: [Color(0xFF13171F), Color(0xFF08090C)],
          ),
        ),
      );
    } else if (activeId == 'sunset') {
      layer = Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? const [
                    Color(0xFF2A150F),
                    Color(0xFF1A1110),
                    Color(0xFF0E0C0C),
                  ]
                : const [
                    Color(0xFFFDEEE8),
                    Color(0xFFFBF4F2),
                    Color(0xFFF2EDED),
                  ],
          ),
        ),
      );
    } else if (activeId.startsWith('solid_') || activeId.startsWith('custom_color:')) {
      Color c = const Color(0xFF0D1B2A);
      if (activeId == 'solid_forest') c = const Color(0xFF0A1F18);
      if (activeId == 'solid_plum') c = const Color(0xFF1C0D24);
      if (activeId.startsWith('custom_color:')) {
        final hex = activeId.substring('custom_color:'.length);
        final val = int.tryParse(hex, radix: 16);
        if (val != null) c = Color(val);
      }
      layer = Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              c,
              Color.lerp(c, Colors.black, isDark ? 0.35 : 0.1)!,
            ],
          ),
        ),
      );
    } else {
      // Default plain
      layer = Container(color: p.bg);
    }

    if (child == null) return layer;
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(child: layer),
        child!,
      ],
    );
  }
}

/// Custom painter for the P2P Mesh wallpaper.
class _MeshWallpaperPainter extends CustomPainter {
  const _MeshWallpaperPainter({
    required this.accent,
    required this.lineColor,
    required this.nodeColor,
    required this.bg,
  });

  final Color accent;
  final Color lineColor;
  final Color nodeColor;
  final Color bg;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);

    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final nodePaint = Paint()
      ..color = nodeColor
      ..style = PaintingStyle.fill;

    // Deterministic pseudo-random mesh grid
    final cols = (size.width / 75).ceil() + 1;
    final rows = (size.height / 75).ceil() + 1;
    final nodes = <Offset>[];

    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final seed = (r * 31 + c * 17) % 100;
        final dx = (seed * 0.35) - 17.0;
        final dy = ((seed * 1.3) % 30) - 15.0;
        nodes.add(Offset(c * 75.0 + dx, r * 75.0 + dy));
      }
    }

    for (var i = 0; i < nodes.length; i++) {
      final a = nodes[i];
      if (i % cols < cols - 1) {
        canvas.drawLine(a, nodes[i + 1], linePaint);
      }
      if (i + cols < nodes.length) {
        canvas.drawLine(a, nodes[i + cols], linePaint);
      }
      if ((i % 3 == 0) && (i + cols + 1 < nodes.length) && (i % cols < cols - 1)) {
        canvas.drawLine(a, nodes[i + cols + 1], linePaint);
      }
      final radius = (i % 4 == 0) ? 3.0 : 2.0;
      canvas.drawCircle(a, radius, nodePaint);
    }
  }

  @override
  bool shouldRepaint(_MeshWallpaperPainter old) =>
      old.accent != accent || old.bg != bg;
}

/// Custom painter for technical grid wallpaper.
class _BlueprintPainter extends CustomPainter {
  const _BlueprintPainter({required this.dotColor, required this.bg});
  final Color dotColor;
  final Color bg;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);
    final dotPaint = Paint()
      ..color = dotColor
      ..style = PaintingStyle.fill;

    const step = 28.0;
    for (var x = 14.0; x < size.width; x += step) {
      for (var y = 14.0; y < size.height; y += step) {
        final isMajor = ((x.toInt() ~/ step) % 4 == 0) &&
            ((y.toInt() ~/ step) % 4 == 0);
        canvas.drawCircle(Offset(x, y), isMajor ? 1.6 : 0.9, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(_BlueprintPainter old) =>
      old.dotColor != dotColor || old.bg != bg;
}

/// Custom painter for repeating cryptographic/P2P doodle wallpaper.
class _DoodleWallpaperPainter extends CustomPainter {
  const _DoodleWallpaperPainter({required this.iconColor, required this.bg});
  final Color iconColor;
  final Color bg;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);

    final p = Paint()
      ..color = iconColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;

    const stepX = 90.0;
    const stepY = 90.0;
    var index = 0;

    for (var y = 45.0; y < size.height; y += stepY) {
      final shift = (index % 2 == 1) ? 45.0 : 0.0;
      for (var x = 45.0 + shift; x < size.width; x += stepX) {
        final type = (index * 7 + (x / stepX).floor()) % 4;
        _drawIcon(canvas, Offset(x, y), type, p);
        index++;
      }
    }
  }

  void _drawIcon(Canvas canvas, Offset o, int type, Paint p) {
    switch (type) {
      case 0:
        // Shield
        final path = Path()
          ..moveTo(o.dx - 8, o.dy - 8)
          ..lineTo(o.dx + 8, o.dy - 8)
          ..lineTo(o.dx + 8, o.dy + 2)
          ..quadraticBezierTo(o.dx, o.dy + 12, o.dx, o.dy + 12)
          ..quadraticBezierTo(o.dx - 8, o.dy + 2, o.dx - 8, o.dy - 8)
          ..close();
        canvas.drawPath(path, p);
        break;
      case 1:
        // Padlock
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset(o.dx, o.dy + 3), width: 14, height: 11),
            const Radius.circular(3),
          ),
          p,
        );
        canvas.drawArc(
          Rect.fromCenter(center: Offset(o.dx, o.dy - 2), width: 8, height: 8),
          math.pi,
          math.pi,
          false,
          p,
        );
        break;
      case 2:
        // Node / Hub
        canvas.drawCircle(o, 3.5, p);
        canvas.drawLine(Offset(o.dx - 8, o.dy), Offset(o.dx - 4, o.dy), p);
        canvas.drawLine(Offset(o.dx + 4, o.dy), Offset(o.dx + 8, o.dy), p);
        canvas.drawLine(Offset(o.dx, o.dy - 8), Offset(o.dx, o.dy - 4), p);
        canvas.drawLine(Offset(o.dx, o.dy + 4), Offset(o.dx, o.dy + 8), p);
        break;
      case 3:
      default:
        // Chat bubble
        final path = Path()
          ..addRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(center: o, width: 16, height: 12),
              const Radius.circular(4),
            ),
          )
          ..moveTo(o.dx - 3, o.dy + 6)
          ..lineTo(o.dx - 6, o.dy + 9)
          ..lineTo(o.dx - 1, o.dy + 6);
        canvas.drawPath(path, p);
        break;
    }
  }

  @override
  bool shouldRepaint(_DoodleWallpaperPainter old) =>
      old.iconColor != iconColor || old.bg != bg;
}

/// Displays the wallpaper bottom sheet picker.
Future<void> showWallpaperPicker(BuildContext context, {String? scope}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _WallpaperPickerSheet(scope: scope),
  );
}

class _WallpaperPickerSheet extends ConsumerStatefulWidget {
  const _WallpaperPickerSheet({this.scope});
  final String? scope;

  @override
  ConsumerState<_WallpaperPickerSheet> createState() =>
      _WallpaperPickerSheetState();
}

class _WallpaperPickerSheetState extends ConsumerState<_WallpaperPickerSheet> {
  late String _selected;
  String? _customPath;

  @override
  void initState() {
    super.initState();
    final e = ref.read(maybeEngineProvider);
    String global;
    try {
      global = ref.read(settingsProvider).chatWallpaper ?? 'default';
    } catch (_) {
      global = 'default';
    }
    if (global.isEmpty) global = 'default';
    if (widget.scope != null && e != null) {
      final cur = e.db.getKv('wallpaper:${widget.scope}');
      _selected = (cur != null && cur.isNotEmpty) ? cur : global;
    } else {
      _selected = global;
    }
    if (_selected.startsWith('custom_image:')) {
      final path = _selected.substring('custom_image:'.length).trim().replaceAll('"', '');
      if (File(path).existsSync()) {
        _customPath = path;
      }
    }
  }

  Future<void> _pickPhoto() async {
    try {
      String? rawPath;

      // 1. On desktop (Windows, Linux, macOS), use native FilePicker
      if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
        try {
          final res = await FilePicker.pickFiles(
            type: FileType.custom,
            allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif'],
          );
          if (res.isNotEmpty) {
            rawPath = res.first.path;
          }
        } catch (_) {}
      }

      // 2. On mobile, check permissions and use ImagePicker
      if (rawPath == null && !kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        try {
          if (!mounted) return;
          await allowMediaOrTell(
            context,
            images: true,
            message: 'Photo access is needed to select a wallpaper.',
          );
          final picker = ImagePicker();
          final img = await picker.pickImage(
            source: ImageSource.gallery,
            maxWidth: 2560,
            imageQuality: 92,
          );
          rawPath = img?.path;
        } catch (_) {}
      }

      // 3. Fallback to FilePicker
      if (rawPath == null) {
        try {
          final res = await FilePicker.pickFiles(
            type: FileType.image,
          );
          if (res.isNotEmpty) {
            rawPath = res.first.path;
          }
        } catch (_) {}
      }

      if (rawPath == null || rawPath.isEmpty) return;

      final srcFile = File(rawPath);
      if (!srcFile.existsSync()) return;

      // Persistently copy into app's documents directory
      final appDir = await getApplicationDocumentsDirectory();
      final wpDir = Directory(p.join(appDir.path, 'wallpapers'));
      if (!wpDir.existsSync()) {
        await wpDir.create(recursive: true);
      }

      final ext = p.extension(rawPath).isNotEmpty ? p.extension(rawPath) : '.jpg';
      final fileName = 'wallpaper_${DateTime.now().millisecondsSinceEpoch}$ext';
      final destFile = File(p.join(wpDir.path, fileName));
      await srcFile.copy(destFile.path);

      final wallpaperKey = 'custom_image:${destFile.path}';

      if (!mounted) return;
      setState(() {
        _customPath = destFile.path;
        _selected = wallpaperKey;
      });

      HapticFeedback.selectionClick();

      // Automatically apply so the user immediately gets their chosen photo
      if (widget.scope != null) {
        _apply(forThisChatOnly: true);
      } else {
        _apply(forThisChatOnly: false);
      }
    } catch (e) {
      if (mounted) toast(context, 'Could not select photo: $e');
    }
  }

  void _apply({required bool forThisChatOnly}) {
    HapticFeedback.mediumImpact();
    final e = ref.read(maybeEngineProvider);
    if (e == null) return;

    if (forThisChatOnly && widget.scope != null) {
      e.setChatWallpaper(widget.scope!, _selected);
      toast(context, 'Wallpaper applied to this chat');
    } else {
      ref.read(settingsProvider.notifier).update(
            (s) => s.copyWith(chatWallpaper: _selected),
          );
      if (widget.scope != null) {
        // Clear chat-specific override so it uses the new default
        e.setChatWallpaper(widget.scope!, '');
      }
      toast(context, 'Applied as default wallpaper for all chats');
    }
    Navigator.pop(context);
  }

  void _resetDefault() {
    HapticFeedback.selectionClick();
    final e = ref.read(maybeEngineProvider);
    if (e != null && widget.scope != null) {
      e.setChatWallpaper(widget.scope!, '');
      toast(context, 'Reset to default wallpaper');
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final isSpecificChat = widget.scope != null;

    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(Space.gutter, 12, Space.gutter, Space.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Grab handle
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: p.faint.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: Space.md),

              // Title row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Chat Wallpaper', style: Txt.heading(p.ink)),
                      const SizedBox(height: 2),
                      Text(
                        isSpecificChat
                            ? 'Personalize this conversation'
                            : 'Set default for all chats',
                        style: Txt.small(p.muted),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: Space.md),

              // Interactive live preview box
              Container(
                height: 140,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                ),
                foregroundDecoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: p.line),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ChatWallpaperBackground(wallpaperId: _selected),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          // Fake received bubble
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Avatar(id: 'preview_peer', size: 24, presence: false),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                                  decoration: BoxDecoration(
                                    color: p.surface,
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(color: p.line),
                                  ),
                                  child: Text(
                                    'Loving this new wallpaper! ✨',
                                    style: Txt.small(p.ink),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Fake sent bubble
                          Align(
                            alignment: Alignment.centerRight,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                              decoration: BoxDecoration(
                                color: p.bubbleMine,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'Encrypted and peer-to-peer 🔐',
                                    style: Txt.small(p.bubbleMineInk),
                                  ),
                                  const SizedBox(width: 4),
                                  Icon(Icons.done_all_rounded, size: 13, color: p.accent),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Space.lg),

              // Wallpaper selector horizontal list
              SizedBox(
                height: 96,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    // Choose Photo Card
                    _CustomPhotoCard(
                      selected: _selected.startsWith('custom_image:'),
                      customPath: _customPath,
                      onTap: _pickPhoto,
                    ),
                    const SizedBox(width: 10),

                    // Preset Cards
                    for (final preset in kWallpaperPresets) ...[
                      _PresetThumbnailCard(
                        preset: preset,
                        isSelected: _selected == preset.id,
                        onTap: () {
                          HapticFeedback.selectionClick();
                          setState(() => _selected = preset.id);
                          if (!isSpecificChat) {
                            ref.read(settingsProvider.notifier).update(
                                  (s) => s.copyWith(chatWallpaper: preset.id),
                                );
                            toast(context, '${preset.name} set as default wallpaper');
                          }
                        },
                      ),
                      const SizedBox(width: 10),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: Space.lg),

              // Action buttons
              if (isSpecificChat) ...[
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: () => _apply(forThisChatOnly: true),
                        child: const Text('For this chat'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => _apply(forThisChatOnly: false),
                        child: const Text('For all chats'),
                      ),
                    ),
                  ],
                ),
                TextButton(
                  onPressed: _resetDefault,
                  child: Text('Reset this chat to default', style: Txt.small(p.muted)),
                ),
              ] else ...[
                FilledButton(
                  onPressed: () => _apply(forThisChatOnly: false),
                  child: const Text('Set as default wallpaper'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PresetThumbnailCard extends StatelessWidget {
  const _PresetThumbnailCard({
    required this.preset,
    required this.isSelected,
    required this.onTap,
  });

  final WallpaperPreset preset;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;

    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 62,
            height: 62,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
            ),
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isSelected ? p.accent : p.line,
                width: isSelected ? 2.5 : 1.0,
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ChatWallpaperBackground(wallpaperId: preset.id),
                if (isSelected)
                  Container(
                    alignment: Alignment.center,
                    color: Colors.black26,
                    child: Icon(Icons.check_circle_rounded, color: p.accent, size: 22),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 5),
          Text(
            preset.name,
            style: TextStyle(
              fontSize: 11,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
              color: isSelected ? p.accent : p.ink,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _CustomPhotoCard extends StatelessWidget {
  const _CustomPhotoCard({
    required this.selected,
    required this.customPath,
    required this.onTap,
  });

  final bool selected;
  final String? customPath;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;

    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 62,
            height: 62,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: p.raised,
              borderRadius: BorderRadius.circular(14),
            ),
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected ? p.accent : p.line,
                width: selected ? 2.5 : 1.0,
              ),
            ),
            child: customPath != null && File(customPath!).existsSync()
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.file(File(customPath!), fit: BoxFit.cover),
                      if (selected)
                        Container(
                          alignment: Alignment.center,
                          color: Colors.black26,
                          child: Icon(Icons.check_circle_rounded, color: p.accent, size: 22),
                        ),
                    ],
                  )
                : Icon(Icons.add_photo_alternate_outlined, color: p.muted, size: 24),
          ),
          const SizedBox(height: 5),
          Text(
            'Photo',
            style: TextStyle(
              fontSize: 11,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? p.accent : p.ink,
            ),
          ),
        ],
      ),
    );
  }
}
