import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/market/market.dart';
import '../../net/pay/coin.dart';
import '../../state/calls.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';

/// The open account's marketplace, or null before the node is up.
final marketProvider = Provider<Market?>((ref) => ref.watch(maybeEngineProvider)?.market);

/// Ticks whenever a listing, record or payment changes.
final marketTickProvider = StreamProvider<int>((ref) {
  final m = ref.watch(marketProvider);
  final c = ref.watch(coinProvider);
  if (m == null) return Stream.value(0);
  var n = 0;
  return Stream.multi((out) {
    out.add(n);
    final a = m.changes.listen((_) => out.add(++n));
    final b = c?.changes.listen((_) => out.add(++n));
    out.onCancel = () async {
      await a.cancel();
      await b?.cancel();
    };
  });
});

/// Market accents that sit beside the app's single live accent.
class MarketColors {
  const MarketColors(this.p);
  final Palette p;
  Color get amber => p.isDark ? const Color(0xFFFBBF24) : const Color(0xFFB45309);
  Color get amberSoft => p.isDark ? const Color(0xFF2A2110) : const Color(0xFFFEF3C7);
  Color get blue => p.isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
  Color get blueSoft => p.isDark ? const Color(0xFF122033) : const Color(0xFFDBEAFE);
  Color get violet => p.isDark ? const Color(0xFFA78BFA) : const Color(0xFF6D28D9);
  Color get violetSoft => p.isDark ? const Color(0xFF1E1633) : const Color(0xFFEDE9FE);

  (Color, Color) kind(String kind) => switch (kind) {
    Kinds.item => (p.accent, p.accentSoft),
    Kinds.task => (amber, amberSoft),
    Kinds.ad => (violet, violetSoft),
    Kinds.resource => (blue, blueSoft),
    Kinds.exchange => (p.ink, p.raised),
    _ => (p.inkSoft, p.raised),
  };

  (Color, Color) stage(String stage) => switch (stage) {
    'completed' || 'paid' || 'verified' || 'active' || 'final' => (p.accent, p.accentSoft),
    'disputed' || 'payment problem' || 'failed' || 'failed check' || 'conflicted' => (p.danger, p.dangerSoft),
    'cancelled' || 'declined' || 'refunded' || 'withdrawn' || 'ended' || 'expired' || 'not chosen' ||
    'offer withdrawn' || 'partly refunded' => (p.muted, p.raised),
    'in review' || 'birr sent' || 'shipped' || 'delivered' || 'checking' => (blue, blueSoft),
    _ => (amber, amberSoft),
  };
}

IconData kindIcon(String kind) => switch (kind) {
  Kinds.item => Icons.shopping_bag_outlined,
  Kinds.task => Icons.task_alt_rounded,
  Kinds.ad => Icons.campaign_outlined,
  Kinds.resource => Icons.memory_rounded,
  Kinds.exchange => Icons.currency_exchange_rounded,
  _ => Icons.extension_outlined,
};

String kindLabel(String kind) => switch (kind) {
  Kinds.item => 'Shop',
  Kinds.task => 'Tasks',
  Kinds.ad => 'Ads',
  Kinds.resource => 'Resources',
  Kinds.exchange => 'Exchange',
  _ => 'Plugins',
};

/// A Mentos amount: the number, then a small unit.
class Amount extends StatelessWidget {
  const Amount(this.minor, {super.key, this.size = 16, this.color, this.unit = true, this.sign = false});
  final int minor;
  final double size;
  final Color? color;
  final bool unit;
  final bool sign;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final c = color ?? p.ink;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          Coin.format(minor, sign: sign),
          style: TextStyle(
            fontFamily: kSans,
            fontSize: size,
            fontWeight: FontWeight.w600,
            letterSpacing: size > 22 ? -1 : -0.3,
            color: c,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (unit) ...[
          const SizedBox(width: 4),
          Text('MNT', style: Txt.mono(c.withValues(alpha: .6), size: size > 22 ? 12 : 10, w: FontWeight.w500)),
        ],
      ],
    );
  }
}

/// A rounded pill with a dot, for stages and flags.
class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, required this.fg, required this.bg, this.icon, this.dot = true});
  final String text;
  final Color fg;
  final Color bg;
  final IconData? icon;
  final bool dot;

  factory Pill.stage(BuildContext context, String stage) {
    final (fg, bg) = MarketColors(context.pal).stage(stage);
    return Pill(stage[0].toUpperCase() + stage.substring(1), fg: fg, bg: bg);
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.pill)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 12, color: fg),
          const SizedBox(width: 4),
        ] else if (dot) ...[
          Container(width: 6, height: 6, decoration: BoxDecoration(color: fg, shape: BoxShape.circle)),
          const SizedBox(width: 6),
        ],
        Text(text, style: Txt.mono(fg, size: 11, w: FontWeight.w500)),
      ],
    ),
  );
}

