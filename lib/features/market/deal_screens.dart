import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/market/market.dart';
import '../../net/pay/coin.dart';
import '../../state/calls.dart';
import '../../state/providers.dart';
import '../../widgets/media.dart';
import '../../widgets/ui.dart';
import '../common/attach.dart';
import 'market_kit.dart';

/// `/market/r/:kind/:id`: one deal, whichever side of it this phone is on.
class DealScreen extends ConsumerWidget {
  const DealScreen({super.key, required this.kind, required this.id});
  final String kind;
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = ref.watch(marketProvider);
    ref.watch(marketTickProvider);
    if (m == null) return const Scaffold(body: Loading());
    return switch (kind) {
      'order' => _OrderScreen(id),
      'task' => _TaskWorkScreen(id),
      'trade' => _TradeScreen(id),
      'lease' => _LeaseScreen(id),
      'job' => _JobScreen(id),
      _ => Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.help_outline, title: 'Unknown record')),
    };
  }
}

Scaffold _missing(String what) => Scaffold(
  appBar: AppBar(),
  body: EmptyState(icon: Icons.inbox_outlined, title: '$what not found', body: 'It may still be on its way to this phone.'),
);

Widget _pad(Widget child, {double top = Space.lg}) =>
    Padding(padding: EdgeInsets.fromLTRB(Space.gutter, top, Space.gutter, 0), child: child);

Widget _label(BuildContext context, String t) => _pad(Text(t.toUpperCase(), style: Txt.label(context.pal.muted)), top: Space.xl);

/// Primary and secondary actions laid out as full-width buttons.
class _Actions extends StatelessWidget {
  const _Actions(this.items);
  final List<({String label, VoidCallback? onTap, bool primary, bool danger})> items;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    if (items.isEmpty) return const SizedBox.shrink();
    return _pad(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final a in items)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.sm),
              child: a.primary
                  ? FilledButton(
                      onPressed: a.onTap,
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                      child: Text(a.label),
                    )
                  : OutlinedButton(
                      onPressed: a.onTap,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(46),
                        foregroundColor: a.danger ? p.danger : null,
                      ),
                      child: Text(a.label),
                    ),
            ),
        ],
      ),
    );
  }
}

({String label, VoidCallback? onTap, bool primary, bool danger}) _act(String label, VoidCallback? onTap,
        {bool primary = false, bool danger = false}) =>
    (label: label, onTap: onTap, primary: primary, danger: danger);

Future<String?> _ask(BuildContext context, String title, {String hint = '', String action = 'Send', bool required = true, String? body}) =>
    prompt(context, title: title, hint: hint, action: action, maxLength: 1000, multiline: true, minLines: 2, allowEmpty: !required, body: body);

Future<void> _openRef(BuildContext context, WidgetRef ref, MediaRef media, List<String> sources) async {
  final e = ref.read(engineProvider);
  toast(context, 'Opening ${media.name}…');
  final f = await e.media.open(media, sources: sources);
  if (!context.mounted) return;
  if (f == null) {
    toast(context, 'Could not reach anyone who has this file');
    return;
  }
  await showLocalFile(context, f, name: media.name, mime: media.mime);
}

Widget _fileTile(BuildContext context, WidgetRef ref, MediaRef f, List<String> sources) {
  final p = context.pal;
  return ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(10)),
      child: Icon(f.isImage ? Icons.image_outlined : Icons.insert_drive_file_outlined, color: p.inkSoft),
    ),
    title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text(bytes(f.size)),
    trailing: const Icon(Icons.open_in_new_rounded, size: 18),
    onTap: () => _openRef(context, ref, f, sources),
  );
}

Future<void> _reviewSheet(BuildContext context, WidgetRef ref, {required String lock, required String subject, required String role, String listing = ''}) async {
  var stars = 5;
  final text = TextEditingController();
  final ok = await showInputSheet<bool>(
    context,
    (ctx) => StatefulBuilder(builder: (ctx, set) {
      final p = ctx.pal;
      return InputSheet(
        title: 'Leave a review',
        body: 'Reviews are signed and tied to this escrow, so everyone can see they come from a real trade.',
        action: 'Publish review',
        onAction: () => Navigator.pop(ctx, true),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 1; i <= 5; i++)
                  IconButton(
                    iconSize: 36,
                    onPressed: () => set(() => stars = i),
                    icon: Icon(i <= stars ? Icons.star_rounded : Icons.star_outline_rounded, color: MarketColors(p).amber),
                  ),
              ],
            ),
            TextField(controller: text, maxLength: 500, maxLines: 3, decoration: const InputDecoration(hintText: 'What was it like?')),
          ],
        ),
      );
    }),
  );
  if (ok != true || !context.mounted) return;
  await attempt(
    context,
    () => ref.read(marketProvider)!.review(lock: lock, subject: subject, stars: stars, text: text.text, role: role, listing: listing),
    done: 'Review published',
  );
}

