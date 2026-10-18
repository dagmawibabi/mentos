import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../net/market/listing.dart';
import '../../net/pay/coin.dart';
import '../../state/providers.dart';
import '../market/market_kit.dart';
import '../../plugins/plugin_providers.dart';
import '../../plugins/plugins.dart';
import '../../plugins/script.dart';
import '../../widgets/input_sheet.dart';
import '../../widgets/ui.dart';

IconData pluginIcon(String name) => switch (name) {
  'palette' || 'theme' => Icons.palette_outlined,
  'casino' || 'dice' => Icons.casino_outlined,
  'translate' => Icons.translate_rounded,
  'bolt' => Icons.bolt_rounded,
  'sparkle' || 'auto_awesome' => Icons.auto_awesome_outlined,
  'chat' => Icons.chat_bubble_outline_rounded,
  'timer' || 'schedule' => Icons.schedule_rounded,
  'calculate' => Icons.calculate_outlined,
  'music' => Icons.music_note_outlined,
  'brush' => Icons.brush_outlined,
  'code' => Icons.code_rounded,
  'star' => Icons.star_outline_rounded,
  'heart' || 'favorite' => Icons.favorite_outline_rounded,
  'public' || 'globe' => Icons.public_rounded,
  'shield' => Icons.shield_outlined,
  'robot' || 'bot' => Icons.smart_toy_outlined,
  'wallet' => Icons.account_balance_wallet_outlined,
  'cloud' => Icons.cloud_outlined,
  'sun' => Icons.wb_sunny_outlined,
  'moon' => Icons.dark_mode_outlined,
  'text' => Icons.text_fields_rounded,
  'emoji' => Icons.emoji_emotions_outlined,
  'away' || 'reply' => Icons.reply_all_rounded,
  'note' => Icons.sticky_note_2_outlined,
  _ => Icons.extension_outlined,
};

Color _tint(String id) {
  const colors = [Color(0xFF0E9F6E), Color(0xFF2563EB), Color(0xFFD97706), Color(0xFF8B5CF6), Color(0xFFDB2777), Color(0xFF0891B2)];
  return colors[id.codeUnits.fold<int>(0, (a, b) => a + b) % colors.length];
}

class PluginIcon extends StatelessWidget {
  const PluginIcon(this.manifest, {super.key, this.size = 44});
  final PluginManifest manifest;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = _tint(manifest.id);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: t.withValues(alpha: .14), borderRadius: BorderRadius.circular(size * .3)),
      child: Icon(pluginIcon(manifest.icon), color: t, size: size * .5),
    );
  }
}

/// Kept for old links; plugins live in the market's Plugins tab.
class PluginsScreen extends StatelessWidget {
  const PluginsScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Plugins')),
    body: ListView(padding: const EdgeInsets.only(bottom: Space.xxl), children: const [PluginStore()]),
  );
}

/// The plugin marketplace: discover (registries and network listings),
/// what's installed, and every way to add one.
class PluginStore extends ConsumerStatefulWidget {
  const PluginStore({super.key, this.query = ''});
  final String query;

  @override
  ConsumerState<PluginStore> createState() => _PluginStoreState();
}

class _PluginStoreState extends ConsumerState<PluginStore> {
  var _tab = 'discover';
  Future<({List<RegistryEntry> entries, Map<String, String> failed})>? _browse;

  void _refresh() {
    final host = ref.read(pluginHostProvider);
    if (host == null) return;
    final next = host.browse();
    setState(() {
      _browse = next;
    });
  }

