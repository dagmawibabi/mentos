import 'dart:convert';
import 'dart:isolate';

import 'package:cryptography/cryptography.dart';

import 'crypto/crypto.dart';

/// App PIN storage. A PIN is short, so a fast unsalted hash can be reversed
/// by trying every PIN. PBKDF2 with a random salt makes each guess cost
/// real work. Format: `p2$<iterations>$<salt b64>$<hash b64>`.
abstract final class PinHash {
  static const iterations = 120000;

  static Future<String> create(String pin, {int iterations = iterations}) async {
    final salt = randomBytes(16);
    final hash = await _derive(pin, salt, iterations);
    return 'p2\$$iterations\$${base64Encode(salt)}\$${base64Encode(hash)}';
  }

  /// True when [pin] matches [stored]. Accepts the old SHA-256 hex format.
  static Future<bool> verify(String pin, String stored) async {
    if (stored.isEmpty) return false;
    if (isLegacy(stored)) return _same(utf8.encode(toHex(sha256(utf8.encode(pin)))), utf8.encode(stored));
    final parts = stored.split(r'$');
    if (parts.length != 4 || parts[0] != 'p2') return false;
    final iterations = int.tryParse(parts[1]);
    if (iterations == null || iterations < 1000 || iterations > 5000000) return false;
    try {
      final salt = base64Decode(parts[2]);
      final want = base64Decode(parts[3]);
      return _same(await _derive(pin, salt, iterations), want);
    } catch (_) {
      return false;
    }
  }

  static bool isLegacy(String stored) => RegExp(r'^[0-9a-f]{64}$').hasMatch(stored);

  static Future<List<int>> _derive(String pin, List<int> salt, int iterations) {
    // Off the UI isolate: 120k rounds of HMAC-SHA256 take a noticeable moment.
    return Isolate.run(() async {
      final kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256);
      final key = await kdf.deriveKeyFromPassword(password: pin, nonce: salt);
      return key.extractBytes();
    });
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

/// Wrong-PIN backoff that survives restarting the app. The first few
/// mistakes are free; after that each one doubles the wait, up to an hour.
class PinThrottle {
  const PinThrottle({this.fails = 0, this.until = 0});

  static const free = 3;
  static const base = Duration(seconds: 15);
  static const cap = Duration(hours: 1);

  final int fails;

  /// No attempts before this time, ms since epoch.
  final int until;

  Duration waitAt(int now) => Duration(milliseconds: (until - now).clamp(0, cap.inMilliseconds));

  PinThrottle failed(int now) {
    final n = fails + 1;
    if (n <= free) return PinThrottle(fails: n);
    final ms = (base.inMilliseconds * (1 << (n - free - 1).clamp(0, 20))).clamp(0, cap.inMilliseconds);
    return PinThrottle(fails: n, until: now + ms);
  }

  String encode() => jsonEncode({'f': fails, 'u': until});

  static PinThrottle decode(String? raw) {
    if (raw == null) return const PinThrottle();
    try {
      final m = jsonDecode(raw) as Map;
      return PinThrottle(fails: (m['f'] as num).toInt(), until: (m['u'] as num).toInt());
    } catch (_) {
      return const PinThrottle();
    }
  }
}