/// Arbiter's split: how much of the hold goes to the payee.
Future<int?> _splitSheet(BuildContext context, int remaining, String payee, String payer) async {
  var toPayee = remaining / 2;
  final ok = await showInputSheet<bool>(
    context,
    (ctx) => StatefulBuilder(builder: (ctx, set) {
      final p = ctx.pal;
      return InputSheet(
        title: 'Settle the dispute',
        body: 'Signs a refund and a release on the ledger. This cannot be undone.',
        action: 'Settle',
        onAction: () => Navigator.pop(ctx, true),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Slider(value: toPayee, min: 0, max: remaining.toDouble(), onChanged: (v) => set(() => toPayee = v)),
            Row(
              children: [
                Expanded(child: Fact(payee, '', child: Amount(toPayee.round(), size: 16, color: p.accent))),
                Expanded(child: Fact(payer, '', child: Amount(remaining - toPayee.round(), size: 16))),
              ],
            ),
          ],
        ),
      );
    }),
  );
  return ok == true ? toPayee.round() : null;
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.stage, required this.subtitle, this.amount});
  final String title;
  final String stage;
  final String subtitle;
  final int? amount;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return _pad(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Pill.stage(context, stage),
              const Spacer(),
              Text(subtitle, style: Txt.mono(p.muted, size: 11)),
            ],
          ),
          const SizedBox(height: Space.md),
          Text(title, style: Txt.title(p.ink)),
          if (amount != null) ...[
            const SizedBox(height: Space.sm),
            Amount(amount!, size: 28),
          ],
        ],
      ),
      top: Space.md,
    );
  }
}

// ---------------------------------------------------------------------------
// orders

const _orderLabels = {
  'placed': 'placed the order',
  'accepted': 'accepted',
  'declined': 'declined',
  'shipped': 'shipped',
  'delivered': 'delivered',
  'refunded': 'refunded',
  'claimed': 'collected payment',
  'cancelled': 'cancelled',
  'received': 'confirmed delivery',
  'disputed': 'opened a dispute',
  'ruling': 'settled the dispute',
  'case': 'asked the arbiter',
  'note': 'wrote',
};

class _OrderScreen extends ConsumerWidget {
  const _OrderScreen(this.id);
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final m = ref.watch(marketProvider)!;
    final e = ref.watch(engineProvider);
    final coin = ref.watch(coinProvider);
    final r = m.order(id);
    if (r == null) return _missing('Order');
    final role = r['role'] as String;
    final stage = m.orderStage(r);
    final lock = r['lock'] as String?;
    final hold = lock == null ? null : coin?.escrow(lock);
    final now = nowMs();
    final acts = hold?.actionsFor(e.me.id, now) ?? const <String>{};
    final buyer = r['buyer'] as String, seller = r['seller'] as String;
    final other = role == 'buyer' ? seller : buyer;
    final lines = (r['lines'] as List).whereType<Map>().toList();
    final delivery = (r['delivery'] as Map?)?.cast<String, dynamic>() ?? const {};
    final address = (r['address'] as Map?)?.cast<String, dynamic>();
    final shipped = (r['shipped'] as Map?)?.cast<String, dynamic>();
    final delivered = (r['delivered'] as Map?)?.cast<String, dynamic>();
    final reviewed = lock != null && m.myReviewFor(lock) != null;

