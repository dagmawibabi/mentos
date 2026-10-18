import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as c;
import 'package:flutter/material.dart';

import '../net/engine.dart';
import '../net/pay/coin.dart';
import 'script.dart';

/// What a plugin may ask for. Anything not granted throws when called.
const pluginPermissions = <String, (IconData, String)>{
  'theme': (Icons.palette_outlined, 'Change the app colors and text size'),
  'commands': (Icons.terminal_rounded, 'Add / commands to the chat composer'),
  'compose': (Icons.edit_note_rounded, 'Rewrite messages before you send them'),
  'messages.read': (Icons.mark_chat_unread_outlined, 'Read chat messages as they arrive'),
  'messages.send': (Icons.send_rounded, 'Send chat messages for you'),
  'chats.read': (Icons.forum_outlined, 'See your chat list'),
  'contacts.read': (Icons.people_outline_rounded, 'See your contacts\' names'),
  'wallet.read': (Icons.account_balance_wallet_outlined, 'See your coin balance'),
  'storage': (Icons.save_outlined, 'Keep its own settings on this device'),
  'notify': (Icons.notifications_none_rounded, 'Show notices in the app'),
  'net': (Icons.public_rounded, 'Fetch from the internet over https'),
  'ui': (Icons.dashboard_customize_outlined, 'Add its own pages, cards and a tab'),
  'layout': (Icons.view_quilt_outlined, 'Rearrange the app: tabs, sections and density'),
  'p2p': (Icons.device_hub_rounded, 'Message itself on your contacts\' devices'),
};

/// Where plugins are listed. Each is an index.json; see plugins/README.md.
const defaultRegistries = [
  'https://raw.githubusercontent.com/dagmawibabi/mentos/main/plugins/index.json',
  'https://raw.githubusercontent.com/dagmawibabi/mentossite/main/plugins/index.json',
];

class PluginManifest {
  const PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    this.author = '',
    this.description = '',
    this.icon = 'extension',
    this.permissions = const [],
    this.main = 'main.js',
    this.sha256,
    this.homepage,
  });

  final String id;
  final String name;
  final String version;
  final String author;
  final String description;
  final String icon;
  final List<String> permissions;
  final String main;

  /// Hex sha256 of the script. When present the download must match it.
  final String? sha256;
  final String? homepage;

  static final _idRe = RegExp(r'^[a-z0-9][a-z0-9-]{1,39}$');

  static PluginManifest parse(Object? j) {
    if (j is! Map) throw const FormatException('manifest is not an object');
    String s(String k, {String? dflt, int max = 200}) {
      final v = j[k];
      if (v == null && dflt != null) return dflt;
      if (v is! String || v.length > max) throw FormatException('manifest "$k" is missing or too long');
      return v;
    }

    final id = s('id', max: 40);
    if (!_idRe.hasMatch(id)) throw const FormatException('id must be lowercase letters, digits and dashes');
    final perms = j['permissions'] ?? const [];
    if (perms is! List || perms.any((p) => p is! String || !pluginPermissions.containsKey(p))) {
      throw FormatException('unknown permission in ${jsonEncode(perms)}');
    }
    final hash = j['sha256'];
    if (hash != null && (hash is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash))) {
      throw const FormatException('sha256 must be 64 hex characters');
    }
    final main = s('main', dflt: 'main.js', max: 120);
    if (main.contains('..') || main.startsWith('/')) throw const FormatException('main must be a relative path');
    return PluginManifest(
      id: id,
      name: s('name', max: 60),
      version: s('version', max: 20),
      author: s('author', dflt: '', max: 80),
      description: s('description', dflt: '', max: 400),
      icon: s('icon', dflt: 'extension', max: 40),
      permissions: perms.cast<String>().toSet().toList(),
      main: main,
      sha256: hash as String?,
      homepage: j['homepage'] is String ? j['homepage'] as String : null,
    );
  }

  /// Single-file plugins carry their manifest in a leading comment:
  /// `/* @plugin { "id": "...", "name": "...", ... } */`.
  static PluginManifest? fromHeader(String source) {
    final m = RegExp(r'^\s*/\*\s*@plugin\s*(\{[\s\S]*?\})\s*\*/').firstMatch(source);
    if (m == null) return null;
    return parse(jsonDecode(m[1]!));
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'author': author,
    'description': description,
    'icon': icon,
    'permissions': permissions,
    'main': main,
    'sha256': ?sha256,
    'homepage': ?homepage,
  };
}

class InstalledPlugin {
  InstalledPlugin({
    required this.manifest,
    required this.source,
    required this.origin,
    required this.installedAt,
    this.enabled = true,
  });

  final PluginManifest manifest;
  final String source;

