import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/plugins/script.dart';

void main() {
  Object? ev(String s) => Interp().eval(s);

  test('expressions, closures and builtins', () {
    expect(ev('1 + 2 * 3'), 7);
    expect(ev('10 / 4'), 2.5);
    expect(ev('"a" + 1'), 'a1');
    expect(ev('`x=${1 + 1}!`'), 'x=2!');
    expect(ev('let a = [3, 1, 2]; a.sort((x, y) => x - y); a.join("-")'), '1-2-3');
    expect(ev('[1,2,3].map(x => x * 2).filter(x => x > 2).reduce((a, b) => a + b, 0)'), 10);
    expect(ev('function f(n) { return n < 2 ? n : f(n - 1) + f(n - 2) } f(15)'), 610);
    expect(ev('const mk = () => { let c = 0; return () => ++c }; const g = mk(); g(); g(); g()'), 3);
    expect(ev('let o = {a: 1, b: {c: [4, 5]}}; o.b.c[1] + o.a'), 6);
    expect(ev('let o = null; o?.x?.y ?? "none"'), 'none');
    expect(ev('let s = 0; for (let i = 0; i < 10; i++) { if (i % 2) continue; if (i > 6) break; s += i } s'), 12);
    expect(ev('let t = ""; for (const k in {x: 1, y: 2}) t += k; t'), 'xy');
    expect(ev('let t = 0; for (const v of [1, 2, 3]) t += v; t'), 6);
    expect(ev('JSON.stringify({a: [1, "b", true, null]})'), '{"a":[1,"b",true,null]}');
    expect(ev('JSON.parse("{\\"x\\": 2}").x'), 2);
    expect(ev('"Hello World".split(" ").map(w => w.toUpperCase()).join("_")'), 'HELLO_WORLD');
    expect(ev('let m; try { throw {message: "boom"} } catch (e) { m = e.message } m'), 'boom');
    expect(ev('let r; try { null.x } catch (e) { r = "caught" } r'), 'caught');
    expect(ev('typeof missing'), 'undefined');
    expect(ev('let q = {...{a: 1}, b: 2}; Object.keys(q).length'), 2);
    expect(ev('Math.max(...[4, 9, 2])'), 9);
    expect(ev('(5).toFixed(2)'), '5.00');
  });

  test('budget stops runaway scripts', () {
    expect(() => Interp(stepBudget: 10000).run('while (true) {}'), throwsA(isA<ScriptError>()));
    expect(() => Interp().run('function f() { return f() } f()'), throwsA(isA<ScriptError>()));
    expect(() => Interp().run('const a = 1; a = 2'), throwsA(isA<ScriptError>()));
    expect(() => Interp().run('let x = ;'), throwsA(isA<ScriptError>()));
  });

  test('host functions and frozen api', () {
    final logs = <String>[];
    final i = Interp(onLog: logs.add);
    final calls = <Object?>[];
    i.define('host', frozen({'say': Native('say', (a) => calls.add(a.first))}));
    i.run('host.say("hi"); console.log("n", 1, {a: 2}); let h = (x) => x * 3;');
    expect(calls, ['hi']);
    expect(logs, ['n 1 {"a":2}']);
    expect(() => i.run('host.say = 1'), throwsA(isA<ScriptError>()));
    final h = i.eval('h');
    expect(i.invoke(h, [4]), 12);
  });
}