    final actions = <({String label, VoidCallback? onTap, bool primary, bool danger})>[];
    if (role == 'seller') {
      if (acts.contains('ack') && r['invalid'] != true) {
        actions.add(_act('Accept order', () => attempt(context, () => m.acceptOrder(id), done: 'Accepted'), primary: true));
        actions.add(_act('Decline and refund', () async {
          final why = await _ask(context, 'Decline order', hint: 'Out of stock, cannot deliver there…', action: 'Decline');
          if (why != null && context.mounted) await attempt(context, () => m.declineOrder(id, why), done: 'Refunded');
        }, danger: true));
      }
      if (hold?.state == HoldState.accepted) {
        if (r['digital'] == true || delivery['kind'] == 'digital') {
          actions.add(_act('Deliver files', () async {
            final picked = await pickFiles(e.media, context: context);
            if (picked.isEmpty || !context.mounted) return;
            await attempt(context, () async {
              final refs = [for (final x in picked) await importPending(e, x)];
              await m.deliverOrder(id, refs, 'Your files are ready');
            }, done: 'Delivered');
          }, primary: shipped == null && delivered == null));
        } else if (shipped == null) {
          actions.add(_act('Mark as shipped', () async {
            final t = await _ask(context, 'Shipped', hint: 'Courier and tracking, or pickup details', action: 'Mark shipped', required: false);
            if (t != null && context.mounted) await attempt(context, () => m.shipOrder(id, t), done: 'Buyer notified');
          }, primary: true));
        }
      }
      if (acts.contains('claim')) {
        actions.add(_act('Collect payment', () => attempt(context, () => m.claimOrder(id), done: 'Collected'), primary: true));
      }
      if (acts.contains('refund') && hold!.acked) {
        actions.add(_act('Refund some or all', () async {
          final t = await prompt(context, title: 'Refund', hint: 'Amount in Mentos', action: 'Refund',
              keyboard: const TextInputType.numberWithOptions(decimal: true), initial: Coin.format(hold.remaining));
          final amount = t == null ? null : Coin.parse(t);
          if (amount != null && context.mounted) await attempt(context, () => m.refundOrder(id, amount, ''), done: 'Refunded');
        }));
      }
    }
    if (role == 'buyer') {
      if (acts.contains('cancel')) {
        actions.add(_act('Cancel order', () async {
          final ok = await confirm(context, title: 'Cancel order?', body: 'The seller has not accepted yet. All of it comes back to you.', action: 'Cancel order');
          if (ok && context.mounted) await attempt(context, () => m.cancelOrder(id), done: 'Cancelled');
        }, danger: true));
      }
      if (hold != null && hold.acked && hold.remaining > 0 && !hold.disputed) {
        actions.add(_act('I received it, release payment', () async {
          final ok = await confirm(context,
              title: 'Release ${Coin.format(hold.remaining)}?', body: 'The seller is paid now. This cannot be undone.', action: 'Release');
          if (ok && context.mounted) await attempt(context, () => m.confirmOrder(id), done: 'Payment released');
        }, primary: true));
      }
      if (acts.contains('dispute') && hold!.acked) {
        actions.add(_act('Open a dispute', () async {
          final why = await _ask(context, 'What went wrong?', action: 'Open dispute',
              body: r['arbiter'] == null
                  ? 'The payment freezes until the seller refunds or you release it.'
                  : 'The arbiter will see the order and decide how to split the payment.');
          if (why != null && context.mounted) await attempt(context, () => m.disputeOrder(id, why), done: 'Dispute opened');
        }, danger: true));
      }
      if (hold != null && hold.remaining == 0 && hold.released > 0 && !reviewed) {
        actions.add(_act('Review the seller', () => _reviewSheet(context, ref, lock: lock!, subject: seller, role: 'buyer',
            listing: '${lines.first['listing']}')));
      }
    }
    if (role == 'seller' && hold != null && hold.remaining == 0 && hold.released > 0 && !reviewed) {
      actions.add(_act('Review the buyer', () => _reviewSheet(context, ref, lock: lock!, subject: buyer, role: 'seller')));
    }
    if (role == 'arbiter' && hold != null && hold.disputed && hold.remaining > 0) {
      actions.add(_act('Settle the dispute', () async {
        final toSeller = await _splitSheet(context, hold.remaining, 'Seller', 'Buyer');
        if (toSeller != null && context.mounted) await attempt(context, () => m.ruleOrder(id, toSeller, ''), done: 'Settled');
      }, primary: true));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Order ${id.substring(2, 8)}'),
        actions: [
          if (role != 'arbiter')
            IconBtn(Icons.chat_bubble_outline_rounded, tooltip: 'Message', onTap: () => context.push('/chat/$other')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          _Header(
            title: lines.length == 1 ? '${lines.first['title']}' : '${lines.length} items',
            stage: stage,
            subtitle: timeAgo(r['created'] as int? ?? 0),
            amount: r['total'] as int?,
          ),
          if (r['priceChanged'] == true && role == 'seller')
            _pad(MCard(
              color: p.dangerSoft,
              border: false,
              child: Text('Prices changed since this order was placed. Check the total before accepting.', style: Txt.small(p.inkSoft)),
            )),
          if (r['invalid'] == true)
            _pad(MCard(
              color: p.dangerSoft,
              border: false,
              child: Text('The escrow does not match this order. Do not ship.', style: Txt.small(p.danger)),
            )),
          _label(context, role == 'buyer' ? 'Seller' : (role == 'seller' ? 'Buyer' : 'Parties')),
          if (role == 'arbiter') ...[
            _pad(TraderChip(buyer, label: 'Buyer · ${e.nameOf(buyer)}'), top: Space.sm),
            _pad(TraderChip(seller, label: 'Seller · ${e.nameOf(seller)}'), top: Space.sm),
          ] else
            _pad(TraderChip(other, onTap: () => context.push('/u/$other')), top: Space.sm),
          _label(context, 'Payment'),
          _pad(EscrowPanel(lock: lock), top: Space.sm),
          _Actions(actions),
          _label(context, 'Items'),
          for (final x in lines)
            _pad(
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 56,
                      height: 56,
                      child: MarketImage(media: mediaFrom(x['cover']), sources: [seller]),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${x['title']}', style: Txt.bodyStrong(p.ink)),
                        Text(
                          ['×${x['qty']}', ...((x['options'] as Map?) ?? const {}).entries.map((o) => '${o.key}: ${o.value}')].join(' · '),
                          style: Txt.small(p.muted),
                        ),
                      ],
                    ),
                  ),
                  Amount((x['unit'] as int) * (x['qty'] as int), size: 14),
                ],
              ),
              top: Space.sm,
            ),
          _label(context, 'Delivery'),
          _pad(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${delivery['label'] ?? ''} · ${deliveryKinds[delivery['kind']] ?? ''}', style: Txt.bodyStrong(p.ink)),
                if (address != null && role != 'arbiter') ...[
                  const SizedBox(height: 4),
                  Text(
                    [address['name'], address['phone'], address['line'], address['city']]
                        .whereType<String>()
                        .where((s) => s.isNotEmpty)
                        .join('\n'),
                    style: Txt.small(p.inkSoft),
                  ),
                ],
                if ('${r['note'] ?? ''}'.isNotEmpty) ...[
                  const SizedBox(height: Space.sm),
                  Text('Note: ${r['note']}', style: Txt.small(p.inkSoft)),
                ],
                if (shipped != null) ...[
                  const SizedBox(height: Space.sm),
                  Pill('Shipped ${timeAgo(shipped['ts'] as int)}', fg: MarketColors(p).blue, bg: MarketColors(p).blueSoft, icon: Icons.local_shipping_outlined),
                  if ('${shipped['text']}'.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text('${shipped['text']}', style: Txt.small(p.inkSoft))),
                ],
              ],
            ),
            top: Space.sm,
          ),
          if (delivered != null) ...[
            _label(context, 'Files'),
            for (final f in refsFrom(delivered['files'])) _pad(_fileTile(context, ref, f, [seller]), top: 0),
          ],
          _label(context, 'Timeline'),
          _pad(Timeline(events: r['events'] as List? ?? const [], labels: _orderLabels), top: Space.md),
          _pad(
            TextButton.icon(
              onPressed: () async {
                final t = await _ask(context, 'Add a note', action: 'Send');
                if (t != null && context.mounted) await attempt(context, () => m.noteOrder(id, t));
              },
              icon: const Icon(Icons.edit_note_rounded),
              label: const Text('Add a note to the timeline'),
            ),
            top: 0,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// tasks

const _taskLabels = {
  'applied': 'applied',
  'offered': 'offered the task',
  'accepted': 'accepted',
  'declined': 'declined',
  'withdrawn': 'withdrew',
  'submitted': 'submitted work',
  'changes': 'asked for changes',
  'approved': 'approved and paid',
  'rejected': 'disputed the work',
  'cancelled': 'withdrew the offer',
  'passed': 'chose someone else',
  'claimed': 'claimed the reward',
  'ruling': 'settled the dispute',
  'case': 'asked the arbiter',
  'note': 'wrote',
};

class _TaskWorkScreen extends ConsumerStatefulWidget {
  const _TaskWorkScreen(this.listingId);
  final String listingId;
  @override
  ConsumerState<_TaskWorkScreen> createState() => _TaskWorkScreenState();
}

class _TaskWorkScreenState extends ConsumerState<_TaskWorkScreen> {
  final _ticks = <int>{};

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final m = ref.watch(marketProvider)!;
    final e = ref.watch(engineProvider);
    final coin = ref.watch(coinProvider);
    final id = widget.listingId;
    final l = m.listing(id);
    var r = m.taskRecord(id);
    if (r == null && l != null && l.author == e.me.id) {
      r = {'role': 'owner', 'listing': id, 'title': l.title, 'reward': l.price, 'applications': const [], 'owner': e.me.id};
    }
    if (r == null) return _missing('Task');
    final role = r['role'] as String;
    final stage = m.taskStage(r);
    final lock = r['lock'] as String?;
    final hold = lock == null ? null : coin?.escrow(lock);
    final acts = hold?.actionsFor(e.me.id, nowMs()) ?? const <String>{};
    final worker = role == 'worker' ? e.me.id : r['worker'] as String?;
    final owner = r['owner'] as String;
    final criteria = ((l?.body['criteria'] ?? r['criteria']) as List? ?? const []).whereType<String>().toList();
    final subs = (r['submissions'] as List? ?? const []).whereType<Map>().toList();
    final apps = (r['applications'] as List? ?? const []).whereType<Map>().toList();
    final reviewed = lock != null && m.myReviewFor(lock) != null;

    final actions = <({String label, VoidCallback? onTap, bool primary, bool danger})>[];
    if (role == 'owner') {
      if (acts.contains('cancel')) {
        actions.add(_act('Withdraw the offer', () => attempt(context, () => m.cancelOffer(id), done: 'Offer withdrawn'), danger: true));
      }
      if (stage == 'in review') {
        final all = criteria.isEmpty || _ticks.length == criteria.length;
        actions.add(_act(all ? 'Approve and pay' : 'Tick every criterion to approve', all
            ? () async {
                final ok = await confirm(context, title: 'Approve work?', body: 'Releases ${Coin.format(hold!.remaining)} to ${e.nameOf(worker!)}.', action: 'Approve');
                if (ok && context.mounted) await attempt(context, () => m.approveWork(id), done: 'Paid');
              }
            : null, primary: true));
        actions.add(_act('Ask for changes', () async {
          final t = await _ask(context, 'What should change?', action: 'Send');
          if (t != null && context.mounted) await attempt(context, () => m.requestChanges(id, t), done: 'Sent');
        }));
      }
      if (acts.contains('dispute') && hold!.acked) {
        actions.add(_act('Dispute the work', () async {
          final t = await _ask(context, 'Why does it fall short?', action: 'Dispute');
          if (t != null && context.mounted) await attempt(context, () => m.rejectWork(id, t), done: 'Disputed');
        }, danger: true));
      }
      if (hold != null && hold.remaining == 0 && hold.released > 0 && !reviewed && worker != null) {
        actions.add(_act('Review the worker', () => _reviewSheet(context, ref, lock: lock!, subject: worker, role: 'owner', listing: id)));
      }
    }
    if (role == 'worker') {
      if (acts.contains('ack')) {
        actions.add(_act('Accept the task', () => attempt(context, () => m.acceptOffer(id), done: 'Accepted'), primary: true));
      }
      if (hold != null && hold.acked && hold.remaining > 0 && !hold.disputed) {
        actions.add(_act(subs.isEmpty ? 'Submit work' : 'Submit again', () => _submit(context, m, id), primary: stage != 'in review'));
      }
      if (acts.contains('claim')) {
        actions.add(_act('Claim the reward', () => attempt(context, () => m.claimTask(id), done: 'Claimed'), primary: true));
      }
      if (acts.contains('refund')) {
        actions.add(_act(hold!.acked ? 'Withdraw and hand back' : 'Decline', () async {
          final t = await _ask(context, 'Leave this task?', action: 'Leave', required: false, hint: 'Optional reason');
          if (t != null && context.mounted) await attempt(context, () => m.leaveTask(id, t), done: 'Done');
        }, danger: true));
      }
      if (hold != null && hold.remaining == 0 && hold.released > 0 && !reviewed) {
        actions.add(_act('Review the owner', () => _reviewSheet(context, ref, lock: lock!, subject: owner, role: 'worker', listing: id)));
      }
    }
    if (role == 'arbiter' && hold != null && hold.disputed && hold.remaining > 0) {
      actions.add(_act('Settle the dispute', () async {
        final toWorker = await _splitSheet(context, hold.remaining, 'Worker', 'Owner');
        if (toWorker != null && context.mounted) await attempt(context, () => m.ruleTask(id, toWorker, ''), done: 'Settled');
      }, primary: true));
    }

    return Scaffold(
      appBar: AppBar(title: Text(role == 'owner' ? 'Your task' : (role == 'worker' ? 'Your work' : 'Task dispute'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          _Header(title: '${r['title']}', stage: stage, subtitle: role, amount: r['reward'] as int?),
          if (r['feedback'] != null && stage == 'changes requested')
            _pad(MCard(
              color: MarketColors(p).amberSoft,
              border: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('CHANGES REQUESTED', style: Txt.label(MarketColors(p).amber)),
                  const SizedBox(height: 4),
                  Text('${r['feedback']}', style: Txt.body(p.ink)),
                ],
              ),
            )),
          if (lock != null) ...[
            _label(context, 'Reward'),
            _pad(EscrowPanel(lock: lock, payerLabel: 'Owner', payeeLabel: 'Worker'), top: Space.sm),
          ],
          _Actions(actions),
          if (role == 'owner' && lock == null) ...[
            _label(context, 'Applicants (${apps.length})'),
            if (apps.isEmpty)
              _pad(Text('Nobody has applied yet. Your task is visible to every phone on the network.', style: Txt.small(p.muted)), top: Space.sm),
            for (final a in apps)
              _pad(
                MCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TraderChip('${a['by']}', onTap: () => context.push('/u/${a['by']}')),
                      if ('${a['pitch']}'.isNotEmpty) ...[
                        const SizedBox(height: Space.sm),
                        Text('${a['pitch']}', style: Txt.body(p.inkSoft)),
                      ],
                      const SizedBox(height: Space.md),
                      FilledButton(
                        onPressed: () => _pick(context, m, l, '${a['by']}'),
                        child: Text('Pick ${e.nameOf('${a['by']}')}'),
                      ),
                    ],
                  ),
                ),
                top: Space.sm,
              ),
          ],
          if (worker != null && role != 'worker') ...[
            _label(context, 'Worker'),
            _pad(TraderChip(worker, onTap: () => context.push('/u/$worker')), top: Space.sm),
          ],
          if (role != 'owner') ...[
            _label(context, 'Owner'),
            _pad(TraderChip(owner, onTap: () => context.push('/u/$owner')), top: Space.sm),
          ],
          if (criteria.isNotEmpty) ...[
            _label(context, role == 'owner' && stage == 'in review' ? 'Check the evidence' : 'Done means'),
            for (var i = 0; i < criteria.length; i++)
              role == 'owner' && stage == 'in review'
                  ? CheckboxListTile(
                      value: _ticks.contains(i),
                      onChanged: (v) => setState(() => v == true ? _ticks.add(i) : _ticks.remove(i)),
                      title: Text(criteria[i]),
                      controlAffinity: ListTileControlAffinity.leading,
                    )
                  : _pad(
                      Row(children: [
                        Icon(Icons.check_circle_outline_rounded, size: 18, color: p.accent),
                        const SizedBox(width: Space.sm),
                        Expanded(child: Text(criteria[i], style: Txt.body(p.ink))),
                      ]),
                      top: Space.sm,
                    ),
          ],
          if (subs.isNotEmpty) ...[
            _label(context, 'Submissions'),
            for (final s in subs.reversed)
              _pad(
                MCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(timeAgo(s['ts'] as int? ?? 0), style: Txt.mono(p.muted, size: 11)),
                      if ('${s['text'] ?? ''}'.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text('${s['text']}', style: Txt.body(p.ink)),
                      ],
                      if (refsFrom(s['media']).where((x) => x.isImage).isNotEmpty) ...[
                        const SizedBox(height: Space.sm),
                        SizedBox(
                          height: 96,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              for (final x in refsFrom(s['media']).where((x) => x.isImage))
                                Padding(
                                  padding: const EdgeInsets.only(right: Space.sm),
                                  child: GestureDetector(
                                    onTap: () => _openRef(context, ref, x, [?worker]),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: SizedBox(width: 96, height: 96, child: MarketImage(media: x, sources: [?worker])),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                      for (final x in refsFrom(s['media']).where((x) => !x.isImage)) _fileTile(context, ref, x, [?worker]),
                      for (final link in (s['links'] as List? ?? const []).whereType<String>())
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(link, style: Txt.small(MarketColors(p).blue)),
                        ),
                    ],
                  ),
                ),
                top: Space.sm,
              ),
          ],
          _label(context, 'Timeline'),
          _pad(Timeline(events: r['events'] as List? ?? const [], labels: _taskLabels), top: Space.md),
        ],
      ),
    );
  }

  Future<void> _pick(BuildContext context, Market m, Listing? l, String worker) async {
    final arbiters = (l?.body['arbiters'] as List?)?.whereType<String>().toList() ?? const <String>[];
    String? arbiter;
    if (arbiters.isNotEmpty) {
      arbiter = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(title: Text('Arbiter for disputes')),
              ListTile(title: const Text('No arbiter'), onTap: () => Navigator.pop(ctx, '')),
              for (final a in arbiters) ListTile(title: TraderChip(a, dense: true), onTap: () => Navigator.pop(ctx, a)),
            ],
          ),
        ),
      );
      if (arbiter == null) return;
    }
    if (!context.mounted) return;
    final ok = await confirm(context,
        title: 'Pick this person?',
        body: 'The reward moves into escrow for them now. They have two days to accept.',
        action: 'Pick and pay into escrow');
    if (!ok || !context.mounted) return;
    await attempt(context, () => m.assign(widget.listingId, worker, arbiter: arbiter?.isEmpty == true ? null : arbiter), done: 'Offer sent');
  }

  Future<void> _submit(BuildContext context, Market m, String id) async {
    final e = ref.read(engineProvider);
    final text = TextEditingController();
    final links = TextEditingController();
    final files = <Pending>[];
    final ok = await showInputSheet<bool>(
      context,
      (ctx) => StatefulBuilder(builder: (ctx, set) {
        final p = ctx.pal;
        return InputSheet(
          title: 'Submit work',
          body: 'Show how each criterion is met. Photos and files are fetched from your phone when the owner opens them.',
          action: 'Submit',
          onAction: () => Navigator.pop(ctx, true),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(controller: text, maxLines: 4, maxLength: 2000, decoration: const InputDecoration(hintText: 'What you did')),
              TextField(controller: links, decoration: const InputDecoration(hintText: 'Links, separated by spaces (optional)')),
              const SizedBox(height: Space.md),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      final x = await pickImages(context: ctx, limit: 8);
                      set(() => files.addAll(x));
                    },
                    icon: const Icon(Icons.photo_outlined),
                    label: const Text('Photos'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final x = await pickFiles(e.media, context: ctx);
                      set(() => files.addAll(x));
                    },
                    icon: const Icon(Icons.attach_file_rounded),
                    label: const Text('Files'),
                  ),
                ],
              ),
              if (files.isNotEmpty) ...[
                const SizedBox(height: Space.sm),
                Text('${files.length} attached: ${files.map((f) => f.name).join(', ')}', style: Txt.small(p.muted)),
              ],
            ],
          ),
        );
      }),
    );
    if (ok != true || !context.mounted) return;
    await attempt(context, () async {
      final refs = [for (final f in files.take(12)) await importPending(e, f)];
      final urls = links.text.split(RegExp(r'\s+')).where((s) => s.startsWith('http')).take(6).toList();
      await m.submitWork(id, text.text, media: refs, links: urls);
    }, done: 'Submitted');
  }
}