  /// Manifest URL it came from, or "dev" / "file".
  final String origin;
  final int installedAt;
  bool enabled;

  String get id => manifest.id;

  Map<String, Object?> toJson() => {
    'm': manifest.toJson(),
    'src': source,
    'origin': origin,
    'at': installedAt,
    'on': enabled,
  };

  static InstalledPlugin? fromJson(Object? j) {
    try {
      if (j is! Map) return null;
      return InstalledPlugin(
        manifest: PluginManifest.parse(j['m']),
        source: j['src'] as String,
        origin: j['origin'] as String? ?? '',
        installedAt: (j['at'] as num?)?.toInt() ?? 0,
        enabled: j['on'] != false,
      );
    } catch (_) {
      return null;
    }
  }
}

/// A registry listing, before install.
class RegistryEntry {
  RegistryEntry({required this.manifest, required this.manifestUrl, required this.registry});
  final PluginManifest manifest;
  final Uri manifestUrl;
  final String registry;
}

class PluginLog {
  const PluginLog(this.ts, this.plugin, this.level, this.text);
  final int ts;
  final String plugin;
  final String level;
  final String text;
  Map<String, Object> toJson() => {'ts': ts, 'plugin': plugin, 'level': level, 'text': text};
}

class PluginCommand {
  const PluginCommand(this.plugin, this.name, this.description, this.fn);
  final String plugin;
  final String name;
  final String description;
  final Object? fn;
}

class PluginPage {
  PluginPage(this.plugin, this.id, this.title, this.icon, this.render);
  final String plugin;
  final String id;
  final String title;
  final String icon;
  final Object? render;
}

/// Palette changes a theme plugin asked for. Colors are ARGB.
class PluginTheme {
  const PluginTheme({this.light = const {}, this.dark = const {}, this.textScale});
  final Map<String, Color> light;
  final Map<String, Color> dark;
  final double? textScale;
  bool get isEmpty => light.isEmpty && dark.isEmpty && textScale == null;
}

/// How layout plugins want the app arranged. Later installs win.
class PluginLayout {
  const PluginLayout({this.hideTabs = const {}, this.hide = const {}, this.density, this.feedImages, this.navLabels});

  /// Bottom-bar tabs to hide: feed, wallet, network.
  final Set<String> hideTabs;

  /// Sections to hide: stories, composeButton, quickActions, marketBanner.
  final Set<String> hide;

  /// compact | comfortable
  final String? density;

  /// square | original
  final String? feedImages;
  final bool? navLabels;

  bool get isEmpty => hideTabs.isEmpty && hide.isEmpty && density == null && feedImages == null && navLabels == null;
}

/// A plugin's card inside one of the app's screens.
class PluginSlot {
  const PluginSlot(this.plugin, this.name, this.render);
  final String plugin;
  final String name;
  final Object? render;
}

/// A plugin page pinned to the bottom bar.
class PluginTab {
  const PluginTab(this.plugin, this.page, this.title, this.icon);
  final String plugin;
  final String page;
  final String title;
  final String icon;
}

class _Runtime {
  _Runtime(this.plugin, this.interp);
  final InstalledPlugin plugin;
  final Interp interp;
  final commands = <PluginCommand>[];
  final onSend = <Object?>[];
  final onMessage = <Object?>[];
  final pages = <PluginPage>[];
  final timers = <int, Timer>{};
  var nextTimer = 1;
  PluginTheme? theme;
  PluginLayout? layout;
  final slots = <String, PluginSlot>{};
  PluginTab? tab;
  final onPeer = <Object?>[];
  int inflight = 0;
  String? error;
  int errors = 0;

  void dispose() {
    for (final t in timers.values) {
      t.cancel();
    }
    timers.clear();
  }
}

typedef PluginFetch = Future<String> Function(Uri url);

/// Installs, stores and runs plugins for one identity. Plugins are scripts
/// fetched at runtime, so new ones need no app update.
class PluginHost {
  PluginHost(this.engine, {PluginFetch? fetch, this.toast}) : _fetch = fetch ?? _httpFetch {
    _load();
    _msgSub = engine.incoming.listen(_onIncoming);
    _appSub = engine.appMessages.where((m) => m.app.startsWith('plugin:')).listen(_onPeerMessage);
  }

  final Engine engine;
  final PluginFetch _fetch;

  /// Shows a notice from a plugin; set by the app shell.
  void Function(String plugin, String text)? toast;

  final _installed = <String, InstalledPlugin>{};
  final _runtimes = <String, _Runtime>{};
  final _logs = <PluginLog>[];
  final _changes = StreamController<void>.broadcast();
  StreamSubscription<Object?>? _msgSub;
  StreamSubscription<Object?>? _appSub;
  bool _closed = false;

  static const _kIndex = 'plugins:index';
  static const maxScript = 512 * 1024;

