import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../net/market/market.dart';
import '../../net/pay/coin.dart';
import '../../state/calls.dart';
import '../../state/providers.dart';
import '../../widgets/ui.dart';
import 'market_kit.dart';

typedef _Line = ({Rec line, Listing? listing});

class CartScreen extends ConsumerWidget {
  const CartScreen({super.key, this.seller});
  final String? seller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final m = ref.watch(marketProvider);
    ref.watch(marketTickProvider);
    if (m == null) return const Scaffold(body: Loading());
    final e = ref.watch(engineProvider);
    final groups = <String, List<_Line>>{};
    final gone = <_Line>[];
    for (final line in m.cart()) {
      final l = m.listing('${line['listing']}');
      if (l == null || l.deleted) {
        gone.add((line: line, listing: l));
      } else {
        (groups[l.author] ??= []).add((line: line, listing: l));
      }
    }
    final order = groups.keys.toList()..sort((a, b) => a == seller ? -1 : (b == seller ? 1 : 0));
    return Scaffold(
      appBar: AppBar(title: const Text('Cart')),
      body: groups.isEmpty && gone.isEmpty
          ? EmptyState(
              icon: Icons.shopping_cart_outlined,
              title: 'Your cart is empty',
              body: 'Items you add stay here until you check out.',
              action: FilledButton(onPressed: () => context.pop(), child: const Text('Keep shopping')),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: Space.xxl),
              children: [
                for (final s in order) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, Space.sm),
                    child: TraderChip(s, dense: true, label: 'From ${e.nameOf(s)}'),
                  ),
                  for (final x in groups[s]!) _CartLine(x),
                  _GroupFooter(seller: s, lines: groups[s]!),
                ],
                if (gone.isNotEmpty) ...[
                  const SectionLabel('No longer available'),
                  for (final x in gone)
                    ListTile(
                      title: Text(x.listing?.title ?? 'Removed listing', style: Txt.body(p.muted)),
                      trailing: IconBtn(Icons.delete_outline_rounded, onTap: () => m.setCartQty('${x.line['key']}', 0)),
                    ),
                ],
              ],
            ),
    );
  }
}

class _CartLine extends ConsumerWidget {
  const _CartLine(this.x);
  final _Line x;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final m = ref.watch(marketProvider)!;
    final l = x.listing!;
    final qty = x.line['qty'] as int;
    final options = (x.line['options'] as Map?)?.cast<String, dynamic>() ?? const {};
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: Space.sm),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(width: 72, height: 72, child: MarketImage(media: l.cover, sources: [l.author, m.via(l.id) ?? ''])),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Txt.bodyStrong(p.ink)),
                if (options.isNotEmpty)
                  Text(options.entries.map((o) => '${o.key}: ${o.value}').join(' · '), style: Txt.small(p.muted)),
                const SizedBox(height: 4),
                Amount(l.price * qty, size: 15),
              ],
            ),
          ),
          Column(
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconBtn(Icons.remove_circle_outline_rounded, size: 20, onTap: () => m.setCartQty('${x.line['key']}', qty - 1)),
                  Text('$qty', style: Txt.bodyStrong(p.ink)),
                  IconBtn(Icons.add_circle_outline_rounded, size: 20, onTap: () => m.setCartQty('${x.line['key']}', qty + 1)),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GroupFooter extends ConsumerWidget {
  const _GroupFooter({required this.seller, required this.lines});
  final String seller;
  final List<_Line> lines;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final subtotal = lines.fold<int>(0, (s, x) => s + x.listing!.price * (x.line['qty'] as int));
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, Space.md),
      child: Row(
        children: [
          Text('Subtotal', style: Txt.small(p.muted)),
          const SizedBox(width: Space.sm),
          Amount(subtotal, size: 17),
          const Spacer(),
          FilledButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CheckoutScreen(seller: seller))),
            child: const Text('Checkout'),
          ),
        ],
      ),
    );
  }
}

/// Everything from one seller, paid into a single escrow.
class CheckoutScreen extends ConsumerStatefulWidget {
  const CheckoutScreen({super.key, required this.seller});
  final String seller;

