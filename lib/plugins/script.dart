import 'dart:convert';
import 'dart:math' as math;

/// MentosScript: the small JavaScript subset plugins are written in.
///
/// It runs inside the app with no file, network or platform access of its
/// own. Everything a plugin can touch comes from the host object it is given,
/// and every call runs on a step and depth budget so a bad loop cannot hang
/// the app.
///
/// Supported: let/const/var, functions and arrows (closures), objects,
/// arrays, template strings, if/else, while, for, for-of, for-in, break,
/// continue, return, try/catch/throw, the usual operators including ?. and ??,
/// and common String, Array, Math, JSON and Object helpers.
class ScriptError implements Exception {
  ScriptError(this.message, [this.line]);
  final String message;
  final int? line;
  @override
  String toString() => line == null ? message : 'line $line: $message';
}

/// A function the host provides. [self] is the receiver for method calls.
typedef NativeFn = Object? Function(List<Object?> args);

class Native {
  const Native(this.name, this.fn);
  final String name;
  final NativeFn fn;
}

class Closure {
  // ignore: library_private_types_in_public_api
  Closure(this.name, this.params, this.body, this.env, this.interp, {this.arrowExpr = false});
  final String name;
  final List<String> params;
  final Object body; // _Block or _Expr for arrow expressions
  // ignore: library_private_types_in_public_api
  final _Env env;
  final Interp interp;
  final bool arrowExpr;

  Object? call(List<Object?> args) => interp.callFunction(this, args);
}

// ---------------------------------------------------------------- lexer

enum _T { num, str, tmpl, ident, kw, punct, eof }

class _Tok {
  _Tok(this.t, this.v, this.line, {this.parts});
  final _T t;
  final String v;
  final int line;

  /// Template literal: alternating string, source, string, ...
  final List<String>? parts;
  @override
  String toString() => '$t($v)';
}

const _keywords = {
  'let', 'const', 'var', 'function', 'return', 'if', 'else', 'while', 'for', 'of', 'in', 'break',
  'continue', 'true', 'false', 'null', 'undefined', 'typeof', 'try', 'catch', 'finally', 'throw',
};

const _puncts = [
  '===', '!==', '...', '??=', '**', '=>', '==', '!=', '<=', '>=', '&&', '||', '??', '?.', '++', '--', '+=', '-=',
  '*=', '/=', '%=', '{', '}', '(', ')', '[', ']', ';', ',', '.', ':', '?', '+', '-', '*', '/', '%', '<', '>',
  '=', '!',
];

