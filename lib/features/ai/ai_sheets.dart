import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../ai/ai.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/ui.dart';

// ---------------------------------------------------------------- models

Future<void> showModelPicker(BuildContext context, AiStore store) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Colors.transparent,
  showDragHandle: false,
  builder: (_) => _ModelSheet(store: store),
);

class _ModelSheet extends StatefulWidget {
  const _ModelSheet({required this.store});
  final AiStore store;

  @override
  State<_ModelSheet> createState() => _ModelSheetState();
}

class _ModelSheetState extends State<_ModelSheet> {
  final _q = TextEditingController();
  String _lab = '';
  late Future<List<AiModel>> _load = widget.store.models(widget.store.gateway);

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  void _pick(String? id) {
    widget.store.model = id;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .86,
      minChildSize: .5,
      maxChildSize: .96,
      builder: (_, scroll) => Container(
        decoration: BoxDecoration(color: p.bg, borderRadius: const BorderRadius.vertical(top: Radius.circular(28))),
        child: FutureBuilder<List<AiModel>>(
          future: _load,
          builder: (context, snap) {
            final all = snap.data ?? widget.store.cachedModels(widget.store.gateway);
            final q = _q.text.trim().toLowerCase();
            final labs = <String>{for (final m in all) m.lab}.toList()..sort();
            final shown = [
              for (final m in all)
                if ((_lab.isEmpty || m.lab == _lab) &&
                    (q.isEmpty || '${m.name} ${m.id} ${m.lab} ${m.description}'.toLowerCase().contains(q)))
                  m,
            ];
            final selected = widget.store.model;
            final rows = <Widget>[];
            String? lastLab;
            for (final m in shown) {
              if (m.lab != lastLab) {
                lastLab = m.lab;
                rows.add(Padding(
                  padding: const EdgeInsets.fromLTRB(4, Space.lg, 4, Space.sm),
                  child: Text(m.lab, style: Txt.bodyStrong(p.ink)),
                ));
              }
              rows.add(_ModelCard(m, selected: m.id == selected, onTap: () => _pick(m.id)));
            }
            return CustomScrollView(
              controller: scroll,
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(Space.gutter, 10, Space.gutter, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(child: Container(width: 36, height: 4, decoration: BoxDecoration(color: p.line, borderRadius: BorderRadius.circular(2)))),
                        const SizedBox(height: Space.lg),
                        Row(
                          children: [
                            Expanded(child: Text('Models', style: Txt.title(p.ink))),
                            if (snap.connectionState == ConnectionState.waiting && all.isEmpty)
                              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            else
                              Text('${all.length} available', style: Txt.small(p.muted)),
                            IconBtn(
                              Icons.refresh_rounded,
                              size: 18,
                              color: p.muted,
                              tooltip: 'Refresh from models.dev',
                              onTap: () {
                                final next = widget.store.models(widget.store.gateway, force: true);
                                setState(() {
                                  _load = next;
                                });
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: Space.md),
                        TextField(
                          controller: _q,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            hintText: 'Search models…',
                            prefixIcon: const Icon(Icons.search_rounded),
                            isDense: true,
                            filled: true,
                            fillColor: p.surface,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(26), borderSide: BorderSide(color: p.line)),
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(26), borderSide: BorderSide(color: p.line)),
                          ),
                        ),
                        const SizedBox(height: Space.md),
                      ],
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 42,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
                      children: [
                        _LabChip(icon: Icons.apps_rounded, label: 'All', on: _lab.isEmpty, onTap: () => setState(() => _lab = '')),
                        for (final l in labs) _LabChip(icon: Icons.dns_outlined, label: l, on: _lab == l, onTap: () => setState(() => _lab = l)),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, Space.xxl),
                  sliver: SliverList.list(
                    children: [
                      if (_lab.isEmpty && q.isEmpty)
                        _AutoCard(gateway: widget.store.gateway, selected: selected == null, onTap: () => _pick(null)),
                      if (snap.hasError && all.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: Space.xl),
                          child: Text('Couldn\'t load models.dev: ${snap.error}', style: Txt.small(p.danger)),
                        ),
                      if (all.isNotEmpty && shown.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: Space.xl),
                          child: Center(child: Text('No model matches', style: Txt.small(p.muted))),
                        ),
                      ...rows,
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _LabChip extends StatelessWidget {
  const _LabChip({required this.icon, required this.label, required this.on, required this.onTap});
  final IconData icon;
  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: on ? p.accent : p.surface,
        shape: StadiumBorder(side: BorderSide(color: on ? p.accent : p.line)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: on ? p.accentInk : p.inkSoft),
                const SizedBox(width: 6),
                Text(label, style: Txt.small(on ? p.accentInk : p.ink).copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AutoCard extends StatelessWidget {
  const _AutoCard({required this.gateway, required this.selected, required this.onTap});
  final AiGateway gateway;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Material(
      color: selected ? p.accentSoft : p.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: selected ? p.accent : p.line)),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Space.md),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Auto', style: Txt.bodyStrong(p.ink)),
                    const SizedBox(height: 4),
                    Text(
                      gateway == AiGateway.openrouter
                          ? 'OpenRouter routes each question to the model that fits it best.'
                          : 'A fast, low-cost model that handles most questions well.',
                      style: Txt.small(p.inkSoft),
                    ),
                  ],
                ),
              ),
              if (selected) Icon(Icons.check_rounded, color: p.accent),
            ],
          ),
        ),
      ),
    );
  }
}