  bool _match(String text) => widget.query.isEmpty || text.toLowerCase().contains(widget.query);

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    ref.watch(pluginTickProvider);
    ref.watch(marketTickProvider);
    final host = ref.watch(pluginHostProvider);
    if (host == null) return const Padding(padding: EdgeInsets.only(top: Space.xxl), child: Loading());
    final market = ref.watch(marketProvider);
    final installed = host.installed.where((x) => _match('${x.manifest.name} ${x.manifest.description}')).toList();
    _browse ??= host.browse();
    final listed = [
      for (final l in market?.pluginListings() ?? const <Listing>[])
        if (_match(l.haystack)) l,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
          child: Container(
            padding: const EdgeInsets.all(Space.lg),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [p.accentSoft, p.surface],
              ),
              border: Border.all(color: p.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(color: p.accent, borderRadius: BorderRadius.circular(12)),
                      child: Icon(Icons.extension_rounded, color: p.accentInk, size: 22),
                    ),
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Make Mentos yours', style: Txt.bodyStrong(p.ink)),
                          Text(
                            '${host.installed.length} installed · ${host.commands.length} commands · ${host.pages.length} pages',
                            style: Txt.small(p.muted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.md),
                Text(
                  'Plugins add commands, themes, pages and automations. They install instantly, run in a sandbox and only get the permissions you approve.',
                  style: Txt.small(p.inkSoft),
                ),
                const SizedBox(height: Space.md),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _Action(Icons.link_rounded, 'From a link', () => _fromLink(host)),
                      _Action(Icons.file_open_outlined, 'From a file', () => _fromFile(host)),
                      _Action(Icons.hub_outlined, 'Registries', () => _registries(host)),
                      _Action(Icons.publish_rounded, 'List yours', () => context.push('/market/sell/plugin')),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
          child: Segmented<String>(
            value: _tab,
            options: {'discover': 'Discover', 'installed': 'Installed  ${host.installed.length}'},
            onChanged: (v) => setState(() => _tab = v),
          ),
        ),
        if (_tab == 'installed') ...[
          if (installed.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Space.xl),
              child: EmptyState(
                icon: Icons.extension_outlined,
                title: widget.query.isEmpty ? 'No plugins yet' : 'No installed plugin matches',
                body: widget.query.isEmpty ? 'Find one in Discover, or install from a link or a file.' : null,
                compact: true,
                action: widget.query.isEmpty
                    ? FilledButton(onPressed: () => setState(() => _tab = 'discover'), child: const Text('Discover plugins'))
                    : null,
              ),
            )
          else ...[
            SectionLabel('On this device'),
            for (final pl in installed) _InstalledRow(pl),
          ],
          if (host.pages.isNotEmpty) ...[
            SectionLabel('Plugin pages'),
            for (final pg in host.pages)
              RowTile(
                icon: pluginIcon(pg.icon),
                title: pg.title,
                subtitle: host.plugin(pg.plugin)?.manifest.name == pg.title ? null : host.plugin(pg.plugin)?.manifest.name,
                onTap: () => context.push('/plugins/${pg.plugin}/page/${pg.id}'),
              ),
          ],
        ] else ...[
          FutureBuilder(
            future: _browse,
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Padding(padding: EdgeInsets.symmetric(vertical: Space.xl), child: Loading());
              }
              final r = snap.data!;
              final entries = r.entries.where((en) => _match('${en.manifest.name} ${en.manifest.description} ${en.manifest.author}')).toList();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SectionLabel(
                    'From the registries',
                    trailing: GestureDetector(onTap: _refresh, child: Icon(Icons.refresh_rounded, size: 16, color: p.muted)),
                  ),
                  if (entries.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
                      child: Text(
                        r.failed.isNotEmpty && r.entries.isEmpty ? 'Couldn\'t reach the plugin registries. Pull to try again later.' : 'Nothing matches.',
                        style: Txt.small(p.muted),
                      ),
                    ),
                  for (final en in entries) _RegistryRow(en),
                  if (r.failed.isNotEmpty && r.entries.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(Space.gutter, Space.xs, Space.gutter, 0),
                      child: Text('${r.failed.length} registry unreachable', style: Txt.small(p.muted)),
                    ),
                ],
              );
            },
          ),
          SectionLabel('Listed on the network', trailing: Text('${listed.length}', style: Txt.mono(p.muted, size: 11))),
          if (listed.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
              child: Text('Nobody has listed a plugin yet. Made one? List it so everyone on the network can find it.', style: Txt.small(p.muted)),
            ),
          for (final l in listed) PluginListingRow(l),
        ],
      ],
    );
  }

  Future<void> _fromLink(PluginHost host) async {
    final url = await prompt(
      context,
      title: 'Install from a link',
      body: 'Paste the address of a plugin.json, or of a single-file plugin script.',
      hint: 'https://',
      action: 'Fetch',
      maxLength: 300,
      allowEmpty: false,
      keyboard: TextInputType.url,
    );
    final u = Uri.tryParse(url?.trim() ?? '');
    if (u == null || u.host.isEmpty || !mounted) return;
    try {
      final (m, src) = await host.fetchPackage(u);
      if (mounted) await reviewAndInstall(context, host, m, src, origin: u.toString());
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t fetch that plugin: $e');
    }
  }

  Future<void> _fromFile(PluginHost host) async {
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['js', 'json']);
    final path = picked.isEmpty ? null : picked.first.path;
    if (path == null || !mounted) return;
    try {
      final text = await File(path).readAsString();
      final PluginManifest m;
      final String src;
      if (path.endsWith('.json')) {
        final j = jsonDecode(text) as Map;
        m = PluginManifest.parse(j);
        src = await File('${File(path).parent.path}${Platform.pathSeparator}${m.main}').readAsString();
      } else {
        m = PluginManifest.fromHeader(text) ?? (throw const FormatException('the script has no /* @plugin {...} */ header'));
        src = text;
      }
      if (mounted) await reviewAndInstall(context, host, m, src, origin: 'file');
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t read that plugin: $e');
    }
  }

  Future<void> _registries(PluginHost host) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => _Registries(host: host, onChanged: _refresh),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action(this.icon, this.label, this.onTap);
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.only(right: Space.sm),
      child: Material(
        color: p.surface,
        shape: StadiumBorder(side: BorderSide(color: p.line)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: p.inkSoft),
                const SizedBox(width: 6),
                Text(label, style: Txt.small(p.ink).copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A plugin someone listed on the market.
class PluginListingRow extends ConsumerWidget {
  const PluginListingRow(this.listing, {super.key});
  final Listing listing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final l = listing;
    final e = ref.watch(engineProvider);
    final host = ref.watch(pluginHostProvider);
    final m = manifestOfListing(l);
    final have = host?.plugin(m.id);
    final perms = m.permissions;
    return _StoreCard(
      onTap: () => context.push('/market/l/${l.id}'),
      icon: PluginIcon(m),
      title: l.title,
      meta: '${e.nameOf(l.author)} · v${m.version}',
      about: l.about,
      permissions: perms,
      trailing: have != null
          ? Pill(have.manifest.version == m.version ? 'Installed' : 'Update', fg: p.accent, bg: p.accentSoft)
          : (l.price == 0 ? Text('Free', style: Txt.bodyStrong(p.accent)) : Amount(l.price, size: 14)),
    );
  }
}

/// The manifest a plugin listing describes.
PluginManifest manifestOfListing(Listing l) => PluginManifest(
  id: '${l.body['pluginId'] ?? 'unknown'}',
  name: l.title,
  version: '${l.body['version'] ?? '?'}',
  description: l.about,
  icon: '${l.body['icon'] ?? 'extension'}',
  permissions: [
    for (final x in (l.body['permissions'] as List?) ?? const [])
      if (pluginPermissions.containsKey(x)) x as String,
  ],
  sha256: l.body['sha256'] as String?,
  homepage: l.body['homepage'] as String?,
);

/// Shows a listed plugin's permissions, takes payment when it has a price,
/// and installs the exact script that was listed.
Future<void> installListedPlugin(BuildContext context, WidgetRef ref, Listing l) async {
  final host = ref.read(pluginHostProvider);
  final market = ref.read(marketProvider);
  if (host == null || market == null) return;
  try {
    final (m, src) = await host.fetchPackage(Uri.parse(l.body['manifest'] as String), pinnedSha: l.body['sha256'] as String?);
    if (m.id != l.body['pluginId']) throw const FormatException('the manifest no longer matches this listing');
    if (!context.mounted) return;
    final paid = market.pluginPaid(l);
    await reviewAndInstall(
      context,
      host,
      m,
      src,
      origin: l.body['manifest'] as String,
      action: paid ? null : 'Pay ${Coin.format(l.price)} and install',
      beforeInstall: paid ? null : () => market.buyPlugin(l),
    );
  } catch (e) {
    if (context.mounted) toast(context, 'Couldn\'t get ${l.title}: $e');
  }
}

class _StoreCard extends StatelessWidget {
  const _StoreCard({required this.onTap, required this.icon, required this.title, required this.meta, required this.about, required this.permissions, required this.trailing});
  final VoidCallback? onTap;
  final Widget icon;
  final String title;
  final String meta;
  final String about;
  final List<String> permissions;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.sm),
      child: Material(
        color: p.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: p.line)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(Space.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                icon,
                const SizedBox(width: Space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: Txt.bodyStrong(p.ink)),
                      Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.mono(p.muted, size: 10.5)),
                      if (about.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(about, maxLines: 2, overflow: TextOverflow.ellipsis, style: Txt.small(p.inkSoft)),
                      ],
                      if (permissions.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            for (final perm in permissions.take(6))
                              Tooltip(
                                message: pluginPermissions[perm]?.$2 ?? perm,
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(7)),
                                  child: Icon(pluginPermissions[perm]?.$1 ?? Icons.help_outline, size: 13, color: p.muted),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: Space.sm),
                trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Registries extends StatefulWidget {
  const _Registries({required this.host, required this.onChanged});
  final PluginHost host;
  final VoidCallback onChanged;

  @override
  State<_Registries> createState() => _RegistriesState();
}

class _RegistriesState extends State<_Registries> {
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final h = widget.host;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.sm),
            child: Text('Registries', style: Txt.title(p.ink)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.sm),
            child: Text('Each registry is an index.json listing plugins. Add your own to share plugins with friends.', style: Txt.small(p.muted)),
          ),
          for (final r in h.registries)
            ListTile(
              dense: true,
              leading: Icon(defaultRegistries.contains(r) ? Icons.verified_outlined : Icons.link_rounded, size: 18, color: p.muted),
              title: Text(Uri.parse(r).path.replaceFirst('/', ''), maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.mono(p.ink, size: 12)),
              subtitle: Text(Uri.parse(r).host, style: Txt.small(p.muted)),
              trailing: defaultRegistries.contains(r)
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () {
                        h.removeRegistry(r);
                        widget.onChanged();
                        setState(() {});
                      },
                    ),
            ),
          Padding(
            padding: const EdgeInsets.all(Space.gutter),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add a registry'),
              onPressed: () async {
                final url = await prompt(
                  context,
                  title: 'Registry',
                  hint: 'https://…/index.json',
                  action: 'Add',
                  maxLength: 300,
                  allowEmpty: false,
                  keyboard: TextInputType.url,
                );
                final u = Uri.tryParse(url?.trim() ?? '');
                if (u == null || u.scheme != 'https' || u.host.isEmpty) return;
                h.addRegistry(u.toString());
                widget.onChanged();
                setState(() {});
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows what a plugin asks for, and installs it on approval.
Future<bool> reviewAndInstall(
  BuildContext context,
  PluginHost host,
  PluginManifest m,
  String source, {
  required String origin,
  String? action,
  Future<void> Function()? beforeInstall,
}) async {
  final old = host.plugin(m.id);
  final newPerms = m.permissions.where((x) => !(old?.manifest.permissions.contains(x) ?? false)).toList();
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      final p = ctx.pal;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  PluginIcon(m, size: 52),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(m.name, style: Txt.title(p.ink)),
                        Text(
                          [if (m.author.isNotEmpty) m.author, 'v${m.version}', if (old != null) 'installed v${old.manifest.version}'].join(' · '),
                          style: Txt.small(p.muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (m.description.isNotEmpty) ...[const SizedBox(height: Space.md), Text(m.description, style: Txt.body(p.inkSoft))],
              const SizedBox(height: Space.lg),
              Text(m.permissions.isEmpty ? 'NEEDS NO PERMISSIONS' : 'IT WILL BE ABLE TO', style: Txt.label(p.muted)),
              const SizedBox(height: Space.sm),
              for (final perm in m.permissions)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      Icon(pluginPermissions[perm]!.$1, size: 18, color: newPerms.contains(perm) && old != null ? p.accent : p.inkSoft),
                      const SizedBox(width: Space.md),
                      Expanded(child: Text(pluginPermissions[perm]!.$2, style: Txt.body(p.ink))),
                      if (newPerms.contains(perm) && old != null) Text('new', style: Txt.mono(p.accent, size: 11)),
                    ],
                  ),
                ),
              const SizedBox(height: Space.md),
              Text(
                '${(source.length / 1024).toStringAsFixed(1)} KB script from ${origin == 'file' || origin == 'dev' ? 'this device' : Uri.tryParse(origin)?.host ?? origin}',
                style: Txt.mono(p.muted, size: 11),
              ),
              const SizedBox(height: Space.lg),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                  ),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action ?? (old == null ? 'Install' : 'Update'))),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
  if (ok != true || !context.mounted) return false;
  try {
    await beforeInstall?.call();
    host.install(m, source, origin: origin);
    toast(context, '${m.name} ${old == null ? 'installed' : 'updated'}');
    return true;
  } catch (e) {
    toast(context, 'Couldn\'t install: $e');
    return false;
  }
}

