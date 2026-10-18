import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:open_filex/open_filex.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../net/market/market.dart';
import '../../net/pay/coin.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';
import 'market_kit.dart';

/// The page a renter gets with a sandbox: run scripts, manage files, follow
/// what happened. The host sees the same page, read-only, with a stop button.
class BoxScreen extends ConsumerStatefulWidget {
  const BoxScreen({super.key, required this.bid});
  final String bid;

  @override
  ConsumerState<BoxScreen> createState() => _BoxScreenState();
}

class _BoxScreenState extends ConsumerState<BoxScreen> {
  var _tab = 'console';
  final _code = TextEditingController(text: Sandboxes.sampleScripts.values.first);
  final _args = TextEditingController(text: '{}');
  String? _shownRun;
  bool _showArgs = false;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    // Time left ticks down on screen.
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    _code.dispose();
    _args.dispose();
    super.dispose();
  }

  Future<void> _run(Market m) async {
    Map<String, dynamic> args;
    try {
      final j = jsonDecode(_args.text.trim().isEmpty ? '{}' : _args.text);
      if (j is! Map) throw const FormatException('Input must be a JSON object');
      args = j.cast<String, dynamic>();
    } catch (e) {
      toast(context, 'Input isn\'t valid JSON: $e');
      return;
    }
    await attempt(context, () async {
      final rid = await m.runInBox(widget.bid, _code.text, args: args);
      setState(() => _shownRun = rid);
    });
  }

  Future<void> _upload(Market m) async {
    final files = await FilePicker.pickFiles();
    for (final f in files) {
      final path = f.path;
      if (path == null) continue;
      if (!mounted) return;
      await attempt(context, () => m.putInBox(widget.bid, File(path), name: f.name));
    }
  }

  Future<void> _open(Market m, Map f, {bool preview = false}) async {
    final file = await m.getFromBox(widget.bid, '${f['name']}');
    if (!mounted) return;
    if (file == null) {
      toast(context, 'Fetching ${f['name']} from the host…');
      return;
    }
    if (preview) {
      String text;
      try {
        final bytes = await file.readAsBytes();
        text = utf8.decode(bytes.length > 200000 ? bytes.sublist(0, 200000) : bytes);
      } catch (_) {
        text = 'Not a text file.';
      }
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (ctx) {
          final p = ctx.pal;
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: .7,
            maxChildSize: .95,
            builder: (_, scroll) => ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.xl),
              children: [
                Row(
                  children: [
                    Expanded(child: Text('${f['name']}', style: Txt.title(p.ink))),
                    IconBtn(Icons.copy_rounded, tooltip: 'Copy', onTap: () {
                      Clipboard.setData(ClipboardData(text: text));
                      toast(ctx, 'Copied');
                    }),
                  ],
                ),
                const SizedBox(height: Space.md),
                Container(
                  padding: const EdgeInsets.all(Space.md),
                  decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(14)),
                  child: SelectableText(text, style: Txt.mono(p.ink, size: 12.5)),
                ),
              ],
            ),
          );
        },
      );
    } else {
      await OpenFilex.open(file.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final mc = MarketColors(p);
    final m = ref.watch(marketProvider);
    ref.watch(marketTickProvider);
    final r = m?.box(widget.bid);
    if (m == null || r == null) {
      return Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.terminal_rounded, title: 'Sandbox not found'));
    }
    final role = r['role'] as String;
    final stage = m.boxStage(r);
    final active = stage == 'active';
    final host = role == 'provider';
    final other = host ? r['renter'] as String : r['provider'] as String;
    final runs = (r['runs'] as List? ?? const []).whereType<Map>().toList().reversed.toList();
    final files = (r['files'] as List? ?? const []).whereType<Map>().toList();
    final used = files.fold<int>(0, (s, f) => s + ((f['size'] as int?) ?? 0));
    final quota = ((r['mb'] as int?) ?? 64) * 1024 * 1024;
    final start = r['start'] as int, end = r['end'] as int;
    final now = DateTime.now().millisecondsSinceEpoch;
    final left = (end - now).clamp(0, end - start);
    final busy = runs.isNotEmpty && runs.first['state'] == 'running';
    final shown = _shownRun == null ? (runs.isEmpty ? null : runs.first) : runs.where((x) => x['rid'] == _shownRun).firstOrNull;

    return Scaffold(
      appBar: AppBar(
        title: Text(role == 'demo' ? 'Demo sandbox' : 'Sandbox'),
        actions: [
          if (stage != 'ended' && stage != 'cancelled')
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v != 'end') return;
                final ok = await confirm(
                  context,
                  title: host ? 'Stop hosting?' : 'End this session?',
                  body: role == 'demo'
                      ? 'The demo workspace and its files are deleted.'
                      : host
                      ? 'The workspace is deleted and the unused time is refunded to the renter.'
                      : 'Download anything you need first. Unused hours are refunded.',
                  action: host ? 'Stop' : 'End session',
                  danger: true,
                );
                if (ok && context.mounted) await attempt(context, () => m.endBox(widget.bid), done: 'Ended');
              },
              itemBuilder: (_) => [PopupMenuItem(value: 'end', child: Text(host ? 'Stop hosting' : 'End session'))],
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          // ---------------------------------------------------- header
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
            child: Container(
              padding: const EdgeInsets.all(Space.lg),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: LinearGradient(colors: [mc.violetSoft, p.surface], begin: Alignment.topLeft, end: Alignment.bottomRight),
                border: Border.all(color: p.line),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (role == 'demo')
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(color: mc.violet.withValues(alpha: .15), borderRadius: BorderRadius.circular(14)),
                          child: Icon(Icons.science_outlined, color: mc.violet),
                        )
                      else
                        Avatar(id: other, size: 44, presence: false),
                      const SizedBox(width: Space.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              role == 'demo'
                                  ? 'Runs on this phone, free'
                                  : host
                                  ? 'Hosting for ${m.engine.nameOf(other)}'
                                  : 'On ${m.engine.nameOf(other)}\'s device',
                              style: Txt.bodyStrong(p.ink),
                            ),
                            Text(
                              role == 'demo' ? 'Try the console, then rent the real thing' : '${r['hours']} h · ${Coin.format(r['total'] as int)} MNT in escrow',
                              style: Txt.small(p.muted),
                            ),
                          ],
                        ),
                      ),
                      Pill(stage, fg: active ? p.accent : p.muted, bg: active ? p.accentSoft : p.raised),
                    ],
                  ),
                  const SizedBox(height: Space.md),
                  Row(
                    children: [
                      Expanded(
                        child: _Meter(
                          label: active ? '${_dur(left)} left' : (stage == 'requested' ? 'Waiting for the host' : 'Time'),
                          value: end <= start ? 0 : 1 - left / (end - start),
                          color: mc.violet,
                        ),
                      ),
                      const SizedBox(width: Space.md),
                      Expanded(
                        child: _Meter(label: '${_bytes(used)} of ${_bytes(quota)}', value: quota == 0 ? 0 : used / quota, color: p.accent),
                      ),
                    ],
                  ),
                  if (host || r['usage'] != null) ...[
                    const SizedBox(height: Space.sm),
                    Text(
                      '${(r['usage'] as Map?)?['runs'] ?? runs.length} runs · ${(r['usage'] as Map?)?['ms'] ?? 0} ms of compute',
                      style: Txt.mono(p.muted, size: 11),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (stage == 'requested')
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
              child: Text(
                host ? 'Accepting…' : 'Your payment is in escrow. The console opens as soon as ${m.engine.nameOf(other)}\'s device accepts.',
                style: Txt.small(p.muted),
              ),
            ),
          if (role != 'demo' && !host)
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded, size: 16, color: p.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('The host\'s device can read files in this workspace. Use a storage lease for anything private.', style: Txt.small(p.muted)),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
            child: Segmented<String>(
              value: _tab,
              options: {'console': host ? 'Runs' : 'Console', 'files': 'Files  ${files.length}', 'log': 'Activity'},
              onChanged: (v) => setState(() => _tab = v),
            ),
          ),

          // ---------------------------------------------------- console
          if (_tab == 'console') ...[
            if (!host) ...[
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
                  children: [
                    for (final e in Sandboxes.sampleScripts.entries)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ActionChip(
                          avatar: Icon(Icons.description_outlined, size: 16, color: mc.violet),
                          label: Text(e.key),
                          onPressed: () => setState(() {
                            _code.text = e.value;
                            if (e.key == 'Primes') {
                              _args.text = '{"limit": 20000}';
                              _showArgs = true;
                            }
                          }),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
                child: Container(
                  decoration: BoxDecoration(
                    color: p.isDark ? const Color(0xFF15191A) : const Color(0xFF111413),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: p.isDark ? p.line : Colors.transparent),
                  ),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 10, 8, 0),
                        child: Row(
                          children: [
                            for (final c in const [Color(0xFFF2675C), Color(0xFFF5B94A), Color(0xFF34D399)])
                              Container(width: 9, height: 9, margin: const EdgeInsets.only(right: 6), decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
                            const SizedBox(width: 6),
                            Text('script.js', style: Txt.mono(Colors.white54, size: 11)),
                            const Spacer(),
                            Text('${_code.text.split('\n').length} lines', style: Txt.mono(Colors.white38, size: 11)),
                          ],
                        ),
                      ),
                      TextField(
                        controller: _code,
                        minLines: 8,
                        maxLines: 18,
                        style: Txt.mono(const Color(0xFFE6EDE9), size: 12.5),
                        cursorColor: const Color(0xFF34D399),
                        keyboardType: TextInputType.multiline,
                        autocorrect: false,
                        enableSuggestions: false,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.fromLTRB(14, 10, 14, 14),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
                child: Row(
                  children: [
                    TextButton.icon(
                      onPressed: () => setState(() => _showArgs = !_showArgs),
                      icon: Icon(_showArgs ? Icons.expand_less_rounded : Icons.data_object_rounded, size: 18),
                      label: const Text('Input'),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: active && !busy ? () => _run(m) : null,
                      icon: busy
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.play_arrow_rounded),
                      label: Text(busy ? 'Running…' : 'Run'),
                    ),
                  ],
                ),
              ),
              if (_showArgs)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, 0),
                  child: TextField(
                    controller: _args,
                    style: Txt.mono(p.ink, size: 12.5),
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(labelText: 'box.args (JSON)', isDense: true),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.gutter, 4, Space.gutter, 0),
                child: Text(
                  'Scripts get box.files(), read, write, append, json, remove, exists, size, box.args and log(). End with return to send back a result.',
                  style: Txt.small(p.muted),
                ),
              ),
            ],
            if (shown != null) ...[
              SectionLabel('Output'),
              Padding(padding: const EdgeInsets.symmetric(horizontal: Space.gutter), child: _RunView(shown)),
            ],
            SectionLabel('History', trailing: Text('${runs.length}', style: Txt.mono(p.muted, size: 11))),
            if (runs.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
                child: Text(host ? 'Nothing has run yet.' : 'Runs you start show up here.', style: Txt.small(p.muted)),
              ),
            for (final run in runs.take(20))
              ListTile(
                dense: true,
                leading: Icon(
                  switch (run['state']) {
                    'done' => Icons.check_circle_rounded,
                    'failed' => Icons.error_rounded,
                    _ => Icons.hourglass_top_rounded,
                  },
                  color: switch (run['state']) {
                    'done' => p.accent,
                    'failed' => p.danger,
                    _ => mc.violet,
                  },
                ),
                title: Text('${run['code']}'.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => 'script'), maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.mono(p.ink, size: 12)),
                subtitle: Text([_ago(run['ts'] as int), if (run['ms'] != null) '${run['ms']} ms', if (run['steps'] != null) '${run['steps']} steps'].join(' · '), style: Txt.small(p.muted)),
                selected: shown == run,
                onTap: () => setState(() => _shownRun = run['rid'] as String),
              ),
          ],

          // ---------------------------------------------------- files
          if (_tab == 'files') ...[
            if (!host)
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
                child: OutlinedButton.icon(
                  onPressed: active ? () => _upload(m) : null,
                  icon: const Icon(Icons.upload_file_rounded, size: 18),
                  label: const Text('Upload files'),
                ),
              ),
            if (files.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: Space.xl),
                child: EmptyState(icon: Icons.folder_open_rounded, title: 'No files yet', body: 'Upload files, or let a script write them.', compact: true),
              ),
            for (final f in files)
              ListTile(
                leading: Icon(_fileIcon('${f['name']}'), color: mc.violet),
                title: Text('${f['name']}', style: Txt.body(p.ink)),
                subtitle: Text(
                  [_bytes((f['size'] as int?) ?? 0), if (f['ts'] != null) _ago(f['ts'] as int), if (f['pending'] == true) 'uploading'].join(' · '),
                  style: Txt.small(p.muted),
                ),
                trailing: host
                    ? null
                    : PopupMenuButton<String>(
                        onSelected: (v) async {
                          if (v == 'view') await _open(m, f, preview: true);
                          if (v == 'open') await _open(m, f);
                          if (v == 'del') await attempt(context, () => m.deleteFromBox(widget.bid, '${f['name']}'));
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'view', child: Text('View as text')),
                          PopupMenuItem(value: 'open', child: Text('Open')),
                          PopupMenuItem(value: 'del', child: Text('Delete')),
                        ],
                      ),
                onTap: host ? null : () => _open(m, f, preview: true),
              ),
          ],

          // ---------------------------------------------------- log
          if (_tab == 'log')
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
              child: Timeline(events: (r['events'] as List?) ?? const []),
            ),
        ],
      ),
    );
  }
}