List<_Tok> _lex(String src) {
  final out = <_Tok>[];
  var i = 0, line = 1;
  bool isIdStart(int c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36;
  bool isDigit(int c) => c >= 48 && c <= 57;
  while (i < src.length) {
    final c = src.codeUnitAt(i);
    if (c == 10) {
      line++;
      i++;
      continue;
    }
    if (c == 32 || c == 9 || c == 13) {
      i++;
      continue;
    }
    if (src.startsWith('//', i)) {
      while (i < src.length && src.codeUnitAt(i) != 10) {
        i++;
      }
      continue;
    }
    if (src.startsWith('/*', i)) {
      final end = src.indexOf('*/', i + 2);
      if (end < 0) throw ScriptError('unclosed comment', line);
      line += '\n'.allMatches(src.substring(i, end)).length;
      i = end + 2;
      continue;
    }
    if (isDigit(c) || (c == 46 && i + 1 < src.length && isDigit(src.codeUnitAt(i + 1)))) {
      final m = RegExp(r'0x[0-9a-fA-F]+|\d*\.?\d+(?:[eE][+-]?\d+)?').matchAsPrefix(src, i)!;
      out.add(_Tok(_T.num, m[0]!, line));
      i = m.end;
      continue;
    }
    if (isIdStart(c)) {
      var j = i + 1;
      while (j < src.length && (isIdStart(src.codeUnitAt(j)) || isDigit(src.codeUnitAt(j)))) {
        j++;
      }
      final w = src.substring(i, j);
      out.add(_Tok(_keywords.contains(w) ? _T.kw : _T.ident, w, line));
      i = j;
      continue;
    }
    if (c == 34 || c == 39) {
      final b = StringBuffer();
      var j = i + 1;
      while (true) {
        if (j >= src.length) throw ScriptError('unclosed string', line);
        final d = src.codeUnitAt(j);
        if (d == c) break;
        if (d == 10) throw ScriptError('newline in string', line);
        if (d == 92) {
          j = _escape(src, j, b, line);
          continue;
        }
        b.writeCharCode(d);
        j++;
      }
      out.add(_Tok(_T.str, b.toString(), line));
      i = j + 1;
      continue;
    }
    if (c == 96) {
      final parts = <String>[];
      final b = StringBuffer();
      var j = i + 1;
      final startLine = line;
      while (true) {
        if (j >= src.length) throw ScriptError('unclosed template', startLine);
        final d = src.codeUnitAt(j);
        if (d == 96) break;
        if (d == 10) line++;
        if (d == 92) {
          j = _escape(src, j, b, line);
          continue;
        }
        if (d == 36 && j + 1 < src.length && src.codeUnitAt(j + 1) == 123) {
          parts.add(b.toString());
          b.clear();
          var depth = 1, k = j + 2;
          while (k < src.length && depth > 0) {
            final e = src.codeUnitAt(k);
            if (e == 123) depth++;
            if (e == 125) depth--;
            k++;
          }
          if (depth > 0) throw ScriptError('unclosed \${ in template', line);
          parts.add(src.substring(j + 2, k - 1));
          j = k;
          continue;
        }
        b.writeCharCode(d);
        j++;
      }
      parts.add(b.toString());
      out.add(_Tok(_T.tmpl, '`', startLine, parts: parts));
      i = j + 1;
      continue;
    }
    String? p;
    for (final q in _puncts) {
      if (src.startsWith(q, i)) {
        p = q;
        break;
      }
    }
    if (p == null) throw ScriptError('unexpected character ${src[i]}', line);
    out.add(_Tok(_T.punct, p, line));
    i += p.length;
  }
  out.add(_Tok(_T.eof, '', line));
  return out;
}

int _escape(String src, int j, StringBuffer b, int line) {
  if (j + 1 >= src.length) throw ScriptError('bad escape', line);
  final e = src[j + 1];
  switch (e) {
    case 'n':
      b.write('\n');
    case 't':
      b.write('\t');
    case 'r':
      b.write('\r');
    case '0':
      b.write('\x00');
    case 'u':
      if (j + 2 < src.length && src[j + 2] == '{') {
        final end = src.indexOf('}', j + 3);
        if (end < 0) throw ScriptError('bad escape', line);
        b.writeCharCode(int.parse(src.substring(j + 3, end), radix: 16));
        return end + 1;
      }
      if (j + 6 > src.length) throw ScriptError('bad escape', line);
      b.writeCharCode(int.parse(src.substring(j + 2, j + 6), radix: 16));
      return j + 6;
    default:
      b.write(e);
  }
  return j + 2;
}

// ---------------------------------------------------------------- AST

sealed class _Node {
  _Node(this.line);
  final int line;
}

sealed class _Expr extends _Node {
  _Expr(super.line);
}

class _Lit extends _Expr {
  _Lit(super.line, this.v);
  final Object? v;
}

class _Tmpl extends _Expr {
  _Tmpl(super.line, this.strs, this.exprs);
  final List<String> strs;
  final List<_Expr> exprs;
}

class _Id extends _Expr {
  _Id(super.line, this.name);
  final String name;
}

class _Arr extends _Expr {
  _Arr(super.line, this.items);
  final List<_Expr> items; // _Spread allowed
}

class _Obj extends _Expr {
  _Obj(super.line, this.entries);
  final List<(Object, _Expr)> entries; // key: String | _Expr (computed) | null for spread
}

class _Spread extends _Expr {
  _Spread(super.line, this.e);
  final _Expr e;
}

class _Fn extends _Expr {
  _Fn(super.line, this.name, this.params, this.body, {this.arrowExpr = false});
  final String name;
  final List<String> params;
  final Object body;
  final bool arrowExpr;
}

class _Member extends _Expr {
  _Member(super.line, this.obj, this.prop, {this.optional = false});
  final _Expr obj;
  final _Expr prop; // _Lit(String) for dot access
  final bool optional;
}

class _Call extends _Expr {
  _Call(super.line, this.callee, this.args, {this.optional = false});
  final _Expr callee;
  final List<_Expr> args;
  final bool optional;
}

class _Unary extends _Expr {
  _Unary(super.line, this.op, this.e);
  final String op;
  final _Expr e;
}

class _Update extends _Expr {
  _Update(super.line, this.op, this.target, this.prefix);
  final String op;
  final _Expr target;
  final bool prefix;
}

class _Bin extends _Expr {
  _Bin(super.line, this.op, this.a, this.b);
  final String op;
  final _Expr a, b;
}

class _Cond extends _Expr {
  _Cond(super.line, this.c, this.a, this.b);
  final _Expr c, a, b;
}

class _Assign extends _Expr {
  _Assign(super.line, this.op, this.target, this.value);
  final String op;
  final _Expr target, value;
}

sealed class _Stmt extends _Node {
  _Stmt(super.line);
}

class _ExprStmt extends _Stmt {
  _ExprStmt(super.line, this.e);
  final _Expr e;
}

class _Decl extends _Stmt {
  _Decl(super.line, this.names, this.inits, this.isConst);
  final List<String> names;
  final List<_Expr?> inits;
  final bool isConst;
}

class _Block extends _Stmt {
  _Block(super.line, this.body);
  final List<_Stmt> body;
}

class _If extends _Stmt {
  _If(super.line, this.c, this.a, this.b);
  final _Expr c;
  final _Stmt a;
  final _Stmt? b;
}

class _While extends _Stmt {
  _While(super.line, this.c, this.body);
  final _Expr c;
  final _Stmt body;
}

class _For extends _Stmt {
  _For(super.line, this.init, this.c, this.upd, this.body);
  final _Stmt? init;
  final _Expr? c, upd;
  final _Stmt body;
}

class _ForOf extends _Stmt {
  _ForOf(super.line, this.name, this.iter, this.body, {required this.keys});
  final String name;
  final _Expr iter;
  final _Stmt body;
  final bool keys;
}

class _Return extends _Stmt {
  _Return(super.line, this.e);
  final _Expr? e;
}

class _Break extends _Stmt {
  _Break(super.line);
}

class _Continue extends _Stmt {
  _Continue(super.line);
}

class _Throw extends _Stmt {
  _Throw(super.line, this.e);
  final _Expr e;
}

class _Try extends _Stmt {
  _Try(super.line, this.body, this.name, this.handler, this.fin);
  final _Block body;
  final String? name;
  final _Block? handler;
  final _Block? fin;
}

class _FnDecl extends _Stmt {
  _FnDecl(super.line, this.fn);
  final _Fn fn;
}

class _Empty extends _Stmt {
  _Empty(super.line);
}

// ---------------------------------------------------------------- parser

class _Parser {
  _Parser(this.toks);
  final List<_Tok> toks;
  var i = 0;

  _Tok get cur => toks[i];
  _Tok get next => toks[math.min(i + 1, toks.length - 1)];

  bool isP(String v) => cur.t == _T.punct && cur.v == v;
  bool isK(String v) => cur.t == _T.kw && cur.v == v;

  _Tok take() => toks[i++];

  void expectP(String v) {
    if (!isP(v)) throw ScriptError('expected "$v" but found "${cur.v.isEmpty ? 'end' : cur.v}"', cur.line);
    i++;
  }

  bool eatP(String v) {
    if (isP(v)) {
      i++;
      return true;
    }
    return false;
  }

  String ident() {
    if (cur.t != _T.ident) throw ScriptError('expected a name but found "${cur.v}"', cur.line);
    return take().v;
  }

  List<_Stmt> program() {
    final out = <_Stmt>[];
    while (cur.t != _T.eof) {
      out.add(stmt());
    }
    return out;
  }

  void semi() {
    eatP(';');
  }

  _Stmt stmt() {
    final line = cur.line;
    if (isP('{')) return block();
    if (isP(';')) {
      i++;
      return _Empty(line);
    }
    if (isK('let') || isK('const') || isK('var')) {
      final d = decl();
      semi();
      return d;
    }
    if (isK('function') && next.t == _T.ident) {
      i++;
      final name = ident();
      return _FnDecl(line, fnRest(line, name));
    }
    if (isK('return')) {
      i++;
      if (isP(';') || isP('}') || cur.t == _T.eof || cur.line != line) {
        semi();
        return _Return(line, null);
      }
      final e = expr();
      semi();
      return _Return(line, e);
    }
    if (isK('if')) {
      i++;
      expectP('(');
      final c = expr();
      expectP(')');
      final a = stmt();
      _Stmt? b;
      if (isK('else')) {
        i++;
        b = stmt();
      }
      return _If(line, c, a, b);
    }
    if (isK('while')) {
      i++;
      expectP('(');
      final c = expr();
      expectP(')');
      return _While(line, c, stmt());
    }
    if (isK('for')) {
      i++;
      expectP('(');
      if ((isK('let') || isK('const') || isK('var')) && next.t == _T.ident) {
        final save = i;
        i++;
        final name = ident();
        if (isK('of') || isK('in')) {
          final keys = take().v == 'in';
          final it = expr();
          expectP(')');
          return _ForOf(line, name, it, stmt(), keys: keys);
        }
        i = save;
      }
      _Stmt? init;
      if (!isP(';')) {
        init = (isK('let') || isK('const') || isK('var')) ? decl() : _ExprStmt(line, expr());
      }
      expectP(';');
      final c = isP(';') ? null : expr();
      expectP(';');
      final upd = isP(')') ? null : expr();
      expectP(')');
      return _For(line, init, c, upd, stmt());
    }
    if (isK('break')) {
      i++;
      semi();
      return _Break(line);
    }
    if (isK('continue')) {
      i++;
      semi();
      return _Continue(line);
    }
    if (isK('throw')) {
      i++;
      final e = expr();
      semi();
      return _Throw(line, e);
    }
    if (isK('try')) {
      i++;
      final body = block();
      String? name;
      _Block? handler, fin;
      if (isK('catch')) {
        i++;
        if (eatP('(')) {
          name = ident();
          expectP(')');
        }
        handler = block();
      }
      if (isK('finally')) {
        i++;
        fin = block();
      }
      if (handler == null && fin == null) throw ScriptError('try needs catch or finally', line);
      return _Try(line, body, name, handler, fin);
    }
    final e = expr();
    semi();
    return _ExprStmt(line, e);
  }

  _Block block() {
    final line = cur.line;
    expectP('{');
    final out = <_Stmt>[];
    while (!isP('}')) {
      if (cur.t == _T.eof) throw ScriptError('missing "}"', line);
      out.add(stmt());
    }
    i++;
    return _Block(line, out);
  }

  _Decl decl() {
    final line = cur.line;
    final isConst = take().v == 'const';
    final names = <String>[];
    final inits = <_Expr?>[];
    do {
      names.add(ident());
      inits.add(eatP('=') ? assign() : null);
    } while (eatP(','));
    return _Decl(line, names, inits, isConst);
  }

  _Fn fnRest(int line, String name) {
    expectP('(');
    final params = <String>[];
    while (!isP(')')) {
      params.add(ident());
      if (!isP(')')) expectP(',');
    }
    i++;
    return _Fn(line, name, params, block());
  }

  _Expr expr() => assign();

  bool _arrowAhead() {
    // ident =>   or   ( a, b ) =>
    if (cur.t == _T.ident && next.t == _T.punct && next.v == '=>') return true;
    if (!isP('(')) return false;
    var j = i + 1;
    while (j < toks.length) {
      final t = toks[j];
      if (t.t == _T.punct && t.v == ')') {
        return j + 1 < toks.length && toks[j + 1].t == _T.punct && toks[j + 1].v == '=>';
      }
      if (t.t == _T.ident || (t.t == _T.punct && t.v == ',')) {
        j++;
        continue;
      }
      return false;
    }
    return false;
  }

  _Expr arrow() {
    final line = cur.line;
    final params = <String>[];
    if (cur.t == _T.ident) {
      params.add(take().v);
    } else {
      expectP('(');
      while (!isP(')')) {
        params.add(ident());
        if (!isP(')')) expectP(',');
      }
      i++;
    }
    expectP('=>');
    if (isP('{')) return _Fn(line, '', params, block());
    return _Fn(line, '', params, assign(), arrowExpr: true);
  }

  _Expr assign() {
    if (_arrowAhead()) return arrow();
    final line = cur.line;
    final left = ternary();
    for (final op in const ['=', '+=', '-=', '*=', '/=', '%=', '??=']) {
      if (isP(op)) {
        if (left is! _Id && left is! _Member) throw ScriptError('cannot assign to that', line);
        i++;
        return _Assign(line, op, left, assign());
      }
    }
    return left;
  }

  _Expr ternary() {
    final line = cur.line;
    final c = binary(0);
    if (eatP('?')) {
      final a = assign();
      expectP(':');
      return _Cond(line, c, a, assign());
    }
    return c;
  }

  static const _prec = <String, int>{
    '??': 1, '||': 2, '&&': 3, '==': 4, '!=': 4, '===': 4, '!==': 4,
    '<': 5, '>': 5, '<=': 5, '>=': 5, 'in': 5, '+': 6, '-': 6, '*': 7, '/': 7, '%': 7, '**': 8,
  };

  _Expr binary(int min) {
    var left = unary();
    while (true) {
      final op = (cur.t == _T.punct || isK('in')) ? cur.v : null;
      final pr = op == null ? null : _prec[op];
      if (pr == null || pr <= min) break;
      final line = cur.line;
      i++;
      final right = op == '**' ? binary(pr - 1) : binary(pr);
      left = _Bin(line, op!, left, right);
    }
    return left;
  }

  _Expr unary() {
    final line = cur.line;
    if (isP('!') || isP('-') || isP('+')) {
      final op = take().v;
      return _Unary(line, op, unary());
    }
    if (isK('typeof')) {
      i++;
      return _Unary(line, 'typeof', unary());
    }
    if (isP('++') || isP('--')) {
      final op = take().v;
      return _Update(line, op, unary(), true);
    }
    final e = postfix();
    if ((isP('++') || isP('--')) && cur.line == line) {
      return _Update(line, take().v, e, false);
    }
    return e;
  }

  List<_Expr> args() {
    final out = <_Expr>[];
    while (!isP(')')) {
      if (eatP('...')) {
        out.add(_Spread(cur.line, assign()));
      } else {
        out.add(assign());
      }
      if (!isP(')')) expectP(',');
    }
    i++;
    return out;
  }

  _Expr postfix() {
    var e = primary();
    while (true) {
      final line = cur.line;
      if (eatP('.')) {
        final name = cur.t == _T.ident || cur.t == _T.kw ? take().v : throw ScriptError('expected a property name', line);
        e = _Member(line, e, _Lit(line, name));
      } else if (eatP('?.')) {
        if (eatP('(')) {
          e = _Call(line, e, args(), optional: true);
        } else if (eatP('[')) {
          final p = expr();
          expectP(']');
          e = _Member(line, e, p, optional: true);
        } else {
          final name = cur.t == _T.ident || cur.t == _T.kw ? take().v : throw ScriptError('expected a property name', line);
          e = _Member(line, e, _Lit(line, name), optional: true);
        }
      } else if (eatP('[')) {
        final p = expr();
        expectP(']');
        e = _Member(line, e, p);
      } else if (eatP('(')) {
        e = _Call(line, e, args());
      } else {
        break;
      }
    }
    return e;
  }

  _Expr primary() {
    final t = cur;
    final line = t.line;
    switch (t.t) {
      case _T.num:
        i++;
        return _Lit(line, t.v.startsWith('0x') ? int.parse(t.v.substring(2), radix: 16) : _numOf(t.v));
      case _T.str:
        i++;
        return _Lit(line, t.v);
      case _T.tmpl:
        i++;
        final strs = <String>[], exprs = <_Expr>[];
        final parts = t.parts!;
        for (var k = 0; k < parts.length; k++) {
          if (k.isEven) {
            strs.add(parts[k]);
          } else {
            final sub = _Parser(_lex(parts[k]));
            exprs.add(sub.expr());
          }
        }
        return _Tmpl(line, strs, exprs);
      case _T.ident:
        i++;
        return _Id(line, t.v);
      case _T.kw:
        switch (t.v) {
          case 'true':
            i++;
            return _Lit(line, true);
          case 'false':
            i++;
            return _Lit(line, false);
          case 'null' || 'undefined':
            i++;
            return _Lit(line, null);
          case 'function':
            i++;
            final name = cur.t == _T.ident ? take().v : '';
            return fnRest(line, name);
        }
      case _T.punct:
        if (t.v == '(') {
          i++;
          final e = expr();
          expectP(')');
          return e;
        }
        if (t.v == '[') {
          i++;
          final items = <_Expr>[];
          while (!isP(']')) {
            if (eatP('...')) {
              items.add(_Spread(cur.line, assign()));
            } else {
              items.add(assign());
            }
            if (!isP(']')) expectP(',');
          }
          i++;
          return _Arr(line, items);
        }
        if (t.v == '{') {
          i++;
          final entries = <(Object, _Expr)>[];
          while (!isP('}')) {
            if (eatP('...')) {
              entries.add(('...', assign()));
            } else if (eatP('[')) {
              final k = expr();
              expectP(']');
              expectP(':');
              entries.add((k, assign()));
            } else {
              final kt = take();
              if (kt.t != _T.ident && kt.t != _T.str && kt.t != _T.kw && kt.t != _T.num) {
                throw ScriptError('bad object key "${kt.v}"', kt.line);
              }
              final key = kt.v;
              if (isP('(')) {
                entries.add((key, fnRest(kt.line, key)));
              } else if (eatP(':')) {
                entries.add((key, assign()));
              } else {
                entries.add((key, _Id(kt.line, key)));
              }
            }
            if (!isP('}')) expectP(',');
          }
          i++;
          return _Obj(line, entries);
        }
      case _T.eof:
        throw ScriptError('unexpected end of script', line);
    }
    throw ScriptError('unexpected "${t.v}"', line);
  }
}

num _numOf(String s) {
  final d = double.parse(s);
  return d == d.truncateToDouble() && d.abs() < 9e15 && !s.contains('.') && !s.contains('e') ? d.toInt() : d;
}

// ---------------------------------------------------------------- runtime

class _Env {
  _Env(this.parent);
  final _Env? parent;
  final vars = <String, Object?>{};
  final consts = <String>{};

  _Env? find(String n) {
    _Env? e = this;
    while (e != null) {
      if (e.vars.containsKey(n)) return e;
      e = e.parent;
    }
    return null;
  }
}

class _Flow {
  const _Flow(this.kind, [this.value]);
  final int kind; // 1 return, 2 break, 3 continue
  final Object? value;
}

const _brk = _Flow(2);
const _cont = _Flow(3);

/// Thrown by `throw` in a script.
class ScriptThrow implements Exception {
  ScriptThrow(this.value);
  final Object? value;
  @override
  String toString() => 'Uncaught ${Interp.show(value)}';
}

class Interp {
  Interp({this.stepBudget = 2000000, this.maxDepth = 120, this.onLog}) {
    _installGlobals();
  }

  /// Steps allowed per top-level run or host-triggered call.
  final int stepBudget;
  final int maxDepth;
  final void Function(String line)? onLog;

  final globals = _Env(null);
  int _steps = 0;
  int _depth = 0;
  int _entered = 0;

  /// Steps spent by the last top-level run or call.
  int get stepsUsed => _steps;

  /// Defines a host value scripts can read by name.
  void define(String name, Object? value) => globals.vars[name] = value;

  /// Throws a [ScriptError] when [source] does not parse. Runs nothing.
  static void validate(String source) => _Parser(_lex(source)).program();

  /// Parses and runs a whole script.
  void run(String source) {
    final prog = _Parser(_lex(source)).program();
    _enter(() {
      _hoist(prog, globals);
      for (final s in prog) {
        final f = _exec(s, globals);
        if (f != null && f.kind == 1) break;
      }
      return null;
    });
  }

  /// Evaluates one expression or statement list and returns the last value.
  Object? eval(String source) {
    final prog = _Parser(_lex(source)).program();
    return _enter(() {
      _hoist(prog, globals);
      Object? last;
      for (final s in prog) {
        if (s is _ExprStmt) {
          last = _ev(s.e, globals);
        } else {
          final f = _exec(s, globals);
          if (f != null && f.kind == 1) return f.value;
        }
      }
      return last;
    });
  }

  /// Calls a script function from the host, with a fresh step budget.
  Object? invoke(Object? fn, List<Object?> args) => _enter(() => callValue(fn, args, 0));

  Object? _enter(Object? Function() body) {
    if (_entered == 0) {
      _steps = 0;
      _depth = 0;
    }
    _entered++;
    try {
      return body();
    } on ScriptError {
      rethrow;
    } on ScriptThrow catch (t) {
      throw ScriptError(t.toString());
    } on StackOverflowError {
      throw ScriptError('too much recursion');
    } finally {
      _entered--;
    }
  }

  void _tick(int line) {
    if (++_steps > stepBudget) throw ScriptError('script ran too long', line);
  }

  void _hoist(List<_Stmt> body, _Env env) {
    for (final s in body) {
      if (s is _FnDecl) env.vars[s.fn.name] = _closure(s.fn, env);
    }
  }

  Closure _closure(_Fn f, _Env env) => Closure(f.name, f.params, f.body, env, this, arrowExpr: f.arrowExpr);

  _Flow? _exec(_Stmt s, _Env env) {
    _tick(s.line);
    switch (s) {
      case _ExprStmt():
        _ev(s.e, env);
        return null;
      case _Decl():
        for (var k = 0; k < s.names.length; k++) {
          final init = s.inits[k];
          env.vars[s.names[k]] = init == null ? null : _ev(init, env);
          if (s.isConst) env.consts.add(s.names[k]);
        }
        return null;
      case _FnDecl():
        return null; // hoisted
      case _Block():
        final inner = _Env(env);
        _hoist(s.body, inner);
        for (final x in s.body) {
          final f = _exec(x, inner);
          if (f != null) return f;
        }
        return null;
      case _If():
        if (truthy(_ev(s.c, env))) return _exec(s.a, env);
        if (s.b != null) return _exec(s.b!, env);
        return null;
      case _While():
        while (truthy(_ev(s.c, env))) {
          final f = _exec(s.body, env);
          if (f == _brk) break;
          if (f != null && f.kind == 1) return f;
        }
        return null;
      case _For():
        final loop = _Env(env);
        if (s.init != null) _exec(s.init!, loop);
        while (s.c == null || truthy(_ev(s.c!, loop))) {
          // Each iteration sees its own copy, so closures capture the value.
          final iter = _Env(loop);
          final f = _exec(s.body, iter);
          if (f == _brk) break;
          if (f != null && f.kind == 1) return f;
          if (s.upd != null) _ev(s.upd!, loop);
        }
        return null;
      case _ForOf():
        final src = _ev(s.iter, env);
        final Iterable<Object?> items;
        if (s.keys) {
          items = src is Map ? src.keys.toList() : (src is List ? List.generate(src.length, (k) => '$k') : const []);
        } else if (src is List) {
          items = List.of(src);
        } else if (src is String) {
          items = src.split('');
        } else if (src is Map) {
          throw ScriptError('object is not iterable, use Object.entries()', s.line);
        } else {
          throw ScriptError('${show(src)} is not iterable', s.line);
        }
        for (final v in items) {
          final iter = _Env(env)..vars[s.name] = v;
          final f = _exec(s.body, iter);
          if (f == _brk) break;
          if (f != null && f.kind == 1) return f;
        }
        return null;
      case _Return():
        return _Flow(1, s.e == null ? null : _ev(s.e!, env));
      case _Break():
        return _brk;
      case _Continue():
        return _cont;
      case _Throw():
        throw ScriptThrow(_ev(s.e, env));
      case _Try():
        _Flow? out;
        try {
          out = _exec(s.body, env);
        } on ScriptThrow catch (t) {
          if (s.handler == null) rethrow;
          final h = _Env(env);
          if (s.name != null) h.vars[s.name!] = t.value;
          out = _exec(s.handler!, h);
        } on ScriptError catch (err) {
          if (s.handler == null || err.message == 'script ran too long') rethrow;
          final h = _Env(env);
          if (s.name != null) h.vars[s.name!] = {'message': err.message};
          out = _exec(s.handler!, h);
        } finally {
          if (s.fin != null) {
            final f = _exec(s.fin!, env);
            if (f != null) out = f;
          }
        }
        return out;
      case _Empty():
        return null;
    }
  }

  Object? _ev(_Expr x, _Env env) {
    _tick(x.line);
    switch (x) {
      case _Lit():
        return x.v;
      case _Tmpl():
        final b = StringBuffer(x.strs.first);
        for (var k = 0; k < x.exprs.length; k++) {
          b
            ..write(str(_ev(x.exprs[k], env)))
            ..write(x.strs[k + 1]);
        }
        return b.toString();
      case _Id():
        final e = env.find(x.name);
        if (e == null) throw ScriptError('${x.name} is not defined', x.line);
        return e.vars[x.name];
      case _Arr():
        final out = <Object?>[];
        for (final it in x.items) {
          if (it is _Spread) {
            final v = _ev(it.e, env);
            if (v is List) {
              out.addAll(v);
            } else if (v != null) {
              throw ScriptError('can only spread arrays here', it.line);
            }
          } else {
            out.add(_ev(it, env));
          }
        }
        return out;
      case _Obj():
        final out = <String, Object?>{};
        for (final (k, v) in x.entries) {
          if (k == '...') {
            final s = _ev(v, env);
            if (s is Map) out.addAll(s.map((a, b) => MapEntry('$a', b)));
          } else {
            out[k is String ? k : str(_ev(k as _Expr, env))] = _ev(v, env);
          }
        }
        return out;
      case _Spread():
        throw ScriptError('unexpected ...', x.line);
      case _Fn():
        return _closure(x, env);
      case _Member():
        final o = _ev(x.obj, env);
        if (o == null) {
          if (x.optional) return null;
          throw ScriptError('cannot read ${_propName(x.prop, env)} of null', x.line);
        }
        return getProp(o, _ev(x.prop, env), x.line);
      case _Call():
        return _call(x, env);
      case _Unary():
        if (x.op == 'typeof') {
          if (x.e is _Id && env.find((x.e as _Id).name) == null) return 'undefined';
          return typeOf(_ev(x.e, env));
        }
        final v = _ev(x.e, env);
        return switch (x.op) {
          '!' => !truthy(v),
          '-' => -toNum(v),
          _ => toNum(v),
        };
      case _Update():
        final old = toNum(_ev(x.target, env));
        final nv = x.op == '++' ? old + 1 : old - 1;
        _store(x.target, nv, env);
        return x.prefix ? nv : old;
      case _Bin():
        if (x.op == '&&') {
          final a = _ev(x.a, env);
          return truthy(a) ? _ev(x.b, env) : a;
        }
        if (x.op == '||') {
          final a = _ev(x.a, env);
          return truthy(a) ? a : _ev(x.b, env);
        }
        if (x.op == '??') {
          final a = _ev(x.a, env);
          return a ?? _ev(x.b, env);
        }
        return binop(x.op, _ev(x.a, env), _ev(x.b, env), x.line);
      case _Cond():
        return truthy(_ev(x.c, env)) ? _ev(x.a, env) : _ev(x.b, env);
      case _Assign():
        if (x.op == '??=') {
          final cur = _ev(x.target, env);
          if (cur != null) return cur;
          final v = _ev(x.value, env);
          _store(x.target, v, env);
          return v;
        }
        final v = x.op == '='
            ? _ev(x.value, env)
            : binop(x.op.substring(0, 1), _ev(x.target, env), _ev(x.value, env), x.line);
        _store(x.target, v, env);
        return v;
    }
  }

  String _propName(_Expr p, _Env env) => p is _Lit ? '"${p.v}"' : 'a property';

  void _store(_Expr target, Object? v, _Env env) {
    if (target is _Id) {
      final e = env.find(target.name);
      if (e == null) throw ScriptError('${target.name} is not defined', target.line);
      if (e.consts.contains(target.name)) throw ScriptError('${target.name} is a constant', target.line);
      e.vars[target.name] = v;
      return;
    }
    if (target is _Member) {
      final o = _ev(target.obj, env);
      final k = _ev(target.prop, env);
      if (o is List) {
        final idx = k is num ? k.toInt() : int.tryParse('$k');
        if (idx == null || idx < 0 || idx > 100000) throw ScriptError('bad array index', target.line);
        while (o.length <= idx) {
          o.add(null);
        }
        o[idx] = v;
        return;
      }
      if (o is Map) {
        if (o is _Frozen) throw ScriptError('this object is read-only', target.line);
        o['$k'] = v;
        return;
      }
      throw ScriptError('cannot set a property on ${typeOf(o)}', target.line);
    }
  }

  Object? _call(_Call x, _Env env) {
    final args = <Object?>[];
    for (final a in x.args) {
      if (a is _Spread) {
        final v = _ev(a.e, env);
        if (v is List) args.addAll(v);
      } else {
        args.add(_ev(a, env));
      }
    }
    // Method call: keep the receiver for built-in String/Array methods.
    if (x.callee is _Member) {
      final m = x.callee as _Member;
      final o = _ev(m.obj, env);
      if (o == null) {
        if (m.optional || x.optional) return null;
        throw ScriptError('cannot call ${_propName(m.prop, env)} on null', x.line);
      }
      final name = _ev(m.prop, env);
      if (o is String || o is List || o is num) {
        return _method(o, '$name', args, x.line);
      }
      final f = getProp(o, name, x.line);
      if (f == null && x.optional) return null;
      return callValue(f, args, x.line, name: '$name');
    }
    final f = _ev(x.callee, env);
    if (f == null && x.optional) return null;
    return callValue(f, args, x.line, name: x.callee is _Id ? (x.callee as _Id).name : null);
  }

  Object? callValue(Object? f, List<Object?> args, int line, {String? name}) {
    if (f is Closure) return callFunction(f, args);
    if (f is Native) {
      try {
        return f.fn(args);
      } on ScriptError {
        rethrow;
      } on ScriptThrow {
        rethrow;
      } catch (err) {
        throw ScriptError('${f.name}: $err', line);
      }
    }
    throw ScriptError('${name ?? show(f)} is not a function', line);
  }

  Object? callFunction(Closure f, List<Object?> args) {
    if (++_depth > maxDepth) {
      _depth--;
      throw ScriptError('too much recursion');
    }
    try {
      final env = _Env(f.env);
      for (var k = 0; k < f.params.length; k++) {
        env.vars[f.params[k]] = k < args.length ? args[k] : null;
      }
      env.vars['arguments'] = args;
      if (f.arrowExpr) return _ev(f.body as _Expr, env);
      final body = f.body as _Block;
      _hoist(body.body, env);
      for (final s in body.body) {
        final r = _exec(s, env);
        if (r != null && r.kind == 1) return r.value;
      }
      return null;
    } finally {
      _depth--;
    }
  }

  // ------------------------------------------------------------ values

  static bool truthy(Object? v) => switch (v) {
        null => false,
        bool b => b,
        num n => n != 0 && !n.isNaN,
        String s => s.isNotEmpty,
        _ => true,
      };

  static String typeOf(Object? v) => switch (v) {
        null => 'object',
        bool _ => 'boolean',
        num _ => 'number',
        String _ => 'string',
        Closure _ || Native _ => 'function',
        _ => 'object',
      };

  static num toNum(Object? v) => switch (v) {
        null => 0,
        bool b => b ? 1 : 0,
        num n => n,
        String s => s.trim().isEmpty ? 0 : (num.tryParse(s.trim()) ?? double.nan),
        _ => double.nan,
      };

  static String str(Object? v) => switch (v) {
        null => 'null',
        String s => s,
        double d when d == d.truncateToDouble() && d.isFinite && d.abs() < 1e21 => d.toInt().toString(),
        num n => n.toString(),
        bool b => '$b',
        List l => l.map((e) => e == null ? '' : str(e)).join(','),
        Closure _ || Native _ => 'function',
        _ => '[object Object]',
      };

  /// For logs: JSON-ish, readable.
  static String show(Object? v) {
    if (v is String) return v;
    try {
      return jsonEncode(toJson(v));
    } catch (_) {
      return str(v);
    }
  }

  static Object? toJson(Object? v, [int depth = 0]) {
    if (depth > 40) throw ScriptError('value is nested too deeply');
    return switch (v) {
      null || bool _ || String _ => v,
      double d when !d.isFinite => null,
      double d when d == d.truncateToDouble() && d.abs() < 9e15 => d.toInt(),
      num n => n,
      List l => [for (final e in l) toJson(e, depth + 1)],
      Map m => {
          for (final e in m.entries)
            if (e.value is! Closure && e.value is! Native) '${e.key}': toJson(e.value, depth + 1),
        },
      _ => null,
    };
  }

  /// Converts decoded JSON (or host data) into script values.
  static Object? fromJson(Object? v) => switch (v) {
        List l => [for (final e in l) fromJson(e)],
        Map m => <String, Object?>{for (final e in m.entries) '${e.key}': fromJson(e.value)},
        _ => v,
      };

  static bool strictEq(Object? a, Object? b) {
    if (a is num && b is num) return a == b;
    if (a is String && b is String) return a == b;
    return identical(a, b) || (a == null && b == null) || (a is bool && a == b);
  }

  static bool looseEq(Object? a, Object? b) {
    if (a == null || b == null) return a == null && b == null;
    if ((a is num || a is bool || a is String) && (b is num || b is bool || b is String) && a.runtimeType != b.runtimeType) {
      return toNum(a) == toNum(b);
    }
    return strictEq(a, b);
  }

  num _norm(num n) => n is double && n == n.truncateToDouble() && n.isFinite && n.abs() < 9e15 ? n.toInt() : n;

  Object? binop(String op, Object? a, Object? b, int line) {
    switch (op) {
      case '+':
        if (a is String || b is String || a is List || b is List || a is Map || b is Map) {
          final s = str(a) + str(b);
          if (s.length > 4000000) throw ScriptError('string too long', line);
          return s;
        }
        return _norm(toNum(a) + toNum(b));
      case '-':
        return _norm(toNum(a) - toNum(b));
      case '*':
        return _norm(toNum(a) * toNum(b));
      case '/':
        final d = toNum(b);
        if (d == 0) {
          final n = toNum(a);
          return n == 0 ? double.nan : (n > 0 ? double.infinity : double.negativeInfinity);
        }
        return _norm(toNum(a) / d);
      case '%':
        final d = toNum(b);
        if (d == 0) return double.nan;
        return _norm(toNum(a).remainder(d));
      case '**':
        return _norm(math.pow(toNum(a), toNum(b)));
      case '===':
        return strictEq(a, b);
      case '!==':
        return !strictEq(a, b);
      case '==':
        return looseEq(a, b);
      case '!=':
        return !looseEq(a, b);
      case '<' || '>' || '<=' || '>=':
        final int c;
        if (a is String && b is String) {
          c = a.compareTo(b);
        } else {
          final x = toNum(a), y = toNum(b);
          if (x.isNaN || y.isNaN) return false;
          c = x.compareTo(y);
        }
        return switch (op) {
          '<' => c < 0,
          '>' => c > 0,
          '<=' => c <= 0,
          _ => c >= 0,
        };
      case 'in':
        if (b is Map) return b.containsKey(str(a));
        if (b is List) {
          final k = toNum(a);
          return k >= 0 && k < b.length;
        }
        throw ScriptError('"in" needs an object', line);
    }
    throw ScriptError('unknown operator $op', line);
  }

  Object? getProp(Object o, Object? key, int line) {
    final k = key is num ? key : str(key);
    if (o is Map) {
      if (o.containsKey(k is num ? str(k) : k)) return o[k is num ? str(k) : k];
      return null;
    }
    if (o is List) {
      if (k == 'length') return o.length;
      final idx = k is num ? k.toInt() : int.tryParse('$k');
      if (idx != null) return idx >= 0 && idx < o.length ? o[idx] : null;
      return Native('$k', (args) => _method(o, '$k', args, line));
    }
    if (o is String) {
      if (k == 'length') return o.length;
      final idx = k is num ? k.toInt() : int.tryParse('$k');
      if (idx != null) return idx >= 0 && idx < o.length ? o[idx] : null;
      return Native('$k', (args) => _method(o, '$k', args, line));
    }
    if (o is Closure && k == 'name') return o.name;
    if (o is num) return Native('$k', (args) => _method(o, '$k', args, line));
    return null;
  }

  Object? _fnArg(List<Object?> a, int i) => i < a.length ? a[i] : null;

  Object? _method(Object o, String name, List<Object?> a, int line) {
    Object? arg(int i) => _fnArg(a, i);
    if (o is num) {
      switch (name) {
        case 'toFixed':
          return o.toStringAsFixed(toNum(arg(0)).toInt().clamp(0, 20));
        case 'toString':
          return a.isEmpty ? str(o) : o.toInt().toRadixString(toNum(arg(0)).toInt().clamp(2, 36));
      }
      throw ScriptError('number has no method $name', line);
    }
    if (o is String) {
      switch (name) {
        case 'toUpperCase':
          return o.toUpperCase();
        case 'toLowerCase':
          return o.toLowerCase();
        case 'trim':
          return o.trim();
        case 'trimStart':
          return o.trimLeft();
        case 'trimEnd':
          return o.trimRight();
        case 'split':
          final sep = arg(0);
          if (sep == null) return [o];
          final parts = o.split(str(sep));
          if (str(sep).isEmpty) return o.split('');
          return parts;
        case 'includes':
          return o.contains(str(arg(0)));
        case 'startsWith':
          return o.startsWith(str(arg(0)));
        case 'endsWith':
          return o.endsWith(str(arg(0)));
        case 'indexOf':
          return o.indexOf(str(arg(0)));
        case 'lastIndexOf':
          return o.lastIndexOf(str(arg(0)));
        case 'slice' || 'substring':
          final n = o.length;
          int idx(Object? v, int dflt) {
            if (v == null) return dflt;
            var k = toNum(v).toInt();
            if (k < 0) k = name == 'slice' ? n + k : 0;
            return k.clamp(0, n);
          }
          var s = idx(arg(0), 0), e = idx(arg(1), n);
          if (name == 'substring' && s > e) (s, e) = (e, s);
          return s >= e ? '' : o.substring(s, e);
        case 'replace':
          return o.replaceFirst(str(arg(0)), str(arg(1)));
        case 'replaceAll':
          return o.replaceAll(str(arg(0)), str(arg(1)));
        case 'repeat':
          final n = toNum(arg(0)).toInt();
          if (n < 0 || n * o.length > 1000000) throw ScriptError('repeat count is too large', line);
          return o * n;
        case 'padStart':
          return o.padLeft(toNum(arg(0)).toInt().clamp(0, 10000), arg(1) == null ? ' ' : str(arg(1)));
        case 'padEnd':
          return o.padRight(toNum(arg(0)).toInt().clamp(0, 10000), arg(1) == null ? ' ' : str(arg(1)));
        case 'charAt':
          final k = toNum(arg(0)).toInt();
          return k >= 0 && k < o.length ? o[k] : '';
        case 'charCodeAt':
          final k = toNum(arg(0)).toInt();
          return k >= 0 && k < o.length ? o.codeUnitAt(k) : double.nan;
        case 'at':
          var k = toNum(arg(0)).toInt();
          if (k < 0) k += o.length;
          return k >= 0 && k < o.length ? o[k] : null;
        case 'toString':
          return o;
      }
      throw ScriptError('string has no method $name', line);
    }
    final l = o as List;
    switch (name) {
      case 'push':
        if (l.length + a.length > 1000000) throw ScriptError('array too long', line);
        l.addAll(a);
        return l.length;
      case 'pop':
        return l.isEmpty ? null : l.removeLast();
      case 'shift':
        return l.isEmpty ? null : l.removeAt(0);
      case 'unshift':
        l.insertAll(0, a);
        return l.length;
      case 'map':
        final f = arg(0);
        return [for (var k = 0; k < l.length; k++) callValue(f, [l[k], k, l], line)];
      case 'filter':
        final f = arg(0);
        return [
          for (var k = 0; k < l.length; k++)
            if (truthy(callValue(f, [l[k], k, l], line))) l[k],
        ];
      case 'forEach':
        final f = arg(0);
        for (var k = 0; k < l.length; k++) {
          callValue(f, [l[k], k, l], line);
        }
        return null;
      case 'find':
        for (var k = 0; k < l.length; k++) {
          if (truthy(callValue(arg(0), [l[k], k, l], line))) return l[k];
        }
        return null;
      case 'findIndex':
        for (var k = 0; k < l.length; k++) {
          if (truthy(callValue(arg(0), [l[k], k, l], line))) return k;
        }
        return -1;
      case 'some':
        for (var k = 0; k < l.length; k++) {
          if (truthy(callValue(arg(0), [l[k], k, l], line))) return true;
        }
        return false;
      case 'every':
        for (var k = 0; k < l.length; k++) {
          if (!truthy(callValue(arg(0), [l[k], k, l], line))) return false;
        }
        return true;
      case 'reduce':
        var k = 0;
        Object? acc;
        if (a.length > 1) {
          acc = a[1];
        } else {
          if (l.isEmpty) throw ScriptError('reduce of empty array with no start value', line);
          acc = l[0];
          k = 1;
        }
        for (; k < l.length; k++) {
          acc = callValue(arg(0), [acc, l[k], k, l], line);
        }
        return acc;
      case 'join':
        return l.map((e) => e == null ? '' : str(e)).join(arg(0) == null ? ',' : str(arg(0)));
      case 'includes':
        return l.any((e) => strictEq(e, arg(0)));
      case 'indexOf':
        return l.indexWhere((e) => strictEq(e, arg(0)));
      case 'slice':
        final n = l.length;
        int idx(Object? v, int dflt) {
          if (v == null) return dflt;
          var k = toNum(v).toInt();
          if (k < 0) k = n + k;
          return k.clamp(0, n);
        }
        final s = idx(arg(0), 0), e = idx(arg(1), n);
        return s >= e ? <Object?>[] : l.sublist(s, e);
      case 'splice':
        final n = l.length;
        var s = toNum(arg(0)).toInt();
        if (s < 0) s = (n + s).clamp(0, n);
        s = s.clamp(0, n);
        final count = a.length < 2 ? n - s : toNum(arg(1)).toInt().clamp(0, n - s);
        final removed = l.sublist(s, s + count);
        l.replaceRange(s, s + count, a.skip(2));
        return removed;
      case 'concat':
        return [
          ...l,
          for (final x in a)
            if (x is List) ...x else x,
        ];
      case 'reverse':
        final r = l.reversed.toList();
        l
          ..clear()
          ..addAll(r);
        return l;
      case 'sort':
        final f = arg(0);
        l.sort((x, y) {
          if (f != null) return toNum(callValue(f, [x, y], line)).sign.toInt();
          return str(x).compareTo(str(y));
        });
        return l;
      case 'flat':
        return [
          for (final x in l)
            if (x is List) ...x else x,
        ];
      case 'at':
        var k = toNum(arg(0)).toInt();
        if (k < 0) k += l.length;
        return k >= 0 && k < l.length ? l[k] : null;
      case 'toString':
        return str(l);
    }
    throw ScriptError('array has no method $name', line);
  }

  void _installGlobals() {
    final rnd = math.Random();
    void log(List<Object?> a) => onLog?.call(a.map(show).join(' '));
    define('console', _Frozen({
      'log': Native('console.log', (a) {
        log(a);
        return null;
      }),
      'warn': Native('console.warn', (a) {
        log(['warn:', ...a]);
        return null;
      }),
      'error': Native('console.error', (a) {
        log(['error:', ...a]);
        return null;
      }),
    }));
    num n(List<Object?> a, int i) => toNum(_fnArg(a, i));
    define('Math', _Frozen({
      'PI': math.pi,
      'E': math.e,
      'floor': Native('Math.floor', (a) => n(a, 0).floor()),
      'ceil': Native('Math.ceil', (a) => n(a, 0).ceil()),
      'round': Native('Math.round', (a) => (n(a, 0) + 0.5).floor()),
      'trunc': Native('Math.trunc', (a) => n(a, 0).truncate()),
      'abs': Native('Math.abs', (a) => n(a, 0).abs()),
      'sign': Native('Math.sign', (a) => n(a, 0).sign),
      'sqrt': Native('Math.sqrt', (a) => _norm(math.sqrt(n(a, 0)))),
      'pow': Native('Math.pow', (a) => _norm(math.pow(n(a, 0), n(a, 1)))),
      'log': Native('Math.log', (a) => math.log(n(a, 0))),
      'sin': Native('Math.sin', (a) => math.sin(n(a, 0))),
      'cos': Native('Math.cos', (a) => math.cos(n(a, 0))),
      'random': Native('Math.random', (a) => rnd.nextDouble()),
      'min': Native('Math.min', (a) => a.isEmpty ? double.infinity : a.map(toNum).reduce(math.min)),
      'max': Native('Math.max', (a) => a.isEmpty ? double.negativeInfinity : a.map(toNum).reduce(math.max)),
    }));
    define('JSON', _Frozen({
      'stringify': Native('JSON.stringify', (a) {
        final indent = _fnArg(a, 2);
        final enc = indent == null ? const JsonEncoder() : JsonEncoder.withIndent(' ' * toNum(indent).toInt().clamp(0, 8));
        return enc.convert(toJson(_fnArg(a, 0)));
      }),
      'parse': Native('JSON.parse', (a) {
        try {
          return fromJson(jsonDecode(str(_fnArg(a, 0))));
        } on FormatException catch (e) {
          throw ScriptThrow({'message': 'bad JSON: ${e.message}'});
        }
      }),
    }));
    define('Object', _Frozen({
      'keys': Native('Object.keys', (a) => _fnArg(a, 0) is Map ? (_fnArg(a, 0) as Map).keys.map((k) => '$k').toList() : <Object?>[]),
      'values': Native('Object.values', (a) => _fnArg(a, 0) is Map ? (_fnArg(a, 0) as Map).values.toList() : <Object?>[]),
      'entries': Native('Object.entries', (a) => _fnArg(a, 0) is Map
          ? [for (final e in (_fnArg(a, 0) as Map).entries) <Object?>['${e.key}', e.value]]
          : <Object?>[]),
      'assign': Native('Object.assign', (a) {
        final t = _fnArg(a, 0);
        if (t is! Map || t is _Frozen) throw ScriptError('Object.assign needs a plain object');
        for (final s in a.skip(1)) {
          if (s is Map) t.addAll(s.map((k, v) => MapEntry('$k', v)));
        }
        return t;
      }),
    }));
    define('Array', _Frozen({
      'isArray': Native('Array.isArray', (a) => _fnArg(a, 0) is List),
      'from': Native('Array.from', (a) {
        final s = _fnArg(a, 0);
        if (s is List) return List<Object?>.of(s);
        if (s is String) return s.split('');
        if (s is Map && s['length'] is num) {
          final len = toNum(s['length']).toInt().clamp(0, 100000);
          final f = _fnArg(a, 1);
          return [for (var k = 0; k < len; k++) f == null ? null : callValue(f, [null, k], 0)];
        }
        return <Object?>[];
      }),
    }));
    define('Date', _Frozen({'now': Native('Date.now', (a) => DateTime.now().millisecondsSinceEpoch)}));
    define('String', Native('String', (a) => a.isEmpty ? '' : str(a[0])));
    define('Number', Native('Number', (a) => a.isEmpty ? 0 : toNum(a[0])));
    define('Boolean', Native('Boolean', (a) => a.isNotEmpty && truthy(a[0])));
    define('parseInt', Native('parseInt', (a) {
      final m = RegExp(r'^\s*[-+]?\d+').firstMatch(str(_fnArg(a, 0)));
      return m == null ? double.nan : int.parse(m[0]!.trim());
    }));
    define('parseFloat', Native('parseFloat', (a) {
      final m = RegExp(r'^\s*[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?').firstMatch(str(_fnArg(a, 0)));
      return m == null ? double.nan : _norm(double.parse(m[0]!.trim()));
    }));
    define('isNaN', Native('isNaN', (a) => toNum(_fnArg(a, 0)).isNaN));
    define('NaN', double.nan);
    define('Infinity', double.infinity);
  }
}

/// A host object scripts can read but not change.
class _Frozen extends _ReadOnly<String, Object?> {
  _Frozen(super.map);
}

/// Wraps host maps so scripts cannot overwrite the API.
Map<String, Object?> frozen(Map<String, Object?> m) => _Frozen(m);

class _ReadOnly<K, V> implements Map<K, V> {
  _ReadOnly(this._m);
  final Map<K, V> _m;
  @override
  V? operator [](Object? key) => _m[key];
  @override
  void operator []=(K key, V value) => throw ScriptError('this object is read-only');
  @override
  void addAll(Map<K, V> other) => throw ScriptError('this object is read-only');
  @override
  void addEntries(Iterable<MapEntry<K, V>> newEntries) => throw ScriptError('this object is read-only');
  @override
  Map<RK, RV> cast<RK, RV>() => _m.cast<RK, RV>();
  @override
  void clear() => throw ScriptError('this object is read-only');
  @override
  bool containsKey(Object? key) => _m.containsKey(key);
  @override
  bool containsValue(Object? value) => _m.containsValue(value);
  @override
  Iterable<MapEntry<K, V>> get entries => _m.entries;
  @override
  void forEach(void Function(K key, V value) action) => _m.forEach(action);
  @override
  bool get isEmpty => _m.isEmpty;
  @override
  bool get isNotEmpty => _m.isNotEmpty;
  @override
  Iterable<K> get keys => _m.keys;
  @override
  int get length => _m.length;
  @override
  Map<K2, V2> map<K2, V2>(MapEntry<K2, V2> Function(K key, V value) convert) => _m.map(convert);
  @override
  V putIfAbsent(K key, V Function() ifAbsent) => throw ScriptError('this object is read-only');
  @override
  V? remove(Object? key) => throw ScriptError('this object is read-only');
  @override
  void removeWhere(bool Function(K key, V value) test) => throw ScriptError('this object is read-only');
  @override
  V update(K key, V Function(V value) update, {V Function()? ifAbsent}) => throw ScriptError('this object is read-only');
  @override
  void updateAll(V Function(K key, V value) update) => throw ScriptError('this object is read-only');
  @override
  Iterable<V> get values => _m.values;
}