class _InstalledRow extends ConsumerWidget {
  const _InstalledRow(this.plugin);
  final InstalledPlugin plugin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final host = ref.watch(pluginHostProvider)!;
    final err = host.errorOf(plugin.id);
    final m = plugin.manifest;
    return InkWell(
      onTap: () => context.push('/plugins/${plugin.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: 10),
        child: Row(
          children: [
            Opacity(opacity: plugin.enabled ? 1 : .45, child: PluginIcon(m)),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(m.name, style: Txt.bodyStrong(p.ink)),
                  const SizedBox(height: 2),
                  Text(
                    err != null ? 'Stopped: $err' : (m.description.isEmpty ? 'v${m.version}' : m.description),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Txt.small(err != null ? p.danger : p.muted),
                  ),
                ],
              ),
            ),
            Switch(value: plugin.enabled, onChanged: (v) => host.setEnabled(plugin.id, v)),
          ],
        ),
      ),
    );
  }
}

class _RegistryRow extends ConsumerStatefulWidget {
  const _RegistryRow(this.entry);
  final RegistryEntry entry;

  @override
  ConsumerState<_RegistryRow> createState() => _RegistryRowState();
}

class _RegistryRowState extends ConsumerState<_RegistryRow> {
  var _busy = false;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final host = ref.watch(pluginHostProvider)!;
    final m = widget.entry.manifest;
    final have = host.plugin(m.id);
    final update = have != null && have.manifest.version != m.version;
    return _StoreCard(
      onTap: _busy ? null : () => _get(host),
      icon: PluginIcon(m),
      title: m.name,
      meta: [if (m.author.isNotEmpty) m.author, 'v${m.version}'].join(' · '),
      about: m.description,
      permissions: m.permissions,
      trailing: _busy
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : (have != null && !update)
          ? Pill('Installed', fg: p.accent, bg: p.accentSoft)
          : FilledButton.tonal(
              onPressed: () => _get(host),
              style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
              child: Text(update ? 'Update' : 'Get'),
            ),
    );
  }

  Future<void> _get(PluginHost host) async {
    if (host.plugin(widget.entry.manifest.id) != null && host.plugin(widget.entry.manifest.id)!.manifest.version == widget.entry.manifest.version) {
      context.push('/plugins/${widget.entry.manifest.id}');
      return;
    }
    setState(() => _busy = true);
    try {
      final (m, src) = await host.fetchPackage(widget.entry.manifestUrl, pinnedSha: widget.entry.manifest.sha256);
      if (mounted) await reviewAndInstall(context, host, m, src, origin: widget.entry.manifestUrl.toString());
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t download ${widget.entry.manifest.name}: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// One installed plugin: switch, pages, permissions, logs.
class PluginDetailScreen extends ConsumerWidget {
  const PluginDetailScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    ref.watch(pluginTickProvider);
    final host = ref.watch(pluginHostProvider);
    final pl = host?.plugin(id);
    if (host == null || pl == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(icon: Icons.extension_off_outlined, title: 'Plugin not installed'),
      );
    }
    final m = pl.manifest;
    final err = host.errorOf(id);
    final logs = host.logs(plugin: id).reversed.take(80).toList();
    final cmds = host.commands.where((c) => c.plugin == id).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(m.name),
        actions: [IconButton(tooltip: 'Restart', icon: const Icon(Icons.restart_alt_rounded), onPressed: () => host.reload(id))],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
            child: Row(
              children: [
                PluginIcon(m, size: 56),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(m.name, style: Txt.title(p.ink)),
                      Text([if (m.author.isNotEmpty) m.author, 'v${m.version}'].join(' · '), style: Txt.small(p.muted)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (m.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
              child: Text(m.description, style: Txt.body(p.inkSoft)),
            ),
          const SizedBox(height: Space.md),
          SwitchTile(
            icon: Icons.power_settings_new_rounded,
            title: 'Enabled',
            subtitle: err != null ? 'Stopped with an error' : (pl.enabled ? 'Running' : 'Off'),
            value: pl.enabled,
            onChanged: (v) => host.setEnabled(id, v),
          ),
          if (err != null)
            Container(
              margin: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
              padding: const EdgeInsets.all(Space.md),
              decoration: BoxDecoration(color: p.dangerSoft, borderRadius: BorderRadius.circular(14)),
              child: Text(err, style: Txt.mono(p.danger, size: 12)),
            ),
          if (host.pagesOf(id).isNotEmpty) ...[
            SectionLabel('Pages'),
            for (final pg in host.pagesOf(id)) RowTile(icon: pluginIcon(pg.icon), title: pg.title, onTap: () => context.push('/plugins/$id/page/${pg.id}')),
          ],
          if (cmds.isNotEmpty) ...[
            SectionLabel('Chat commands'),
            for (final c in cmds)
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.gutter, 6, Space.gutter, 6),
                child: Row(
                  children: [
                    Text('/${c.name}', style: Txt.mono(p.ink, size: 13, w: FontWeight.w600)),
                    const SizedBox(width: Space.md),
                    Expanded(child: Text(c.description, style: Txt.small(p.muted))),
                  ],
                ),
              ),
          ],
          SectionLabel('Permissions'),
          if (m.permissions.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
              child: Text('None', style: Txt.small(p.muted)),
            ),
          for (final perm in m.permissions)
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, 5, Space.gutter, 5),
              child: Row(
                children: [
                  Icon(pluginPermissions[perm]!.$1, size: 18, color: p.inkSoft),
                  const SizedBox(width: Space.md),
                  Expanded(child: Text(pluginPermissions[perm]!.$2, style: Txt.body(p.ink))),
                  Text(perm, style: Txt.mono(p.faint, size: 10.5)),
                ],
              ),
            ),
          SectionLabel('Log', trailing: Text('${logs.length}', style: Txt.mono(p.muted, size: 11))),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: Space.gutter),
            padding: const EdgeInsets.all(Space.md),
            constraints: const BoxConstraints(maxHeight: 260),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: p.line),
            ),
            child: logs.isEmpty
                ? Text('Nothing logged yet', style: Txt.mono(p.muted, size: 11))
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final l in logs)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text('${_hm(l.ts)}  ${l.text}', style: Txt.mono(l.level == 'error' ? p.danger : p.inkSoft, size: 11)),
                        ),
                    ],
                  ),
          ),
          SectionLabel('About'),
          _kv(p, 'id', m.id),
          _kv(p, 'source', pl.origin == 'dev' ? 'developer API' : pl.origin),
          _kv(p, 'size', '${(pl.source.length / 1024).toStringAsFixed(1)} KB'),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, 0),
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: p.danger),
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: const Text('Remove plugin'),
              onPressed: () async {
                if (!await confirm(context, title: 'Remove ${m.name}?', body: 'Its saved settings are deleted too.', action: 'Remove', danger: true)) return;
                host.uninstall(id);
                if (context.mounted) context.pop();
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _kv(Palette p, String k, String v) => Padding(
    padding: const EdgeInsets.fromLTRB(Space.gutter, 3, Space.gutter, 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 70, child: Text(k, style: Txt.mono(p.muted, size: 11))),
        Expanded(child: Text(v, style: Txt.mono(p.inkSoft, size: 11))),
      ],
    ),
  );
}

