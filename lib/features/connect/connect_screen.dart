import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';

class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key, this.scan = false});
  final bool scan;

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  late bool _scan = widget.scan;
  String? _ticket;
  final _paste = TextEditingController();
  final _scanner = MobileScannerController();
  bool _handling = false;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    ref.read(engineProvider).contactTicket().then((t) {
      if (mounted) setState(() => _ticket = t);
    }).catchError((_) {
      if (mounted) setState(() => _ticket = '');
    });
  }

  @override
  void dispose() {
    _scanner.dispose();
    _paste.dispose();
    super.dispose();
  }

  Future<void> _resumeScan() async {
    _handling = false;
    if (!mounted || !_scan) return;
    try {
      await _scanner.start();
    } catch (_) {}
  }

  Future<void> _open(String raw) async {
    if (_handling || !mounted || raw.trim().isEmpty) return;
    _handling = true;
    final engine = ref.read(engineProvider);
    try {
      await _scanner.stop();
    } catch (_) {}
    try {
      final r = await engine.openTicket(raw);
      if (!mounted) return;
      if (r == null) {
        await _resumeScan();
        if (mounted) toast(context, 'That code isn\'t a Mentos contact or invite.');
        return;
      }
      HapticFeedback.mediumImpact();
      // Unmount the camera preview before the route transition so its
      // texture isn't drawn while the controller is being torn down.
      setState(() => _leaving = true);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      if (r.$1 == 'peer') {
        context.pushReplacement('/u/${r.$2}');
      } else {
        context.pushReplacement('/s/${r.$2}');
      }
    } catch (e) {
      await _resumeScan();
      if (mounted) toast(context, 'Couldn\'t connect: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final me = ref.watch(myProfileProvider).value ?? e.myProfile;
    return Scaffold(
      appBar: AppBar(title: const Text('Connect')),
      body: ListView(
        padding: const EdgeInsets.all(Space.gutter),
        children: [
          Segmented<bool>(
            value: _scan,
            options: const {false: 'My code', true: 'Scan'},
            onChanged: (v) => setState(() => _scan = v),
          ),
          const SizedBox(height: Space.xl),
          if (!_scan) ...[
            Center(
              child: Container(
                padding: const EdgeInsets.all(Space.lg),
                decoration: BoxDecoration(
                  color: p.surface,
                  borderRadius: BorderRadius.circular(Radii.lg + 6),
                  border: Border.all(color: p.line),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(Radii.md)),
                      child: _ticket == null
                          ? const SizedBox(width: 220, height: 220, child: Loading())
                          : QrImageView(
                              data: _ticket!,
                              size: 220,
                              backgroundColor: Colors.white,
                              eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF0D1110)),
                              dataModuleStyle: const QrDataModuleStyle(
                                  dataModuleShape: QrDataModuleShape.square, color: Color(0xFF0D1110)),
                            ),
                    ),
                    const SizedBox(height: Space.lg),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Avatar(id: e.me.id, size: 28, presence: false),
                        const SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(me.displayName, style: Txt.bodyStrong(p.ink)),
                            Text(shortId(e.me.id), style: Txt.mono(p.muted, size: 11)),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: Space.lg),
            Text(
              'This code holds your public key and how to reach your phone. Scanning it lets someone '
              'message you directly — there\'s no directory to search.',
              textAlign: TextAlign.center,
              style: Txt.small(p.muted),
            ),
            const SizedBox(height: Space.lg),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _ticket == null
                        ? null
                        : () {
                            Clipboard.setData(ClipboardData(text: _ticket!));
                            toast(context, 'Contact link copied');
                          },
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: const Text('Copy link'),
                  ),
                ),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _ticket == null ? null : () => SharePlus.instance.share(ShareParams(text: _ticket!)),
                    icon: const Icon(Icons.ios_share_rounded, size: 18),
                    label: const Text('Share'),
                  ),
                ),
              ],
            ),
          ] else ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.lg + 6),
              child: AspectRatio(
                aspectRatio: 1,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_leaving)
                      const ColoredBox(color: Colors.black)
                    else
                      MobileScanner(
                        controller: _scanner,
                        onDetect: (capture) {
                          if (_handling) return;
                          final v = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
                          if (v != null) _open(v);
                        },
                        errorBuilder: (context, error) => Center(
                          child: Padding(
                            padding: const EdgeInsets.all(Space.lg),
                            child: Text(
                              'Camera unavailable. Allow camera access in system settings, or paste a link below.',
                              textAlign: TextAlign.center,
                              style: Txt.small(Colors.white),
                            ),
                          ),
                        ),
                      ),
                    IgnorePointer(
                      child: Center(
                        child: Container(
                          width: 220,
                          height: 220,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(Radii.lg),
                            border: Border.all(color: p.accent, width: 2),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: Space.lg),
            Text('Point at a contact code or a space invite.', textAlign: TextAlign.center, style: Txt.small(p.muted)),
          ],
          SectionLabel('Or paste a link or key', padding: const EdgeInsets.only(top: Space.xl, bottom: Space.sm)),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _paste,
                  style: Txt.mono(p.ink, size: 13),
                  decoration: const InputDecoration(hintText: 'mentos://… or 64-character key'),
                  onSubmitted: _open,
                ),
              ),
              const SizedBox(width: Space.sm),
              IconBtn(Icons.content_paste_rounded, onTap: () async {
                final d = await Clipboard.getData('text/plain');
                if (d?.text != null) _paste.text = d!.text!;
              }),
              FilledButton(onPressed: () => _open(_paste.text), child: const Text('Open')),
            ],
          ),
        ],
      ),
    );
  }
}
