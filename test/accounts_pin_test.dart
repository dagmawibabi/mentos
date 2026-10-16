import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/core/crypto/crypto.dart';
import 'package:mentos/core/pin.dart';
import 'package:mentos/state/accounts.dart';

void main() {
  group('accounts', () {
    late Directory base;
    setUp(() async => base = await Directory.systemTemp.createTemp('mentos-accounts-'));
    tearDown(() async => base.delete(recursive: true));

    test('existing installs are the primary account at the root', () {
      final reg = AccountRegistry(base.path);
      final s = reg.load();
      expect(s.accounts.single.primary, isTrue);
      expect(reg.activeDir(), base.path);
    });

    test('add, switch, rename and remove', () {
      final reg = AccountRegistry(base.path);
      reg.update('.', id: 'a' * 64, name: 'Ada');
      final added = reg.addNew();
      expect(reg.load().active, added.dir);
      expect(Directory(reg.dirOf(added.dir)).existsSync(), isTrue);
      expect(reg.previousOf(added.dir)!.name, 'Ada');

      reg.update(added.dir, id: 'b' * 64, name: 'Bo');
      reg.setActive('.');
      expect(reg.activeDir(), base.path);

      File('${reg.dirOf(added.dir)}/mentos.db').writeAsStringSync('x');
      reg.remove(added.dir);
      expect(reg.load().accounts.map((a) => a.dir), ['.']);
      expect(Directory('${base.path}/${added.dir}').existsSync(), isFalse);
    });

    test('removing the open account falls back to the most recent other', () async {
      final reg = AccountRegistry(base.path);
      reg.update('.', id: 'a' * 64);
      final b = reg.addNew();
      reg.update(b.dir, id: 'b' * 64);
      final c = reg.addNew();
      reg.setActive(b.dir);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      reg.setActive(c.dir);
      reg.remove(c.dir);
      expect(reg.load().active, b.dir);
    });

    test('never trusts a folder name from the file', () {
      File('${base.path}/accounts.json').writeAsStringSync(jsonEncode({
        'active': '../../etc',
        'accounts': [
          {'dir': '../../etc', 'id': 'x'},
          {'dir': 'accounts/0123456789abcdef', 'id': 'y'},
          {'dir': 'accounts/0123456789abcdef', 'id': 'dup'},
        ],
      }));
      final s = AccountRegistry(base.path).load();
      expect(s.accounts.map((a) => a.dir), ['accounts/0123456789abcdef']);
      expect(s.active, 'accounts/0123456789abcdef');
      expect(() => AccountRegistry(base.path).dirOf('accounts/../x'), throwsArgumentError);
      File('${base.path}/accounts.json').writeAsStringSync('{not json');
      expect(AccountRegistry(base.path).load().active, '.');
    });
  });

  group('pin', () {
    test('salted hash verifies only the right PIN', () async {
      final a = await PinHash.create('2468', iterations: 2000);
      final b = await PinHash.create('2468', iterations: 2000);
      expect(a, isNot(b), reason: 'salted');
      expect(a, startsWith(r'p2$2000$'));
      expect(await PinHash.verify('2468', a), isTrue);
      expect(await PinHash.verify('2469', a), isFalse);
      expect(await PinHash.verify('2468', 'garbage'), isFalse);
      expect(await PinHash.verify('2468', r'p2$1$AA==$AA=='), isFalse, reason: 'too few iterations');
      expect(await PinHash.verify('', ''), isFalse);
    });

    test('legacy SHA-256 PINs still unlock', () async {
      final legacy = toHex(sha256(utf8.encode('1234')));
      expect(PinHash.isLegacy(legacy), isTrue);
      expect(await PinHash.verify('1234', legacy), isTrue);
      expect(await PinHash.verify('0000', legacy), isFalse);
    });

    test('throttle: a few free tries, then doubling waits, capped', () {
      var t = const PinThrottle();
      const now = 1000000;
      for (var i = 0; i < PinThrottle.free; i++) {
        t = t.failed(now);
        expect(t.waitAt(now), Duration.zero);
      }
      t = t.failed(now);
      expect(t.waitAt(now), PinThrottle.base);
      t = t.failed(now);
      expect(t.waitAt(now), PinThrottle.base * 2);
      for (var i = 0; i < 30; i++) {
        t = t.failed(now);
      }
      expect(t.waitAt(now), PinThrottle.cap);
      expect(PinThrottle.decode(t.encode()).fails, t.fails);
      expect(PinThrottle.decode('nope').fails, 0);
    });
  });
}