String _hm(int ts) {
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

/// A page a plugin declared with mentos.ui.page, drawn with native widgets.
class PluginPageScreen extends ConsumerWidget {
  const PluginPageScreen({super.key, required this.plugin, required this.page});
  final String plugin;
  final String page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(pluginTickProvider);
    final host = ref.watch(pluginHostProvider);
    final pg = host?.page(plugin, page);
    if (host == null || pg == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(icon: Icons.extension_off_outlined, title: 'This page is gone', body: 'The plugin was turned off or removed.'),
      );
    }
    final tree = host.render(pg);
    return Scaffold(
      appBar: AppBar(title: Text(pg.title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, Space.xxl),
        children: [PluginNode(host: host, plugin: plugin, node: tree)],
      ),
    );
  }
}

/// Cards plugins placed in one of the app's screens. Empty when none.
class PluginSlotView extends ConsumerWidget {
  const PluginSlotView(this.name, {super.key, this.padding = const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0)});
  final String name;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(pluginTickProvider);
    final host = ref.watch(pluginHostProvider);
    final slots = host?.slots(name) ?? const <PluginSlot>[];
    if (host == null || slots.isEmpty) return const SizedBox.shrink();
    final p = context.pal;
    return Column(
      children: [
        for (final s in slots)
          if (host.renderSlot(s) case final tree?)
            Padding(
              padding: padding,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.md, Space.sm),
                decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: p.line)),
                child: PluginNode(host: host, plugin: s.plugin, node: tree),
              ),
            ),
      ],
    );
  }
}