  @override
  ConsumerState<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends ConsumerState<CheckoutScreen> {
  String? _delivery;
  String? _arbiter;
  bool _busy = false;
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _line = TextEditingController();
  final _city = TextEditingController();
  final _note = TextEditingController();

  @override
  void dispose() {
    for (final c in [_name, _phone, _line, _city, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final m = ref.watch(marketProvider)!;
    final coin = ref.watch(coinProvider);
    ref.watch(marketTickProvider);
    final cart = m.cart();
    final lines = <({Listing listing, int qty, Map<String, String> options})>[];
    final keys = <String>[];
    for (final c in cart) {
      final l = m.listing('${c['listing']}');
      if (l == null || l.author != widget.seller || l.deleted) continue;
      lines.add((
        listing: l,
        qty: c['qty'] as int,
        options: ((c['options'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v')),
      ));
      keys.add('${c['key']}');
    }
    if (lines.isEmpty) {
      return Scaffold(appBar: AppBar(title: const Text('Checkout')), body: const EmptyState(icon: Icons.check_circle_outline, title: 'Nothing to pay for'));
    }
    final methods = (lines.first.listing.body['delivery'] as List).whereType<Map>().toList();
    _delivery ??= '${methods.first['id']}';
    final q = m.quote(lines, _delivery);
    final chosen = q.delivery;
    final needsAddress = chosen != null && (chosen['kind'] == 'ship' || chosen['kind'] == 'meet');
    final arbiters = <String>{
      for (final l in lines) ...((l.listing.body['arbiters'] as List?)?.whereType<String>() ?? const <String>[]),
    }.toList();
    final balance = coin?.balance() ?? 0;
    final enough = balance >= q.total;
    final addressOk = !needsAddress || (_name.text.trim().isNotEmpty && _line.text.trim().isNotEmpty);
    final hold = lines.map((l) => l.listing.body['holdDays'] as int).reduce((a, b) => a > b ? a : b) + ((chosen?['days'] as int?) ?? 0);
    return Scaffold(
      appBar: AppBar(title: const Text('Checkout')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
            child: TraderChip(widget.seller),
          ),
          const SectionLabel('Items'),
          for (final l in lines)
            ListTile(
              title: Text(l.listing.title),
              subtitle: Text(['×${l.qty}', ...l.options.entries.map((o) => '${o.key}: ${o.value}')].join(' · ')),
              trailing: Amount(l.listing.price * l.qty, size: 14),
            ),
          const SectionLabel('Delivery'),
          RadioGroup<String>(
            groupValue: _delivery,
            onChanged: (v) => setState(() => _delivery = v),
            child: Column(
              children: [
                for (final d in methods)
                  RadioListTile<String>(
                    value: '${d['id']}',
                    title: Text('${d['label']}'),
                    subtitle: Text('${deliveryKinds[d['kind']]}${(d['days'] as int) > 0 ? ' · ${d['days']} days' : ''}'),
                    secondary: (d['price'] as int) == 0 ? Text('Free', style: Txt.bodyStrong(p.accent)) : Amount(d['price'] as int, size: 14),
                  ),
              ],
            ),
          ),
          if (chosen != null && chosen['kind'] != 'digital') ...[
            SectionLabel(needsAddress ? 'Where to' : 'Contact'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
              child: Column(
                children: [
                  TextField(controller: _name, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Name')),
                  TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone (optional)')),
                  if (needsAddress) ...[
                    TextField(controller: _line, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Address or meeting place')),
                    TextField(controller: _city, decoration: const InputDecoration(labelText: 'City')),
                  ],
                  const SizedBox(height: Space.sm),
                  Row(
                    children: [
                      Icon(Icons.lock_outline_rounded, size: 14, color: p.muted),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text('Sent only to the seller, end-to-end encrypted. Use a pickup point if you prefer.',
                            style: Txt.small(p.muted)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
          const SectionLabel('Note to seller'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: TextField(controller: _note, maxLength: 300, decoration: const InputDecoration(hintText: 'Optional')),
          ),
          if (arbiters.isNotEmpty) ...[
            const SectionLabel('Arbiter'),
            RadioGroup<String?>(
              groupValue: _arbiter,
              onChanged: (v) => setState(() => _arbiter = v),
              child: Column(
                children: [
                  const RadioListTile<String?>(
                    value: null,
                    title: Text('No arbiter'),
                    subtitle: Text('A dispute stays frozen until you two agree'),
                  ),
                  for (final a in arbiters)
                    RadioListTile<String?>(value: a, title: TraderChip(a, dense: true), subtitle: const Text('Can split a disputed payment')),
                ],
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.xl, Space.gutter, 0),
            child: MCard(
              child: Column(
                children: [
                  _row(p, 'Subtotal', q.subtotal),
                  _row(p, 'Delivery', q.shipping),
                  const Divider(height: Space.xl),
                  Row(
                    children: [
                      Text('Total into escrow', style: Txt.bodyStrong(p.ink)),
                      const Spacer(),
                      Amount(q.total, size: 22),
                    ],
                  ),
                  const SizedBox(height: Space.sm),
                  Row(
                    children: [
                      Text('Balance after', style: Txt.small(p.muted)),
                      const Spacer(),
                      Text(Coin.format(balance - q.total), style: Txt.mono(enough ? p.muted : p.danger, size: 12)),
                    ],
                  ),
                  const SizedBox(height: Space.md),
                  Text(
                    'The seller has 3 days to accept; until then you can cancel and get everything back. '
                    'They are paid when you confirm, or $hold days after accepting unless you dispute. '
                    'A 2% network fee comes out of the seller’s side.',
                    style: Txt.small(p.muted),
                  ),
                ],
              ),
            ),
          ),
          if (q.problem != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, 0),
              child: Text(q.problem!, style: Txt.small(p.danger)),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.lg, Space.gutter, 0),
            child: FilledButton(
              onPressed: _busy || !enough || !addressOk || q.problem != null
                  ? null
                  : () async {
                      setState(() => _busy = true);
                      final ok = await attempt(context, () async {
                        final r = await m.placeOrder(
                          lines: lines,
                          deliveryId: _delivery,
                          note: _note.text,
                          arbiter: _arbiter,
                          address: {
                            'name': _name.text.trim(),
                            'phone': _phone.text.trim(),
                            'line': _line.text.trim(),
                            'city': _city.text.trim(),
                          },
                        );
                        m.clearCart(keys);
                        if (context.mounted) {
                          Navigator.of(context).pop();
                          context.push('/market/r/order/${r['id']}');
                        }
                      });
                      if (!ok && mounted) setState(() => _busy = false);
                    },
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              child: Text(!enough ? 'Not enough Mentos' : (_busy ? 'Paying…' : 'Pay ${Coin.format(q.total)} into escrow')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(Palette p, String label, int v) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(children: [Text(label, style: Txt.small(p.inkSoft)), const Spacer(), Amount(v, size: 14, unit: false)]),
  );
}
