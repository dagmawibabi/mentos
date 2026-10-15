import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

final _rng = Random.secure();
final _ed = Ed25519();
final _xchacha = Xchacha20.poly1305Aead();
final _aes = AesGcm.with256bits();

Uint8List randomBytes(int n) => Uint8List.fromList(List.generate(n, (_) => _rng.nextInt(256)));

String toHex(List<int> b) => b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
Uint8List fromHex(String h) =>
    Uint8List.fromList(List.generate(h.length ~/ 2, (i) => int.parse(h.substring(i * 2, i * 2 + 2), radix: 16)));

Uint8List sha256(List<int> data) => Uint8List.fromList(hashes.sha256.convert(data).bytes);

/// A device identity: an Ed25519 key. The public key (hex) is the user's id and
/// doubles as the iroh node id, so whoever holds this key *is* the account.
class Identity {
  Identity._(this.seed, this._kp, this.id);

  final Uint8List seed;
  final SimpleKeyPair _kp;
  final String id;

  static Future<Identity> fromSeed(Uint8List seed) async {
    final kp = await _ed.newKeyPairFromSeed(seed);
    final pub = await kp.extractPublicKey();
    return Identity._(seed, kp, toHex(pub.bytes));
  }

  static Future<Identity> generate() => fromSeed(randomBytes(32));

  static Future<Identity> fromPhrase(String phrase) {
    final normalized = phrase.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');
    if (!bip39.validateMnemonic(normalized)) throw const FormatException('That recovery phrase is not valid.');
    return fromSeed(fromHex(bip39.mnemonicToEntropy(normalized)));
  }

  /// 24-word phrase that encodes the seed itself, so it fully restores the key.
  String get phrase => bip39.entropyToMnemonic(toHex(seed));

  Future<String> sign(List<int> data) async {
    final sig = await _ed.sign(data, keyPair: _kp);
    return base64Encode(sig.bytes);
  }

  static Future<bool> verify(String idHex, List<int> data, String sigB64) async {
    try {
      final pub = SimplePublicKey(fromHex(idHex), type: KeyPairType.ed25519);
      return await _ed.verify(data, signature: Signature(base64Decode(sigB64), publicKey: pub));
    } catch (_) {
      return false;
    }
  }
}

/// Symmetric sealing for small payloads (space gossip). Output: nonce|cipher|mac.
class Seal {
  static Future<Uint8List> close(Uint8List key, List<int> plain) async {
    final box = await _xchacha.encrypt(plain, secretKey: SecretKey(key));
    return Uint8List.fromList(box.concatenation());
  }

  static Future<Uint8List?> open(Uint8List key, List<int> sealed) async {
    try {
      final box = SecretBox.fromConcatenation(sealed,
          nonceLength: _xchacha.nonceLength, macLength: _xchacha.macAlgorithm.macLength);
      return Uint8List.fromList(await _xchacha.decrypt(box, secretKey: SecretKey(key)));
    } catch (_) {
      return null;
    }
  }
}

/// Chunked AES-256-GCM for files. Every file gets its own random key, so the
/// counter nonce never repeats under the same key. Blobs on disk and on the
/// wire are always ciphertext; the key travels inside the signed message.
class FileCipher {
  static const chunk = 256 * 1024;
  static const _overhead = 16;

  static Uint8List _nonce(int i) {
    final n = Uint8List(12);
    ByteData.sublistView(n).setUint64(4, i);
    return n;
  }

  static Future<void> encrypt(File input, File output, Uint8List key) async {
    final sk = SecretKey(key);
    final raf = await input.open();
    final sink = output.openWrite();
    try {
      var i = 0;
      while (true) {
        final data = await raf.read(chunk);
        if (data.isEmpty) break;
        final box = await _aes.encrypt(data, secretKey: sk, nonce: _nonce(i++));
        sink.add(box.cipherText);
        sink.add(box.mac.bytes);
        if (data.length < chunk) break;
      }
      await sink.flush();
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      if (output.existsSync()) await output.delete().catchError((_) => output);
      rethrow;
    } finally {
      await raf.close();
      try {
        await sink.close();
      } catch (_) {}
    }
  }

  static Future<void> decrypt(File input, File output, Uint8List key, {int? plainSize}) async {
    final sk = SecretKey(key);
    final tmp = File('${output.path}.part');
    if (tmp.existsSync()) await tmp.delete();
    final raf = await input.open();
    final sink = tmp.openWrite();
    try {
      var i = 0;
      while (true) {
        final data = await raf.read(chunk + _overhead);
        if (data.isEmpty) break;
        if (data.length < _overhead) {
          throw const FormatException('truncated ciphertext');
        }
        final ct = data.sublist(0, data.length - _overhead);
        final mac = Mac(data.sublist(data.length - _overhead));
        sink.add(await _aes.decrypt(SecretBox(ct, nonce: _nonce(i++), mac: mac), secretKey: sk));
        if (data.length < chunk + _overhead) break;
      }
      await sink.flush();
      await sink.close();
      final n = await tmp.length();
      if (plainSize != null && n != plainSize) {
        throw const FormatException('plaintext length mismatch');
      }
      if (output.existsSync()) await output.delete();
      await tmp.rename(output.path);
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      if (tmp.existsSync()) await tmp.delete().catchError((_) => tmp);
      if (output.existsSync()) await output.delete().catchError((_) => output);
      rethrow;
    } finally {
      await raf.close();
    }
  }
}