/// Stars out of five, with a count.
class Stars extends StatelessWidget {
  const Stars(this.value, {super.key, this.count, this.size = 13});
  final double value;
  final int? count;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final amber = MarketColors(p).amber;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          Icon(
            value >= i ? Icons.star_rounded : (value >= i - .5 ? Icons.star_half_rounded : Icons.star_outline_rounded),
            size: size,
            color: value > 0 ? amber : p.faint,
          ),
        if (count != null) ...[
          const SizedBox(width: 4),
          Text('($count)', style: Txt.mono(p.muted, size: size - 2)),
        ],
      ],
    );
  }
}

/// Who is on the other side, with what the ledger knows about them.
class TraderChip extends ConsumerWidget {
  const TraderChip(this.id, {super.key, this.onTap, this.dense = false, this.label});
  final String id;
  final VoidCallback? onTap;
  final bool dense;
  final String? label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final m = ref.watch(marketProvider);
    final e = ref.watch(maybeEngineProvider);
    ref.watch(marketTickProvider);
    if (m == null || e == null) return const SizedBox.shrink();
    final rep = m.reputation(id);
    final name = id == e.me.id ? 'You' : e.nameOf(id);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.md),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: dense ? 2 : 6),
        child: Row(
          children: [
            Avatar(id: id, size: dense ? 22 : 38),
            SizedBox(width: dense ? 8 : 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          label ?? name,
                          overflow: TextOverflow.ellipsis,
                          style: dense ? Txt.small(p.inkSoft) : Txt.bodyStrong(p.ink),
                        ),
                      ),
                      if (rep.badge) ...[
                        const SizedBox(width: 4),
                        Icon(Icons.verified_rounded, size: dense ? 13 : 16, color: p.accent),
                      ],
                      if (rep.flagged) ...[
                        const SizedBox(width: 6),
                        Pill('double spend', fg: p.danger, bg: p.dangerSoft, icon: Icons.warning_amber_rounded),
                      ],
                    ],
                  ),
                  if (!dense) ...[
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (rep.reviews > 0) ...[
                          Stars(rep.stars, count: rep.reviews, size: 12),
                          const SizedBox(width: 8),
                        ],
                        Flexible(
                          child: Text(
                            rep.isNew
                                ? 'New trader${rep.since == null ? '' : ' · since ${timeAgo(rep.since!)}'}'
                                : '${rep.trades} trades${rep.disputes > 0 ? ' · ${rep.disputes} disputed' : ''}',
                            overflow: TextOverflow.ellipsis,
                            style: Txt.small(p.muted),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            if (onTap != null && !dense) Icon(Icons.chevron_right_rounded, color: p.faint),
          ],
        ),
      ),
    );
  }
}

/// A photo from a listing, fetched from its author (or whoever relayed it).
class MarketImage extends ConsumerStatefulWidget {
  const MarketImage({super.key, required this.media, required this.sources, this.fit = BoxFit.cover, this.icon});
  final MediaRef? media;
  final List<String> sources;
  final BoxFit fit;
  final IconData? icon;

  @override
  ConsumerState<MarketImage> createState() => _MarketImageState();
}

class _MarketImageState extends ConsumerState<MarketImage> {
  File? _file;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant MarketImage old) {
    super.didUpdateWidget(old);
    if (old.media?.hash != widget.media?.hash) {
      _file = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    final ref0 = widget.media;
    final e = ref.read(maybeEngineProvider);
    if (ref0 == null || e == null || !ref0.isImage) return;
    final hit = e.media.cached(ref0);
    if (hit != null) {
      setState(() => _file = hit);
      return;
    }
    final f = await e.media.open(ref0, sources: widget.sources.where((s) => s.isNotEmpty).toList());
    if (!mounted) return;
    setState(() {
      _file = f;
      _failed = f == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    if (_file != null) {
      return Image.file(_file!, fit: widget.fit, gaplessPlayback: true,
          errorBuilder: (_, _, _) => _fallback(p, true));
    }
    return _fallback(p, _failed);
  }

  Widget _fallback(Palette p, bool failed) => Container(
    color: p.raised,
    alignment: Alignment.center,
    child: widget.media == null || failed
        ? Icon(widget.icon ?? (failed ? Icons.cloud_off_outlined : Icons.image_outlined), color: p.faint, size: 28)
        : SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.6, color: p.faint)),
  );
}