/// Renders one node of a plugin page tree. Unknown nodes show as text.
class PluginNode extends StatelessWidget {
  const PluginNode({super.key, required this.host, required this.plugin, required this.node});
  final PluginHost host;
  final String plugin;
  final Object? node;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final n = node;
    if (n == null) return const SizedBox.shrink();
    if (n is List) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final c in n.take(200)) PluginNode(host: host, plugin: plugin, node: c)],
      );
    }
    if (n is! Map)
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(Interp.str(n), style: Txt.body(p.ink)),
      );
    String s(String k) => n[k] == null ? '' : Interp.str(n[k]);
    void call(String k, [List<Object?> args = const []]) {
      if (n[k] != null) host.callback(plugin, n[k], args);
    }

    List<Widget> kids() => [
      for (final c in (n['children'] is List ? n['children'] as List : const []).take(200)) PluginNode(host: host, plugin: plugin, node: c),
    ];

    switch (s('type')) {
      case 'title':
        return Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 6),
          child: Text(s('text'), style: Txt.title(p.ink)),
        );
      case 'text':
        final style = switch (s('style')) {
          'title' => Txt.title(p.ink),
          'heading' => Txt.heading(p.ink),
          'muted' => Txt.small(p.muted),
          'mono' => Txt.mono(p.inkSoft, size: 12),
          'error' => Txt.small(p.danger),
          'strong' => Txt.bodyStrong(p.ink),
          _ => Txt.body(p.ink),
        };
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: SelectableText(s('text'), style: style),
        );
      case 'button':
        final child = Text(s('label').isEmpty ? 'Button' : s('label'));
        void tap() => call('onTap');
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: switch (s('style')) {
            'outline' => OutlinedButton(onPressed: tap, child: child),
            'text' => TextButton(onPressed: tap, child: child),
            _ => FilledButton(onPressed: tap, child: child),
          },
        );
      case 'input':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: _PluginInput(
            key: ValueKey('in-${s('key')}${s('label')}'),
            value: s('value'),
            label: s('label'),
            hint: s('hint'),
            multiline: n['multiline'] == true,
            onChange: (v) => call('onChange', [v]),
            onSubmit: (v) => call('onSubmit', [v]),
          ),
        );
      case 'switch':
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(s('label'), style: Txt.body(p.ink)),
          subtitle: s('subtitle').isEmpty ? null : Text(s('subtitle'), style: Txt.small(p.muted)),
          value: Interp.truthy(n['value']),
          onChanged: (v) => call('onChange', [v]),
        );
      case 'slider':
        final min = Interp.toNum(n['min'] ?? 0).toDouble(), max = Interp.toNum(n['max'] ?? 1).toDouble();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (s('label').isNotEmpty) Text(s('label'), style: Txt.small(p.muted)),
            Slider(
              min: min,
              max: max > min ? max : min + 1,
              value: Interp.toNum(n['value'] ?? min).toDouble().clamp(min, max > min ? max : min + 1),
              onChanged: (v) => call('onChange', [v]),
            ),
          ],
        );
      case 'row':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Wrap(spacing: Space.sm, runSpacing: Space.sm, crossAxisAlignment: WrapCrossAlignment.center, children: kids()),
        );
      case 'column':
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: kids());
      case 'card':
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(Space.md),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: p.line),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: kids()),
        );
      case 'stat':
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(Space.md),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: p.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s('value'), style: Txt.heading(p.ink).copyWith(fontSize: 24)),
              Text(s('label'), style: Txt.small(p.muted)),
            ],
          ),
        );
      case 'list':
        final items = n['items'] is List ? n['items'] as List : const [];
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: p.line),
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            color: p.surface,
            child: Column(
              children: [
                for (final (i, it) in items.take(300).indexed)
                  if (it is Map)
                    ListTile(
                      shape: i == 0 ? null : Border(top: BorderSide(color: p.line)),
                      title: Text(Interp.str(it['title'] ?? ''), style: Txt.body(p.ink)),
                      subtitle: it['subtitle'] == null ? null : Text(Interp.str(it['subtitle']), style: Txt.small(p.muted)),
                      trailing: it['trailing'] == null ? null : Text(Interp.str(it['trailing']), style: Txt.mono(p.muted, size: 12)),
                      onTap: it['onTap'] == null ? null : () => host.callback(plugin, it['onTap']),
                    )
                  else
                    ListTile(title: Text(Interp.str(it), style: Txt.body(p.ink))),
              ],
            ),
          ),
        );
      case 'progress':
        final v = n['value'];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: LinearProgressIndicator(value: v == null ? null : Interp.toNum(v).toDouble().clamp(0, 1), borderRadius: BorderRadius.circular(4)),
        );
      case 'divider':
        return Divider(color: p.line, height: 24);
      case 'space':
        return SizedBox(height: Interp.toNum(n['size'] ?? 12).toDouble().clamp(0, 200));
    }
    return Text(s('text').isEmpty ? Interp.show(n) : s('text'), style: Txt.body(p.ink));
  }
}

class _PluginInput extends StatefulWidget {
  const _PluginInput({
    super.key,
    required this.value,
    required this.label,
    required this.hint,
    required this.multiline,
    required this.onChange,
    required this.onSubmit,
  });
  final String value, label, hint;
  final bool multiline;
  final ValueChanged<String> onChange, onSubmit;

  @override
  State<_PluginInput> createState() => _PluginInputState();
}

class _PluginInputState extends State<_PluginInput> {
  late final _c = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(_PluginInput old) {
    super.didUpdateWidget(old);
    if (widget.value != _c.text && widget.value != old.value) _c.text = widget.value;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _c,
    minLines: widget.multiline ? 3 : 1,
    maxLines: widget.multiline ? 8 : 1,
    decoration: InputDecoration(labelText: widget.label.isEmpty ? null : widget.label, hintText: widget.hint.isEmpty ? null : widget.hint),
    onChanged: widget.onChange,
    onSubmitted: widget.onSubmit,
  );
}