  Stream<void> get changes => _changes.stream;

  List<InstalledPlugin> get installed => _installed.values.toList()..sort((a, b) => a.manifest.name.toLowerCase().compareTo(b.manifest.name.toLowerCase()));

  InstalledPlugin? plugin(String id) => _installed[id];

  bool isRunning(String id) => _runtimes[id] != null && _runtimes[id]!.error == null;

  String? errorOf(String id) => _runtimes[id]?.error;

  List<PluginLog> logs({String? plugin, int since = 0}) => [
    for (final l in _logs)
      if ((plugin == null || l.plugin == plugin) && l.ts > since) l,
  ];

  List<PluginCommand> get commands => [for (final r in _runtimes.values) ...r.commands];

  List<PluginPage> get pages => [for (final r in _runtimes.values) ...r.pages];

  List<PluginPage> pagesOf(String id) => _runtimes[id]?.pages ?? const [];

  PluginPage? page(String plugin, String id) {
    for (final p in pagesOf(plugin)) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Where screens can host plugin cards.
  static const slotNames = ['feed.top', 'chats.top', 'profile.top', 'wallet.top', 'network.top'];

  List<_Runtime> get _byInstall => _runtimes.values.toList()..sort((a, b) => a.plugin.installedAt.compareTo(b.plugin.installedAt));

  /// Layout changes from every running layout plugin.
  PluginLayout get layout {
    final hideTabs = <String>{}, hide = <String>{};
    String? density, feedImages;
    bool? navLabels;
    for (final r in _byInstall) {
      final l = r.layout;
      if (l == null) continue;
      hideTabs.addAll(l.hideTabs);
      hide.addAll(l.hide);
      density = l.density ?? density;
      feedImages = l.feedImages ?? feedImages;
      navLabels = l.navLabels ?? navLabels;
    }
    return PluginLayout(hideTabs: hideTabs, hide: hide, density: density, feedImages: feedImages, navLabels: navLabels);
  }

  List<PluginSlot> slots(String name) => [
    for (final r in _byInstall)
      if (r.slots[name] != null) r.slots[name]!,
  ];

  /// Renders a slot's node tree; null hides the card.
  Object? renderSlot(PluginSlot s) {
    final r = _call(s.plugin, s.render, const []);
    return r.$1 ? r.$2 : null;
  }

  /// Plugin pages pinned to the bottom bar, at most two.
  List<PluginTab> get tabs => [
    for (final r in _byInstall)
      if (r.tab != null && r.pages.any((pg) => pg.id == r.tab!.page)) r.tab!,
  ].take(2).toList();

  void _onPeerMessage(({String from, String app, Map<String, dynamic> m}) msg) {
    final id = msg.app.substring('plugin:'.length);
    final rt = _runtimes[id];
    if (rt == null || rt.onPeer.isEmpty) return;
    final data = {'from': msg.from, 'name': engine.nameOf(msg.from), 'data': Interp.fromJson(msg.m['d'])};
    for (final fn in rt.onPeer.toList()) {
      _call(id, fn, [Map<String, Object?>.of(data)]);
    }
    _changed();
  }

  /// Every running theme plugin, later installs winning.
  PluginTheme get theme {
    final light = <String, Color>{}, dark = <String, Color>{};
    double? scale;
    final list = _runtimes.values.where((r) => r.theme != null).toList()
      ..sort((a, b) => a.plugin.installedAt.compareTo(b.plugin.installedAt));
    for (final r in list) {
      light.addAll(r.theme!.light);
      dark.addAll(r.theme!.dark);
      scale = r.theme!.textScale ?? scale;
    }
    return PluginTheme(light: light, dark: dark, textScale: scale);
  }

  void dispose() {
    _closed = true;
    unawaited(_msgSub?.cancel());
    unawaited(_appSub?.cancel());
    for (final r in _runtimes.values) {
      r.dispose();
    }
    _runtimes.clear();
    unawaited(_changes.close());
  }

  void _changed() {
    if (!_closed && !_changes.isClosed) _changes.add(null);
  }

  void log(String plugin, String level, String text) {
    _logs.add(PluginLog(DateTime.now().millisecondsSinceEpoch, plugin, level, text.length > 2000 ? '${text.substring(0, 2000)}…' : text));
    if (_logs.length > 500) _logs.removeRange(0, _logs.length - 500);
    _changed();
  }

  // ------------------------------------------------------------ storage

  void _load() {
    try {
      final ids = (jsonDecode(engine.db.getKv(_kIndex) ?? '[]') as List).cast<String>();
      for (final id in ids) {
        final p = InstalledPlugin.fromJson(jsonDecode(engine.db.getKv('plugin:$id') ?? 'null'));
        if (p != null) _installed[p.id] = p;
      }
    } catch (_) {}
    for (final p in _installed.values) {
      if (p.enabled) _start(p);
    }
  }

  void _save(InstalledPlugin p) {
    engine.db.setKv('plugin:${p.id}', jsonEncode(p.toJson()));
    engine.db.setKv(_kIndex, jsonEncode(_installed.keys.toList()));
  }

  // ------------------------------------------------------------ install

  /// Fetches a manifest and its script without installing, so the person
  /// can review the permissions first.
  Future<(PluginManifest, String)> fetchPackage(Uri manifestUrl, {String? pinnedSha}) async {
    final manifest = PluginManifest.parse(jsonDecode(await _fetch(manifestUrl)));
    final source = await _fetch(manifestUrl.resolve(manifest.main));
    if (source.length > maxScript) throw const FormatException('script is too large');
    final sum = c.sha256.convert(utf8.encode(source)).toString();
    for (final want in [manifest.sha256, pinnedSha]) {
      if (want != null && want != sum) throw const FormatException('the script does not match its published checksum');
    }
    return (manifest, source);
  }

  /// Checks a script parses before it is stored.
  static String? check(String source) {
    try {
      Interp.validate(source);
      return null;
    } on ScriptError catch (e) {
      return e.toString();
    }
  }

  InstalledPlugin install(PluginManifest m, String source, {required String origin}) {
    final err = check(source);
    if (err != null) throw FormatException('script error: $err');
    final old = _installed[m.id];
    _stop(m.id);
    final p = InstalledPlugin(
      manifest: m,
      source: source,
      origin: origin,
      installedAt: old?.installedAt ?? DateTime.now().millisecondsSinceEpoch,
      enabled: old?.enabled ?? true,
    );
    _installed[m.id] = p;
    _save(p);
    log(m.id, 'info', old == null ? 'installed ${m.version}' : 'updated ${old.manifest.version} → ${m.version}');
    if (p.enabled) _start(p);
    _changed();
    return p;
  }

  Future<InstalledPlugin> installFrom(Uri manifestUrl, {String? pinnedSha}) async {
    final (m, src) = await fetchPackage(manifestUrl, pinnedSha: pinnedSha);
    return install(m, src, origin: manifestUrl.toString());
  }

  void uninstall(String id) {
    _stop(id);
    _installed.remove(id);
    engine.db.deleteKv('plugin:$id');
    for (final k in engine.db.kvKeys('pls:$id:')) {
      engine.db.deleteKv(k);
    }
    engine.db.setKv(_kIndex, jsonEncode(_installed.keys.toList()));
    log(id, 'info', 'removed');
    _changed();
  }

  void setEnabled(String id, bool on) {
    final p = _installed[id];
    if (p == null) return;
    p.enabled = on;
    _save(p);
    if (on) {
      _start(p);
    } else {
      _stop(id);
    }
    _changed();
  }

  /// Restarts a plugin from its stored script, for development.
  void reload(String id) {
    final p = _installed[id];
    if (p == null) return;
    _stop(id);
    if (p.enabled) _start(p);
    _changed();
  }

  // ------------------------------------------------------------ registry

  List<String> get registries {
    try {
      final extra = (jsonDecode(engine.db.getKv('plugins:registries') ?? '[]') as List).cast<String>();
      return [...defaultRegistries, ...extra.where((u) => !defaultRegistries.contains(u))];
    } catch (_) {
      return defaultRegistries;
    }
  }

  List<String> get customRegistries => registries.where((r) => !defaultRegistries.contains(r)).toList();

  void addRegistry(String url) {
    final list = {...customRegistries, url}.toList();
    engine.db.setKv('plugins:registries', jsonEncode(list));
    _changed();
  }

  void removeRegistry(String url) {
    engine.db.setKv('plugins:registries', jsonEncode(customRegistries.where((u) => u != url).toList()));
    _changed();
  }

  /// Every plugin the registries list. Registries that fail are reported in
  /// [failed] and skipped.
  Future<({List<RegistryEntry> entries, Map<String, String> failed})> browse() async {
    final out = <String, RegistryEntry>{};
    final failed = <String, String>{};
    await Future.wait([
      for (final reg in registries)
        () async {
          try {
            final base = Uri.parse(reg);
            final j = jsonDecode(await _fetch(base));
            final list = j is Map ? j['plugins'] : j;
            if (list is! List) throw const FormatException('no "plugins" list');
            for (final raw in list.take(500)) {
              try {
                final m = PluginManifest.parse(raw);
                final at = (raw as Map)['manifest'];
                final url = base.resolve(at is String ? at : '${m.id}/plugin.json');
                out.putIfAbsent(m.id, () => RegistryEntry(manifest: m, manifestUrl: url, registry: reg));
              } catch (_) {}
            }
          } catch (e) {
            failed[reg] = '$e';
          }
        }(),
    ]);
    return (entries: out.values.toList()..sort((a, b) => a.manifest.name.compareTo(b.manifest.name)), failed: failed);
  }

  // ------------------------------------------------------------ hooks

  /// A chat line starting with "/name". Returns null when no plugin owns the
  /// command; otherwise the text to send instead, which may be empty.
  String? runCommand(String text, String scope) {
    final m = RegExp(r'^/([a-zA-Z0-9_-]+)\s*([\s\S]*)$').firstMatch(text.trim());
    if (m == null) return null;
    final name = m[1]!.toLowerCase();
    for (final cmd in commands) {
      if (cmd.name != name) continue;
      final r = _call(cmd.plugin, cmd.fn, [m[2]!.trim(), {'scope': scope}]);
      if (r.$1) return r.$2 == null ? '' : Interp.str(r.$2);
      return '';
    }
    return null;
  }

  /// Passes outgoing text through every compose hook.
  String transformOutgoing(String text, String scope) {
    var out = text;
    for (final r in _runtimes.values.toList()) {
      for (final fn in r.onSend) {
        final res = _call(r.plugin.id, fn, [out, {'scope': scope}]);
        if (res.$1 && res.$2 is String) out = res.$2 as String;
      }
    }
    return out;
  }

  void _onIncoming(({String id, String scope, String author, String text}) m) {
    final msg = {'id': m.id, 'scope': m.scope, 'from': m.author, 'name': engine.nameOf(m.author), 'text': m.text};
    for (final r in _runtimes.values.toList()) {
      for (final fn in r.onMessage) {
        _call(r.plugin.id, fn, [Map<String, Object?>.of(msg)]);
      }
    }
  }

  /// Calls back into a plugin from the UI. Returns false when it failed.
  bool callback(String plugin, Object? fn, [List<Object?> args = const []]) {
    final ok = _call(plugin, fn, args).$1;
    _changed();
    return ok;
  }

  /// Renders a page's node tree, or an error node.
  Object? render(PluginPage p) {
    final r = _call(p.plugin, p.render, const []);
    if (!r.$1) return {'type': 'text', 'text': 'This page failed: ${_runtimes[p.plugin]?.error ?? 'see logs'}', 'style': 'error'};
    return r.$2;
  }

  (bool, Object?) _call(String plugin, Object? fn, List<Object?> args) {
    final rt = _runtimes[plugin];
    if (rt == null || fn == null) return (false, null);
    try {
      return (true, rt.interp.invoke(fn, args));
    } on ScriptError catch (e) {
      rt.errors++;
      log(plugin, 'error', '$e');
      return (false, null);
    } catch (e) {
      rt.errors++;
      log(plugin, 'error', '$e');
      return (false, null);
    }
  }

  // ------------------------------------------------------------ runtime

  void _stop(String id) {
    final r = _runtimes.remove(id);
    r?.dispose();
  }

  void _start(InstalledPlugin p) {
    _stop(p.id);
    final interp = Interp(stepBudget: 1500000, onLog: (l) => log(p.id, 'log', l));
    final rt = _Runtime(p, interp);
    _runtimes[p.id] = rt;
    interp.define('mentos', _api(rt));
    try {
      interp.run(p.source);
      log(p.id, 'info', 'started');
    } on ScriptError catch (e) {
      rt.error = e.toString();
      rt.dispose();
      log(p.id, 'error', 'failed to start: $e');
    }
    _changed();
  }

  Map<String, Object?> _api(_Runtime rt) {
    final p = rt.plugin;
    final id = p.id;
    final granted = p.manifest.permissions.toSet();
    NativeFn need(String perm, NativeFn fn) => (a) {
      if (!granted.contains(perm)) throw ScriptError('${p.manifest.name} needs the "$perm" permission');
      return fn(a);
    };
    Object? arg(List<Object?> a, int i) => i < a.length ? a[i] : null;
    String sArg(List<Object?> a, int i) => Interp.str(arg(a, i) ?? '');

    return frozen({
      'plugin': frozen({'id': id, 'name': p.manifest.name, 'version': p.manifest.version, 'permissions': [...granted]}),
      'log': Native('log', (a) {
        log(id, 'log', a.map(Interp.show).join(' '));
        return null;
      }),
      'me': Native('me', (a) => {'id': engine.me.id, 'name': engine.myProfile.name}),
      'notify': Native('notify', need('notify', (a) {
        toast?.call(p.manifest.name, sArg(a, 0));
        log(id, 'notice', sArg(a, 0));
        return null;
      })),
      'theme': frozen({
        'set': Native('theme.set', need('theme', (a) {
          rt.theme = _parseTheme(arg(a, 0));
          _changed();
          return null;
        })),
        'reset': Native('theme.reset', need('theme', (a) {
          rt.theme = null;
          _changed();
          return null;
        })),
      }),
      'commands': frozen({
        'add': Native('commands.add', need('commands', (a) {
          final name = sArg(a, 0).toLowerCase().replaceAll('/', '');
          if (!RegExp(r'^[a-z0-9_-]{1,24}$').hasMatch(name)) throw ScriptError('command names are 1-24 letters, digits, _ or -');
          final fn = arg(a, 2) ?? arg(a, 1);
          final desc = arg(a, 2) == null ? '' : sArg(a, 1);
          rt.commands
            ..removeWhere((c) => c.name == name)
            ..add(PluginCommand(id, name, desc, fn));
          _changed();
          return null;
        })),
      }),
      'compose': frozen({
        'onSend': Native('compose.onSend', need('compose', (a) {
          rt.onSend.add(arg(a, 0));
          return null;
        })),
      }),
      'on': Native('on', (a) {
        final ev = sArg(a, 0);
        if (ev != 'message') throw ScriptError('unknown event "$ev"; try "message"');
        if (!granted.contains('messages.read')) throw ScriptError('${p.manifest.name} needs the "messages.read" permission');
        rt.onMessage.add(arg(a, 1));
        return null;
      }),
      'chats': frozen({
        'list': Native('chats.list', need('chats.read', (a) => [
          for (final ch in engine.chats().take(200))
            {
              'scope': ch.scope,
              'title': ch.group ? ch.title : engine.nameOf(ch.peer),
              'peer': ch.peer,
              'group': ch.group,
              'unread': ch.unread,
              'last': ch.last?.text ?? '',
            },
        ])),
        'send': Native('chats.send', need('messages.send', (a) {
          final scope = sArg(a, 0), text = sArg(a, 1);
          if (!scope.startsWith('dm:') && !scope.startsWith('gdm:')) throw ScriptError('chats.send needs a chat scope');
          if (text.trim().isEmpty || text.length > 4000) throw ScriptError('message must be 1-4000 characters');
          unawaited(engine.sendMessage(scope, text: text).then((_) {}, onError: (Object e) => log(id, 'error', 'send failed: $e')));
          return null;
        })),
      }),
      'contacts': frozen({
        'name': Native('contacts.name', need('contacts.read', (a) => engine.nameOf(sArg(a, 0)))),
      }),
      'wallet': frozen({
        'balance': Native('wallet.balance', need('wallet.read', (a) {
          final b = engine.coin?.balance() ?? 0;
          return {'minor': b, 'mentos': Coin.format(b)};
        })),
      }),
      'storage': frozen({
        'get': Native('storage.get', need('storage', (a) {
          final raw = engine.db.getKv('pls:$id:${sArg(a, 0)}');
          if (raw == null) return arg(a, 1);
          return Interp.fromJson(jsonDecode(raw));
        })),
        'set': Native('storage.set', need('storage', (a) {
          final k = sArg(a, 0);
          final v = jsonEncode(Interp.toJson(arg(a, 1)));
          if (k.isEmpty || k.length > 100 || v.length > 64 * 1024) throw ScriptError('keys are 1-100 characters and values under 64 KB');
          if (engine.db.kvKeys('pls:$id:').length > 500) throw ScriptError('storage is full (500 keys)');
          engine.db.setKv('pls:$id:$k', v);
          return null;
        })),
        'remove': Native('storage.remove', need('storage', (a) {
          engine.db.deleteKv('pls:$id:${sArg(a, 0)}');
          return null;
        })),
        'keys': Native('storage.keys', need('storage', (a) => [for (final k in engine.db.kvKeys('pls:$id:')) k.substring('pls:$id:'.length)])),
      }),
      'http': frozen({
        'get': Native('http.get', need('net', (a) {
          _http(rt, {'method': 'GET', 'url': sArg(a, 0)}, arg(a, 1));
          return null;
        })),
        'post': Native('http.post', need('net', (a) {
          _http(rt, {'method': 'POST', 'url': sArg(a, 0), 'body': arg(a, 1)}, arg(a, 2));
          return null;
        })),
        'request': Native('http.request', need('net', (a) {
          final o = arg(a, 0);
          if (o is! Map) throw ScriptError('http.request needs {url, method, headers, body}');
          _http(rt, o, arg(a, 1));
          return null;
        })),
      }),
      'peers': frozen({
        'list': Native('peers.list', need('p2p', (a) => [
          for (final pe in engine.people())
            if (!pe.blocked && pe.id != engine.me.id) {'id': pe.id, 'name': pe.name, 'online': engine.isOnline(pe.id)},
        ])),
        'send': Native('peers.send', need('p2p', (a) {
          final to = sArg(a, 0);
          final data = Interp.toJson(arg(a, 1));
          if (to.length != 64) throw ScriptError('peers.send needs a contact id');
          if (jsonEncode(data).length > 32 * 1024) throw ScriptError('messages are limited to 32 KB');
          if (engine.db.peer(to) == null) throw ScriptError('you can only message your contacts');
          unawaited(engine.sendApp(to, 'plugin:$id', {'d': data}).then((_) {}, onError: (Object e) => log(id, 'error', 'peers.send: $e')));
          return null;
        })),
        'on': Native('peers.on', need('p2p', (a) {
          rt.onPeer.add(arg(a, 0));
          return null;
        })),
      }),
      'layout': frozen({
        'set': Native('layout.set', need('layout', (a) {
          final o = arg(a, 0);
          if (o is! Map) throw ScriptError('layout.set needs an object like {hideTabs: ["wallet"]}');
          Set<String> pick(Object? v, Set<String> allowed) => {
            for (final x in (v is List ? v : const [])) if (allowed.contains('$x')) '$x',
          };
          final density = o['density'];
          final images = o['feedImages'];
          rt.layout = PluginLayout(
            hideTabs: pick(o['hideTabs'], const {'feed', 'wallet', 'network'}),
            hide: pick(o['hide'], const {'stories', 'composeButton', 'quickActions', 'marketBanner'}),
            density: density == 'compact' || density == 'comfortable' ? density as String : null,
            feedImages: images == 'square' || images == 'original' ? images as String : null,
            navLabels: o['navLabels'] is bool ? o['navLabels'] as bool : null,
          );
          _changed();
          return null;
        })),
        'reset': Native('layout.reset', need('layout', (a) {
          rt.layout = null;
          _changed();
          return null;
        })),
      }),
      'ui': frozen({
        'page': Native('ui.page', need('ui', (a) {
          final o = arg(a, 0);
          if (o is! Map) throw ScriptError('ui.page needs {title, render}');
          final pid = Interp.str(o['id'] ?? 'main');
          rt.pages
            ..removeWhere((x) => x.id == pid)
            ..add(PluginPage(id, pid, Interp.str(o['title'] ?? p.manifest.name), Interp.str(o['icon'] ?? p.manifest.icon), o['render']));
          _changed();
          return null;
        })),
        'slot': Native('ui.slot', need('ui', (a) {
          final name = sArg(a, 0);
          if (!slotNames.contains(name)) throw ScriptError('slots are ${slotNames.join(', ')}');
          if (arg(a, 1) == null) {
            rt.slots.remove(name);
          } else {
            rt.slots[name] = PluginSlot(id, name, arg(a, 1));
          }
          _changed();
          return null;
        })),
        'tab': Native('ui.tab', need('ui', (a) {
          final o = arg(a, 0);
          if (o == null) {
            rt.tab = null;
          } else {
            if (o is! Map) throw ScriptError('ui.tab needs {title, icon, page}');
            rt.tab = PluginTab(id, Interp.str(o['page'] ?? 'main'), Interp.str(o['title'] ?? p.manifest.name), Interp.str(o['icon'] ?? p.manifest.icon));
          }
          _changed();
          return null;
        })),
        'refresh': Native('ui.refresh', (a) {
          _changed();
          return null;
        }),
      }),
      'timer': frozen({
        'after': Native('timer.after', (a) => _timer(rt, Interp.toNum(arg(a, 0)), arg(a, 1), repeat: false)),
        'every': Native('timer.every', (a) => _timer(rt, Interp.toNum(arg(a, 0)), arg(a, 1), repeat: true)),
        'cancel': Native('timer.cancel', (a) {
          rt.timers.remove(Interp.toNum(arg(a, 0)).toInt())?.cancel();
          return null;
        }),
      }),
    });
  }

  int _timer(_Runtime rt, num seconds, Object? fn, {required bool repeat}) {
    if (rt.timers.length >= 20) throw ScriptError('a plugin can keep at most 20 timers');
    final min = repeat ? 5 : 0.05;
    final ms = (seconds.clamp(min, 86400) * 1000).round();
    final tid = rt.nextTimer++;
    void fire() {
      if (_runtimes[rt.plugin.id] != rt) return;
      if (!repeat) rt.timers.remove(tid);
      _call(rt.plugin.id, fn, const []);
      _changed();
    }

    rt.timers[tid] = repeat ? Timer.periodic(Duration(milliseconds: ms), (_) => fire()) : Timer(Duration(milliseconds: ms), fire);
    return tid;
  }

  void _http(_Runtime rt, Map o, Object? cb) {
    final url = Interp.str(o['url'] ?? '');
    final method = Interp.str(o['method'] ?? 'GET').toUpperCase();
    final body = o['body'];
    final headers = o['headers'] is Map ? o['headers'] as Map : const {};
    final timeout = Duration(seconds: Interp.toNum(o['timeout'] ?? 20).toInt().clamp(1, 60));
    final u = Uri.tryParse(url);
    final local = u != null && (u.host == 'localhost' || u.host == '127.0.0.1');
    if (u == null || u.host.isEmpty || (u.scheme != 'https' && !(u.scheme == 'http' && local))) {
      throw ScriptError('http needs an https:// URL');
    }
    if (!const {'GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD'}.contains(method)) throw ScriptError('unsupported method $method');
    if (rt.inflight >= 6) throw ScriptError('at most 6 requests at a time');
    rt.inflight++;
    unawaited(() async {
      Map<String, Object?> res;
      final watch = Stopwatch()..start();
      try {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
        try {
          final req = await client.openUrl(method, u);
          req.headers.set('user-agent', 'Mentos-plugin/${rt.plugin.id}');
          for (final e in headers.entries) {
            final k = '${e.key}'.toLowerCase();
            if (const {'host', 'cookie', 'content-length'}.contains(k)) continue;
            req.headers.set(k, Interp.str(e.value));
          }
          if (body != null && method != 'GET' && method != 'HEAD') {
            final text = body is String ? body : jsonEncode(Interp.toJson(body));
            if (req.headers.contentType == null) req.headers.contentType = body is String ? ContentType.text : ContentType.json;
            req.write(text);
          }
          final resp = await req.close().timeout(timeout);
          final bytes = <int>[];
          await for (final chunk in resp.timeout(timeout)) {
            bytes.addAll(chunk);
            if (bytes.length > 2 * 1024 * 1024) throw const HttpException('response is over 2 MB');
          }
          final text = utf8.decode(bytes, allowMalformed: true);
          Object? json;
          try {
            json = Interp.fromJson(jsonDecode(text));
          } catch (_) {}
          final outHeaders = <String, Object?>{};
          resp.headers.forEach((k, v) => outHeaders[k] = v.join(', '));
          res = {
            'ok': resp.statusCode >= 200 && resp.statusCode < 300,
            'status': resp.statusCode,
            'headers': outHeaders,
            'body': text,
            'json': json,
            'ms': watch.elapsedMilliseconds,
          };
        } finally {
          client.close(force: true);
        }
      } catch (e) {
        res = {'ok': false, 'status': 0, 'headers': const <String, Object?>{}, 'body': '', 'json': null, 'error': '$e', 'ms': watch.elapsedMilliseconds};
      } finally {
        rt.inflight--;
      }
      if (_runtimes[rt.plugin.id] != rt) return;
      _call(rt.plugin.id, cb, [res]);
      _changed();
    }());
  }

  static Color? _color(Object? v) {
    if (v is! String) return null;
    final h = v.replaceFirst('#', '');
    if (!RegExp(r'^([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$').hasMatch(h)) return null;
    return Color(int.parse(h.length == 6 ? 'FF$h' : h, radix: 16));
  }

  static const themeKeys = [
    'bg', 'surface', 'raised', 'line', 'ink', 'inkSoft', 'muted', 'faint',
    'accent', 'accentInk', 'accentSoft', 'danger', 'bubbleMine', 'bubbleMineInk',
  ];

  static PluginTheme _parseTheme(Object? o) {
    if (o is! Map) throw ScriptError('theme.set needs an object like {accent: "#ff5500"}');
    Map<String, Color> read(Object? m) {
      final out = <String, Color>{};
      if (m is! Map) return out;
      for (final k in themeKeys) {
        final c = _color(m[k]);
        if (c != null) out[k] = c;
      }
      return out;
    }

    final both = read(o);
    final scale = o['textScale'];
    return PluginTheme(
      light: {...both, ...read(o['light'])},
      dark: {...both, ...read(o['dark'])},
      textScale: scale is num ? scale.toDouble().clamp(0.8, 1.4) : null,
    );
  }
}

Future<String> _httpFetch(Uri url) async {
  final local = url.host == 'localhost' || url.host == '127.0.0.1';
  if (url.scheme != 'https' && !(url.scheme == 'http' && local)) {
    throw const FormatException('plugins are fetched over https only');
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(url);
    final resp = await req.close().timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) throw HttpException('HTTP ${resp.statusCode}', uri: url);
    final bytes = <int>[];
    await for (final chunk in resp.timeout(const Duration(seconds: 20))) {
      bytes.addAll(chunk);
      if (bytes.length > PluginHost.maxScript * 2) throw const HttpException('file is too large');
    }
    return utf8.decode(bytes);
  } finally {
    client.close(force: true);
  }
}
