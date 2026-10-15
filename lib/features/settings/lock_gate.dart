import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/pin.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../state/providers.dart';

/// Covers the app when a PIN is set, and again after it has been in the
/// background longer than the chosen timeout.
class LockGate extends ConsumerStatefulWidget {
  const LockGate({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<LockGate> createState() => _LockGateState();
}

class _LockGateState extends ConsumerState<LockGate> with WidgetsBindingObserver {
  final _pin = TextEditingController();
  bool _locked = false;
  DateTime? _paused;
  bool _checking = false;
  String? _error;

  static const _throttleKey = 'pinThrottle';

  PinThrottle _throttle() => PinThrottle.decode(ref.read(maybeEngineProvider)?.db.getKv(_throttleKey));

  void _saveThrottle(PinThrottle t) => ref.read(maybeEngineProvider)?.db.setKv(_throttleKey, t.encode());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final s = ref.read(settingsProvider);
    _locked = s.lockHash.isNotEmpty;
    if (_locked && s.lockBio) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _bio());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pin.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final s = ref.read(settingsProvider);
    if (s.lockHash.isEmpty) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _paused = DateTime.now();
    }
    if (state == AppLifecycleState.resumed && _paused != null) {
      final away = DateTime.now().difference(_paused!).inSeconds;
      if (away >= s.lockAfter) {
        setState(() => _locked = true);
        if (s.lockBio) _bio();
      }
    }
  }

  Future<void> _bio() async {
    if (!mounted || !_locked) return;
    try {
      final auth = LocalAuthentication();
      if (!await auth.canCheckBiometrics && !await auth.isDeviceSupported()) return;
      final ok = await auth.authenticate(
        localizedReason: 'Unlock Mentos',
        biometricOnly: true,
      );
      if (ok && mounted) {
        setState(() {
          _locked = false;
          _error = null;
        });
        _pin.clear();
      }
    } catch (e) {
      // Shown instead of swallowed, so a misconfigured device is visible.
      if (mounted) setState(() => _error = 'Biometrics unavailable: ${e.toString().split('\n').first}');
    }
  }

  Future<void> _unlock() async {
    if (_checking) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final t = _throttle();
    final wait = t.waitAt(now);
    if (wait > Duration.zero) {
      setState(() => _error = 'Too many tries. Wait ${_human(wait)}.');
      return;
    }
    final s = ref.read(settingsProvider);
    setState(() => _checking = true);
    final ok = await PinHash.verify(_pin.text, s.lockHash);
    if (!mounted) return;
    setState(() => _checking = false);
    if (!ok) {
      final next = t.failed(now);
      _saveThrottle(next);
      final left = PinThrottle.free - next.fails;
      setState(() => _error = left > 0
          ? 'Wrong PIN. $left more ${left == 1 ? 'try' : 'tries'} before a wait.'
          : 'Wrong PIN. Wait ${_human(next.waitAt(now))}.');
      return;
    }
    _saveThrottle(const PinThrottle());
    if (PinHash.isLegacy(s.lockHash)) {
      final upgraded = await PinHash.create(_pin.text);
      ref.read(settingsProvider.notifier).update((x) => x.copyWith(lockHash: upgraded));
    }
    if (!mounted) return;
    setState(() {
      _locked = false;
      _error = null;
    });
    _pin.clear();
  }

  static String _human(Duration d) =>
      d.inMinutes >= 1 ? '${d.inMinutes}m ${d.inSeconds % 60}s' : '${d.inSeconds + 1}s';

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    if (s.lockHash.isEmpty || !_locked) return widget.child;
    final p = context.pal;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Space.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Mentos is locked', style: Txt.title(p.ink)),
              const SizedBox(height: 8),
              Text('Enter your PIN to open chats and files.', style: Txt.body(p.muted)),
              const SizedBox(height: 20),
              TextField(
                controller: _pin,
                autofocus: true,
                obscureText: true,
                keyboardType: TextInputType.number,
                onSubmitted: (_) => _unlock(),
                decoration: InputDecoration(hintText: 'PIN', errorText: _error),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _checking ? null : _unlock, child: Text(_checking ? 'Checking…' : 'Unlock')),
              if (s.lockBio) ...[
                const SizedBox(height: 8),
                TextButton(onPressed: _bio, child: const Text('Use biometrics')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