String _ctx(int n) => n >= 1000000 ? '${(n / 1000000).toStringAsFixed(n % 1000000 == 0 ? 0 : 1)}M' : '${(n / 1000).toStringAsFixed(1)}K';

String _cost(double? v) {
  if (v == null) return '—';
  if (v == 0) return 'free';
  return '\$${v < 1 ? v.toStringAsFixed(v < .1 ? 3 : 2).replaceFirst(RegExp(r'0+$'), '') : v.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '')}';
}

String _month(String? d) => d == null || d.length < 7 ? '—' : d.substring(0, 7);

class _ModelCard extends StatelessWidget {
  const _ModelCard(this.m, {required this.selected, required this.onTap});
  final AiModel m;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    Widget fact(String top, String bottom) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(top, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.small(p.inkSoft).copyWith(fontSize: 12)),
          Text(bottom, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.small(p.muted).copyWith(fontSize: 11.5)),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: Material(
        color: selected ? p.accentSoft : p.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: selected ? p.accent : p.line)),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(Space.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.bodyStrong(p.ink).copyWith(fontSize: 16))),
                    if (m.context > 0) Text('${_ctx(m.context)} CTX', style: Txt.small(p.muted).copyWith(fontSize: 12)),
                    if (m.reasoning) ...[const SizedBox(width: 8), Tooltip(message: 'Reasons', child: Icon(Icons.psychology_outlined, size: 17, color: p.muted))],
                    if (m.tools) ...[const SizedBox(width: 6), Tooltip(message: 'Uses tools', child: Icon(Icons.handyman_outlined, size: 16, color: p.muted))],
                    if (m.images) ...[const SizedBox(width: 6), Tooltip(message: 'Sees images', child: Icon(Icons.image_outlined, size: 16, color: p.muted))],
                    if (selected) ...[const SizedBox(width: 6), Icon(Icons.check_rounded, size: 18, color: p.accent)],
                  ],
                ),
                if (m.description.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(m.description, maxLines: 3, overflow: TextOverflow.ellipsis, style: Txt.small(p.muted)),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    fact('${_cost(m.costIn)}/1m In', '${_cost(m.costOut)}/1m Out'),
                    fact(_month(m.knowledge), 'knowledge'),
                    fact(m.released ?? '—', 'Release date'),
                    fact(_month(m.updated), 'Last update'),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- settings

Future<void> showAiSettings(BuildContext context, AiStore store) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Colors.transparent,
  showDragHandle: false,
  builder: (_) => _SettingsSheet(store: store),
);

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({required this.store});
  final AiStore store;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late AiGateway _gw = widget.store.gateway;
  late final _key = TextEditingController(text: widget.store.keyFor(_gw));
  late final _system = TextEditingController(text: widget.store.systemPrompt);
  bool _show = false;

  @override
  void dispose() {
    _key.dispose();
    _system.dispose();
    super.dispose();
  }

  void _switch(AiGateway g) {
    setState(() {
      _gw = g;
      _key.text = widget.store.keyFor(g);
    });
  }

  void _save() {
    widget.store
      ..gateway = _gw
      ..setKey(_gw, _key.text)
      ..systemPrompt = _system.text;
    Navigator.pop(context);
    toast(context, _key.text.trim().isEmpty ? 'Key removed' : 'Saved. Using ${_gw.label}.');
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final looksWrong = _key.text.trim().isNotEmpty && !_key.text.trim().startsWith(_gw.keyPrefix);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        decoration: BoxDecoration(color: p.bg, borderRadius: const BorderRadius.vertical(top: Radius.circular(28))),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Space.gutter, 10, Space.gutter, Space.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Container(width: 36, height: 4, decoration: BoxDecoration(color: p.line, borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: Space.lg),
              Text('AI settings', style: Txt.title(p.ink)),
              const SizedBox(height: 4),
              Text('Bring a key from either gateway. Each keeps its own key and last model.', style: Txt.small(p.muted)),
              const SizedBox(height: Space.lg),
              Segmented<AiGateway>(
                value: _gw,
                options: {for (final g in AiGateway.values) g: g.label},
                onChanged: _switch,
              ),
              const SizedBox(height: Space.lg),
              TextField(
                controller: _key,
                obscureText: !_show,
                autocorrect: false,
                enableSuggestions: false,
                style: Txt.mono(p.ink, size: 13),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: '${_gw.label} API key',
                  hintText: '${_gw.keyPrefix}…',
                  helperText: looksWrong ? '${_gw.label} keys usually start with ${_gw.keyPrefix}' : null,
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: _show ? 'Hide' : 'Show',
                        icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20),
                        onPressed: () => setState(() => _show = !_show),
                      ),
                      IconButton(
                        tooltip: 'Paste',
                        icon: const Icon(Icons.content_paste_rounded, size: 20),
                        onPressed: () async {
                          final clip = await Clipboard.getData(Clipboard.kTextPlain);
                          if (clip?.text != null) setState(() => _key.text = clip!.text!.trim());
                        },
                      ),
                    ],
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: Text('Get a ${_gw.label} key'),
                  onPressed: () => launchUrl(Uri.parse(_gw.keysPage), mode: LaunchMode.externalApplication),
                ),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _system,
                minLines: 2,
                maxLines: 5,
                maxLength: 2000,
                decoration: const InputDecoration(
                  labelText: 'Instructions (optional)',
                  hintText: 'For example: Answer briefly. Use metric units.',
                ),
              ),
              const SizedBox(height: Space.sm),
              Text(
                'Your key is stored in this identity\'s encrypted database and sent only to ${_gw.label}. '
                'Messages and files you attach go to the gateway and the model provider, not over the Mentos network.',
                style: Txt.small(p.muted),
              ),
              const SizedBox(height: Space.lg),
              Row(
                children: [
                  if (widget.store.keyFor(_gw).isNotEmpty)
                    TextButton(
                      style: TextButton.styleFrom(foregroundColor: p.danger),
                      onPressed: () => setState(() => _key.clear()),
                      child: const Text('Remove key'),
                    ),
                  const Spacer(),
                  FilledButton(onPressed: _save, child: const Text('Save')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- history

Future<String?> showAiHistory(BuildContext context, AiStore store, {String? current}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Colors.transparent,
  showDragHandle: false,
  builder: (ctx) => StatefulBuilder(
    builder: (ctx, setState) {
      final p = ctx.pal;
      final list = store.conversations();
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: .7,
        maxChildSize: .95,
        builder: (_, scroll) => Container(
          decoration: BoxDecoration(color: p.bg, borderRadius: const BorderRadius.vertical(top: Radius.circular(28))),
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(Space.gutter, 10, Space.gutter, Space.xl),
            children: [
              Center(child: Container(width: 36, height: 4, decoration: BoxDecoration(color: p.line, borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: Space.lg),
              Text('Chats', style: Txt.title(p.ink)),
              const SizedBox(height: Space.md),
              if (list.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: Space.xl),
                  child: Center(child: Text('No saved chats yet', style: Txt.small(p.muted))),
                ),
              for (final c in list)
                Dismissible(
                  key: ValueKey(c.id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: Space.lg),
                    color: p.dangerSoft,
                    child: Icon(Icons.delete_outline_rounded, color: p.danger),
                  ),
                  onDismissed: (_) => setState(() => store.delete(c.id)),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    leading: Icon(c.id == current ? Icons.chat_bubble_rounded : Icons.chat_bubble_outline_rounded, color: c.id == current ? p.accent : p.muted),
                    title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.body(p.ink)),
                    subtitle: Text(
                      '${c.messages.length} messages · ${MaterialLocalizations.of(ctx).formatShortDate(DateTime.fromMillisecondsSinceEpoch(c.updated))}',
                      style: Txt.small(p.muted),
                    ),
                    onTap: () => Navigator.pop(ctx, c.id),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  ),
);