// ---------------------------------------------------------------------------
// exchange trades

const _tradeLabels = {
  'opened': 'opened the trade',
  'locked': 'locked the Mentos',
  'accepted': 'accepted',
  'paid': 'sent the birr',
  'released': 'released the Mentos',
  'disputed': 'disputed',
  'declined': 'declined',
  'cancelled': 'cancelled',
  'claimed': 'claimed the Mentos',
  'note': 'wrote',
};

class _TradeScreen extends ConsumerWidget {
  const _TradeScreen(this.tid);
  final String tid;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final m = ref.watch(marketProvider)!;
    final e = ref.watch(engineProvider);
    final coin = ref.watch(coinProvider);
    final r = m.trade(tid);
    if (r == null) return _missing('Trade');
    final stage = m.tradeStage(r);
    final iSell = r['seller'] == e.me.id;
    final other = r['role'] == 'maker' ? r['taker'] as String : r['maker'] as String;
    final lock = r['lock'] as String?;
    final hold = lock == null ? null : coin?.escrow(lock);
    final acts = hold?.actionsFor(e.me.id, nowMs()) ?? const <String>{};
    final paid = (r['paid'] as Map?)?.cast<String, dynamic>();
    final actions = <({String label, VoidCallback? onTap, bool primary, bool danger})>[];
    if (iSell) {
      if (lock == null && r['declined'] != true) {
        actions.add(_act('Lock ${Coin.format(r['amount'] as int)} Mentos', () => attempt(context, () => m.lockForTrade(tid), done: 'Locked'), primary: true));
      }
      if (hold != null && hold.remaining > 0 && !hold.disputed) {
        actions.add(_act('Birr received, release Mentos', () async {
          final ok = await confirm(context, title: 'Release?', body: 'Only release once ${Exchange.birr(r['birr'] as int)} is in your account.', action: 'Release');
          if (ok && context.mounted) await attempt(context, () => m.releaseTrade(tid), done: 'Released');
        }, primary: paid != null));
      }
      if (acts.contains('cancel')) actions.add(_act('Cancel', () => attempt(context, () => m.cancelTrade(tid), done: 'Cancelled'), danger: true));
      if (acts.contains('dispute') && hold!.acked) {
        actions.add(_act('Birr never arrived: dispute', () async {
          final t = await _ask(context, 'Dispute trade', action: 'Dispute');
          if (t != null && context.mounted) await attempt(context, () => m.disputeTrade(tid, t), done: 'Disputed');
        }, danger: true));
      }
    } else {
      if (acts.contains('ack')) actions.add(_act('Accept', () => attempt(context, () => m.acceptTrade(tid), done: 'Accepted'), primary: true));
      if (hold != null && hold.acked && paid == null && hold.remaining > 0) {
        actions.add(_act('I sent the birr', () async {
          final t = await _ask(context, 'Payment reference', hint: 'Transaction number or note', action: 'Mark as paid');
          if (t != null && context.mounted) await attempt(context, () => m.markPaid(tid, t), done: 'Seller notified');
        }, primary: true));
      }
      if (acts.contains('claim') && paid != null) {
        actions.add(_act('Claim the Mentos', () => attempt(context, () => m.claimTrade(tid), done: 'Claimed'), primary: true));
      }
      if (acts.contains('refund') && paid == null) {
        actions.add(_act('Cancel and hand back', () => attempt(context, () => m.cancelTrade(tid), done: 'Cancelled'), danger: true));
      }
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(iSell ? 'Selling Mentos' : 'Buying Mentos'),
        actions: [IconBtn(Icons.chat_bubble_outline_rounded, tooltip: 'Message', onTap: () => context.push('/chat/$other'))],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          _Header(title: Exchange.birr(r['birr'] as int), stage: stage, subtitle: '${r['method']}', amount: r['amount'] as int?),
          _pad(Text('${((r['rate'] as int) / 100).toStringAsFixed(2)} birr per Mentos · pay within ${r['windowMins']} min',
              style: Txt.small(p.muted)), top: Space.sm),
          _label(context, iSell ? 'Buyer' : 'Seller'),
          _pad(TraderChip(other, onTap: () => context.push('/u/$other')), top: Space.sm),
          if (!iSell && '${r['details'] ?? ''}'.isNotEmpty) ...[
            _label(context, 'Pay to'),
            _pad(MCard(color: p.accentSoft, border: false, child: SelectableText('${r['details']}', style: Txt.bodyStrong(p.ink))), top: Space.sm),
          ],
          if (paid != null) ...[
            _label(context, 'Birr sent'),
            _pad(Text('${paid['text']} · ${timeAgo(paid['ts'] as int)} ago', style: Txt.body(p.ink)), top: Space.sm),
          ],
          _label(context, 'Escrow'),
          _pad(EscrowPanel(lock: lock, payerLabel: 'Seller', payeeLabel: 'Buyer'), top: Space.sm),
          _Actions(actions),
          _label(context, 'Timeline'),
          _pad(Timeline(events: r['events'] as List? ?? const [], labels: _tradeLabels), top: Space.md),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// storage leases

class _LeaseScreen extends ConsumerWidget {
  const _LeaseScreen(this.lid);
  final String lid;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final mc = MarketColors(p);
    final m = ref.watch(marketProvider)!;
    final e = ref.watch(engineProvider);
    final r = m.lease(lid);
    if (r == null) return _missing('Lease');
    final renter = r['role'] == 'renter';
    final stage = m.leaseStage(r);
    final files = (r['files'] as List? ?? const []).whereType<Map>().toList();
    final audits = (r['audits'] as List? ?? const []).whereType<Map>().toList();
    final used = files.fold<int>(0, (s, f) => s + ((f['sz'] as int?) ?? 0));
    final cap = (r['gb'] as int) * 1024 * 1024 * 1024;
    final other = renter ? r['provider'] as String : r['renter'] as String;
    final passed = audits.where((a) => a['ok'] == true).length;
    return Scaffold(
      appBar: AppBar(title: Text(renter ? 'Rented storage' : 'Storage you provide')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          _Header(title: '${r['gb']} GB for ${r['days']} days', stage: stage, subtitle: 'ends ${timeAgo(r['end'] as int)}', amount: r['total'] as int?),
          _pad(
            MCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text('USED', style: Txt.label(p.muted)),
                    const Spacer(),
                    Text('${bytes(used)} of ${r['gb']} GB', style: Txt.mono(p.ink, size: 12)),
                  ]),
                  const SizedBox(height: Space.sm),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(Radii.pill),
                    child: LinearProgressIndicator(value: cap == 0 ? 0 : used / cap, minHeight: 8, color: mc.blue, backgroundColor: p.raised),
                  ),
                  const SizedBox(height: Space.md),
                  FactRow([
                    Fact('Files', '${files.length}'),
                    Fact('Audits passed', '$passed / ${audits.length}'),
                    Fact('Last audit', r['lastAudit'] == null ? '—' : timeAgo(r['lastAudit'] as int)),
                  ]),
                ],
              ),
            ),
          ),
          _label(context, renter ? 'Provider' : 'Renter'),
          _pad(TraderChip(other, onTap: () => context.push('/u/$other')), top: Space.sm),
          _label(context, 'Escrow'),
          _pad(EscrowPanel(lock: r['lock'] as String?, payerLabel: 'Renter', payeeLabel: 'Provider'), top: Space.sm),
          if (renter && stage == 'active')
            _Actions([
              _act('Add a file', () async {
                final picked = await pickFiles(e.media, context: context);
                if (picked.isEmpty || !context.mounted) return;
                await attempt(context, () async {
                  for (final f in picked) {
                    await m.storeFile(lid, f.file);
                  }
                }, done: 'Encrypted and sent');
              }, primary: true),
              _act('Audit now', () => attempt(context, () async {
                if (!await m.auditLease(lid)) throw StateError('Nothing to audit yet, or the provider is offline');
              }, done: 'Challenge sent')),
              _act('End lease', () async {
                final ok = await confirm(context, title: 'End lease?', body: 'Pays for the days used; the provider returns the rest and deletes your files.', action: 'End lease');
                if (ok && context.mounted) await attempt(context, () => m.endLease(lid), done: 'Ended');
              }, danger: true),
            ]),
          _label(context, 'Files'),
          if (files.isEmpty) _pad(Text(renter ? 'Add a file to store it on their phone.' : 'No files yet.', style: Txt.small(p.muted)), top: Space.sm),
          for (final f in files)
            _pad(
              Row(
                children: [
                  Icon(f['stored'] == true ? Icons.cloud_done_outlined : Icons.cloud_upload_outlined,
                      color: f['stored'] == true ? p.accent : p.muted),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(renter ? (mediaFrom(f['ref'])?.name ?? 'File') : '${(f['h'] as String).substring(0, 12)}…',
                            style: Txt.bodyStrong(p.ink)),
                        Text(
                          '${bytes((f['sz'] as int?) ?? 0)} · ${f['stored'] == true ? 'stored' : 'sending'}${f['offloaded'] == true ? ' · only on their phone' : ''}',
                          style: Txt.small(p.muted),
                        ),
                      ],
                    ),
                  ),
                  if (renter && mediaFrom(f['ref']) != null) ...[
                    IconBtn(Icons.open_in_new_rounded, size: 18, tooltip: 'Open', onTap: () async {
                      final file = await m.retrieveFile(lid, f['h'] as String);
                      final ref0 = mediaFrom(f['ref'])!;
                      if (!context.mounted) return;
                      if (file == null) {
                        toast(context, 'The provider is not reachable right now');
                        return;
                      }
                      await showLocalFile(context, file, name: ref0.name, mime: ref0.mime);
                    }),
                    if (f['stored'] == true && f['offloaded'] != true)
                      IconBtn(Icons.cleaning_services_outlined, size: 18, tooltip: 'Free up space here',
                          onTap: () => attempt(context, () => m.offloadFile(lid, f['h'] as String), done: 'Freed on this phone')),
                  ],
                ],
              ),
              top: Space.sm,
            ),
          if (audits.isNotEmpty) ...[
            _label(context, 'Audits'),
            for (final a in audits.reversed.take(10))
              _pad(
                Row(children: [
                  Icon(a['ok'] == true ? Icons.verified_outlined : Icons.error_outline_rounded, size: 18, color: a['ok'] == true ? p.accent : p.danger),
                  const SizedBox(width: Space.sm),
                  Expanded(child: Text(a['ok'] == true ? 'Proved it still has every byte' : 'Could not prove it has the file', style: Txt.small(p.ink))),
                  Text(timeAgo(a['ts'] as int), style: Txt.mono(p.muted, size: 11)),
                ]),
                top: Space.sm,
              ),
          ],
          _label(context, 'Timeline'),
          _pad(Timeline(events: r['events'] as List? ?? const []), top: Space.md),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// compute jobs

