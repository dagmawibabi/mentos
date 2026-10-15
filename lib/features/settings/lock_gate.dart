import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/crypto/crypto.dart';
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
  DateTime? _nextTry;
  int _fails = 0;
  String? _error;

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
    } catch (_) {}
  }

  void _unlock() {
    final wait = _nextTry?.difference(DateTime.now());
    if (wait != null && !wait.isNegative) {
      setState(() => _error = 'Try again in ${wait.inSeconds + 1}s');
      return;
    }
    final s = ref.read(settingsProvider);
    if (toHex(sha256(utf8.encode(_pin.text))) != s.lockHash) {
      _fails += 1;
      final seconds = 1 << _fails.clamp(0, 5);
      _nextTry = DateTime.now().add(Duration(seconds: seconds));
      setState(() => _error = 'Wrong PIN');
      return;
    }
    _fails = 0;
    _nextTry = null;
    setState(() {
      _locked = false;
      _error = null;
    });
    _pin.clear();
  }

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
              FilledButton(onPressed: _unlock, child: const Text('Unlock')),
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

String pinHash(String pin) => toHex(sha256(utf8.encode(pin)));