/// Surface card with the market's softer corners.
class MCard extends StatelessWidget {
  const MCard({super.key, required this.child, this.padding = const EdgeInsets.all(Space.lg), this.onTap, this.color, this.border = true});
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final Color? color;
  final bool border;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final body = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? p.surface,
        borderRadius: BorderRadius.circular(18),
        border: border ? Border.all(color: p.line) : null,
      ),
      child: child,
    );
    return onTap == null ? body : Pressable(onTap: onTap, child: body);
  }
}

/// A label above a value, used in fact grids.
class Fact extends StatelessWidget {
  const Fact(this.label, this.value, {super.key, this.child});
  final String label;
  final String value;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(), style: Txt.label(p.muted)),
        const SizedBox(height: 4),
        child ?? Text(value, style: Txt.bodyStrong(p.ink)),
      ],
    );
  }
}

/// Two or three facts side by side.
class FactRow extends StatelessWidget {
  const FactRow(this.children, {super.key});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) const SizedBox(width: Space.lg),
        Expanded(child: children[i]),
      ],
    ],
  );
}

/// What the escrow behind a deal is doing, straight from the ledger.
class EscrowPanel extends ConsumerWidget {
  const EscrowPanel({super.key, required this.lock, this.payerLabel = 'Buyer', this.payeeLabel = 'Seller'});
  final String? lock;
  final String payerLabel;
  final String payeeLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    ref.watch(marketTickProvider);
    final coin = ref.watch(coinProvider);
    final e = lock == null ? null : coin?.escrow(lock!);
    final mc = MarketColors(p);
    if (e == null) {
      return MCard(
        color: mc.amberSoft,
        border: false,
        child: Row(
          children: [
            Icon(Icons.hourglass_top_rounded, color: mc.amber),
            const SizedBox(width: Space.md),
            Expanded(
              child: Text(
                lock == null ? 'No escrow yet.' : 'Waiting for the payment to reach this phone’s ledger…',
                style: Txt.small(p.inkSoft),
              ),
            ),
          ],
        ),
      );
    }
    final conf = coin!.confirmation(e.id);
    final now = nowMs();
    final total = e.amount <= 0 ? 1 : e.amount;
    final (label, icon) = switch (e.state) {
      HoldState.open => ('Held · waiting for $payeeLabel to accept', Icons.lock_clock_outlined),
      HoldState.accepted => ('Held · accepted by $payeeLabel', Icons.lock_outline_rounded),
      HoldState.disputed => ('Disputed · frozen until settled', Icons.gavel_rounded),
      HoldState.settled => ('Settled', Icons.lock_open_rounded),
      HoldState.cancelled => ('Cancelled · returned to $payerLabel', Icons.undo_rounded),
    };
    return MCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: p.accentSoft, borderRadius: BorderRadius.circular(12)),
                child: Icon(icon, color: p.accent, size: 20),
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Escrow', style: Txt.label(p.muted)),
                    const SizedBox(height: 2),
                    Text(label, style: Txt.bodyStrong(p.ink)),
                  ],
                ),
              ),
              Amount(e.amount, size: 18),
            ],
          ),
          const SizedBox(height: Space.md),
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.pill),
            child: SizedBox(
              height: 8,
              child: Row(
                children: [
                  if (e.released > 0) Expanded(flex: e.released, child: Container(color: p.accent)),
                  if (e.refunded > 0) Expanded(flex: e.refunded, child: Container(color: mc.blue)),
                  if (e.remaining > 0) Expanded(flex: e.remaining, child: Container(color: p.raised)),
                  if (e.released + e.refunded + e.remaining == 0) Expanded(child: Container(color: p.raised)),
                ],
              ),
            ),
          ),
          const SizedBox(height: Space.sm),
          Wrap(
            spacing: Space.lg,
            runSpacing: 4,
            children: [
              _legend(p, p.accent, 'Paid out ${Coin.format(e.released)}'),
              if (e.refunded > 0) _legend(p, mc.blue, 'Returned ${Coin.format(e.refunded)}'),
              _legend(p, p.raised, 'Held ${Coin.format(e.remaining)}'),
            ],
          ),
          const SizedBox(height: Space.md),
          Hairline(),
          const SizedBox(height: Space.md),
          FactRow([
            Fact(
              e.remaining > 0 && now < e.until ? 'Auto-release' : 'Deadline',
              e.remaining == 0 ? '—' : _relative(e.until),
            ),
            Fact('Ledger', conf.label,
                child: Pill.stage(context, conf.state == Settle.final_ ? 'final' : conf.label.toLowerCase())),
          ]),
          if (e.arbiter != null) ...[
            const SizedBox(height: Space.md),
            Text('ARBITER', style: Txt.label(p.muted)),
            TraderChip(e.arbiter!, dense: true),
          ],
          if (total > 0 && e.fees > 0) ...[
            const SizedBox(height: Space.sm),
            Text('Network fee ${Coin.format(e.fees)} went to the treasury.', style: Txt.small(p.muted)),
          ],
        ],
      ),
    );
  }

  Widget _legend(Palette p, Color c, String t) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: p.line))),
      const SizedBox(width: 6),
      Text(t, style: Txt.mono(p.muted, size: 11)),
    ],
  );
}