class _RunView extends StatelessWidget {
  const _RunView(this.run);
  final Map run;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final state = run['state'];
    final logs = (run['logs'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
    final result = run['result'];
    final pretty = result == null ? null : (result is String ? result : const JsonEncoder.withIndent('  ').convert(result));
    return Container(
      decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: state == 'failed' ? p.danger : p.line)),
      padding: const EdgeInsets.all(Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Pill(
                switch (state) {
                  'done' => 'done',
                  'failed' => 'failed',
                  _ => 'running',
                },
                fg: state == 'failed' ? p.danger : p.accent,
                bg: state == 'failed' ? p.dangerSoft : p.accentSoft,
              ),
              const Spacer(),
              if (run['ms'] != null) Text('${run['ms']} ms · ${run['steps'] ?? '?'} steps', style: Txt.mono(p.muted, size: 11)),
            ],
          ),
          if (state == 'running') ...[
            const SizedBox(height: Space.md),
            const LinearProgressIndicator(),
          ],
          if (run['error'] != null) ...[
            const SizedBox(height: Space.sm),
            Text('${run['error']}', style: Txt.mono(p.danger, size: 12)),
          ],
          if (logs.isNotEmpty) ...[
            const SizedBox(height: Space.sm),
            Text('LOG', style: Txt.label(p.muted)),
            const SizedBox(height: 4),
            for (final l in logs.take(100)) Text(l, style: Txt.mono(p.inkSoft, size: 12)),
          ],
          if (pretty != null) ...[
            const SizedBox(height: Space.sm),
            Row(
              children: [
                Text('RESULT', style: Txt.label(p.muted)),
                const Spacer(),
                IconBtn(Icons.copy_rounded, size: 16, color: p.muted, tooltip: 'Copy', onTap: () {
                  Clipboard.setData(ClipboardData(text: pretty));
                  toast(context, 'Copied');
                }),
              ],
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Space.md),
              decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(12)),
              child: SelectableText(pretty, style: Txt.mono(p.ink, size: 12.5)),
            ),
          ],
        ],
      ),
    );
  }
}