class _JobScreen extends ConsumerWidget {
  const _JobScreen(this.jid);
  final String jid;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final m = ref.watch(marketProvider)!;
    final r = m.job(jid);
    if (r == null) return _missing('Job');
    final renter = r['role'] == 'renter';
    final stage = m.jobStage(r);
    final other = renter ? r['provider'] as String : r['renter'] as String;
    final input = mediaFrom(r['input']);
    final output = mediaFrom(r['output']);
    final params = (r['params'] as Map?)?.cast<String, dynamic>() ?? const {};
    return Scaffold(
      appBar: AppBar(title: Text(renter ? 'Your job' : 'Job you ran')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          _Header(title: jobTypes[r['type']] ?? '${r['type']}', stage: stage, subtitle: timeAgo(r['created'] as int? ?? 0), amount: r['price'] as int?),
          _pad(
            MCard(
              child: FactRow([
                Fact('Units', '${r['units'] ?? '—'}'),
                Fact('Run time', r['ms'] == null ? '—' : '${((r['ms'] as int) / 1000).toStringAsFixed(1)} s'),
                Fact('Check', r['verified'] == null ? '—' : (r['verified'] == true ? 'Passed' : 'Failed')),
              ]),
            ),
          ),
          if (params.isNotEmpty)
            _pad(Text(params.entries.map((e) => '${e.key}: ${e.value}').join(' · '), style: Txt.mono(p.muted, size: 11)), top: Space.sm),
          _label(context, renter ? 'Provider' : 'Renter'),
          _pad(TraderChip(other, onTap: () => context.push('/u/$other')), top: Space.sm),
          _label(context, 'Escrow'),
          _pad(EscrowPanel(lock: r['lock'] as String?, payerLabel: 'Renter', payeeLabel: 'Provider'), top: Space.sm),
          if (input != null) ...[
            _label(context, 'Input'),
            _pad(_fileTile(context, ref, input, [r['renter'] as String]), top: 0),
          ],
          if (output != null) ...[
            _label(context, 'Result'),
            _pad(_fileTile(context, ref, output, [r['provider'] as String]), top: 0),
          ],
          if (renter && output != null && r['verified'] != true)
            _Actions([_act('Check the result again', () => attempt(context, () => m.recheckJob(jid), done: 'Checked'))]),
          _label(context, 'Timeline'),
          _pad(Timeline(events: r['events'] as List? ?? const []), top: Space.md),
        ],
      ),
    );
  }
}

/// Keeps a deal row compact in lists.
class DealRow extends ConsumerWidget {
  const DealRow({super.key, required this.title, required this.subtitle, required this.stage, required this.route, this.amount, this.icon});
  final String title;
  final String subtitle;
  final String stage;
  final String route;
  final int? amount;
  final IconData? icon;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    return InkWell(
      onTap: () => context.push(route),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: Space.md),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(12)),
              child: Icon(icon ?? Icons.receipt_long_outlined, size: 20, color: p.inkSoft),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.bodyStrong(p.ink)),
                  const SizedBox(height: 2),
                  Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.small(p.muted)),
                ],
              ),
            ),
            const SizedBox(width: Space.sm),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (amount != null) Amount(amount!, size: 14, unit: false),
                const SizedBox(height: 4),
                Pill.stage(context, stage),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