String _relative(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms).difference(DateTime.now());
  if (d.isNegative) return 'passed ${timeAgo(ms)} ago';
  if (d.inDays >= 1) return 'in ${d.inDays} d ${d.inHours % 24} h';
  if (d.inHours >= 1) return 'in ${d.inHours} h ${d.inMinutes % 60} m';
  return 'in ${d.inMinutes} min';
}

String relativeTime(int ms) => _relative(ms);

/// The steps a deal went through, newest last.
class Timeline extends ConsumerWidget {
  const Timeline({super.key, required this.events, this.labels = const {}});
  final List<dynamic> events;
  final Map<String, String> labels;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.watch(maybeEngineProvider);
    final list = events.whereType<Map>().toList();
    if (list.isEmpty) return Text('Nothing yet.', style: Txt.small(p.muted));
    return Column(
      children: [
        for (var i = 0; i < list.length; i++)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 22,
                  child: Column(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        margin: const EdgeInsets.only(top: 5),
                        decoration: BoxDecoration(
                          color: i == list.length - 1 ? p.accent : p.surface,
                          shape: BoxShape.circle,
                          border: Border.all(color: i == list.length - 1 ? p.accent : p.faint, width: 2),
                        ),
                      ),
                      if (i < list.length - 1) Expanded(child: Container(width: 2, color: p.line)),
                    ],
                  ),
                ),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: Space.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${e?.nameOf('${list[i]['by']}') ?? ''} · ${labels[list[i]['what']] ?? '${list[i]['what']}'}',
                                style: Txt.bodyStrong(p.ink),
                              ),
                            ),
                            Text(timeAgo((list[i]['ts'] as int?) ?? 0), style: Txt.mono(p.muted, size: 11)),
                          ],
                        ),
                        if ((list[i]['text'] as String?)?.isNotEmpty == true) ...[
                          const SizedBox(height: 2),
                          Text('${list[i]['text']}', style: Txt.small(p.inkSoft)),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Section header with an optional action.
class MHeader extends StatelessWidget {
  const MHeader(this.title, {super.key, this.action, this.onAction, this.subtitle});
  final String title;
  final String? subtitle;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, Space.xl, Space.gutter, Space.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Txt.title(p.ink)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: Txt.small(p.muted)),
                ],
              ],
            ),
          ),
          if (action != null)
            TextButton(onPressed: onAction, child: Text(action!, style: Txt.bodyStrong(p.accent))),
        ],
      ),
    );
  }
}

/// Runs [f] and reports a failure as a toast.
Future<bool> attempt(BuildContext context, Future<void> Function() f, {String? done}) async {
  try {
    await f();
    if (context.mounted && done != null) toast(context, done);
    return true;
  } catch (e) {
    if (context.mounted) toast(context, friendly(e));
    return false;
  }
}

String friendly(Object e) {
  final s = '$e';
  for (final prefix in ['Bad state: ', 'Invalid argument(s): ', 'Exception: ']) {
    if (s.startsWith(prefix)) return s.substring(prefix.length);
  }
  return s;
}

/// "2 d left" style countdown.
String timeLeft(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms).difference(DateTime.now());
  if (d.isNegative) return 'Past due';
  if (d.inDays >= 1) return '${d.inDays} d left';
  if (d.inHours >= 1) return '${d.inHours} h left';
  return '${d.inMinutes} min left';
}