class _Meter extends StatelessWidget {
  const _Meter({required this.label, required this.value, required this.color});
  final String label;
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.small(p.inkSoft)),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: value.clamp(0, 1).toDouble(), minHeight: 6, color: color, backgroundColor: p.raised),
        ),
      ],
    );
  }
}

IconData _fileIcon(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return switch (ext) {
    'json' => Icons.data_object_rounded,
    'csv' => Icons.table_chart_outlined,
    'txt' || 'md' || 'log' => Icons.description_outlined,
    'js' => Icons.code_rounded,
    'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' => Icons.image_outlined,
    _ => Icons.insert_drive_file_outlined,
  };
}

String _bytes(int b) => b < 1024 ? '$b B' : (b < 1048576 ? '${(b / 1024).toStringAsFixed(1)} KB' : (b < 1073741824 ? '${(b / 1048576).toStringAsFixed(1)} MB' : '${(b / 1073741824).toStringAsFixed(1)} GB'));

String _dur(int ms) {
  final m = ms ~/ 60000;
  if (m < 60) return '$m min';
  final h = m ~/ 60;
  return h < 48 ? '$h h ${m % 60} min' : '${h ~/ 24} days';
}

String _ago(int ts) {
  final s = (DateTime.now().millisecondsSinceEpoch - ts) ~/ 1000;
  if (s < 60) return 'just now';
  if (s < 3600) return '${s ~/ 60} min ago';
  if (s < 86400) return '${s ~/ 3600} h ago';
  return '${s ~/ 86400} d ago';
}

/// Routes for sandboxes, linked from activity and the market.
void openBox(BuildContext context, String bid) => context.push('/market/box/$bid');
