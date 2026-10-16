import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../net/pay/ledger.dart';
import 'coin_wallet_screen.dart';
import '../../state/calls.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';

String _money(int minor) => '${Credits.format(minor)} cr';

/// Pays [peer]. With no [amount], one sheet collects the sum and the note.
/// A known amount (a request you already read) still asks before it is sent.
Future<void> payFlow(
  BuildContext context,
  WidgetRef ref,
  String peer, {
  int? amount,
  String memo = '',
}) async {
  final p = ref.read(paymentsProvider);
  final e = ref.read(engineProvider);
  if (p == null) return;
  var a = amount;
  var note = memo;
  if (a == null) {
    final draft = await _askMoney(
      context,
      kind: _MoneyKind.pay,
      who: e.nameOf(peer),
      balance: p.balance(peer),
    );
    if (draft == null || !context.mounted) return;
    a = draft.amount;
    note = draft.memo;
  } else {
    final ok = await confirm(
      context,
      title: 'Pay ${_money(a)}?',
      body:
          'To ${e.nameOf(peer)}${note.isEmpty ? '' : ' for "$note"'}. It counts once they sign it. A signed payment '
          'cannot be taken back, only balanced by paying back.',
      action: 'Pay',
    );
    if (!ok || !context.mounted) return;
  }
  try {
    await p.pay(peer, a, memo: note);
    if (context.mounted) toast(context, 'Sent. Waiting for their signature.');
  } catch (err) {
    if (context.mounted)
      toast(context, err is StateError ? err.message : '$err');
  }
}

/// Everyone you have a credit line with, and what needs your attention.
class WalletScreen extends ConsumerWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    ref.watch(paymentsTickProvider);
    final pay = ref.watch(paymentsProvider);
    final e = ref.watch(maybeEngineProvider);
    if (pay == null || e == null) return const Scaffold(body: Loading());
    final balances = pay.balances();
    final owed = balances.values
        .where((v) => v > 0)
        .fold<int>(0, (a, b) => a + b);
    final owe = balances.values
        .where((v) => v < 0)
        .fold<int>(0, (a, b) => a - b);
    final approvals = pay.approvals();
    final requests = pay.requests();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Wallet'),
        actions: [
          IconBtn(
            Icons.help_outline_rounded,
            tooltip: 'How credit works',
            onTap: () => _explain(context),
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final people = e.people().where((x) => !x.blocked).toList();
          if (people.isEmpty) {
            toast(context, 'Connect with someone first');
            return;
          }
          final id = await showModalBottomSheet<String>(
            context: context,
            isScrollControlled: true,
            builder: (ctx) => SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(ctx).height * .6,
                ),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final x in people)
                      ListTile(
                        leading: Avatar(id: x.id, size: 36),
                        title: Text(x.name),
                        onTap: () => Navigator.pop(ctx, x.id),
                      ),
                  ],
                ),
              ),
            ),
          );
          if (id != null && context.mounted) await payFlow(context, ref, id);
        },
        icon: const Icon(Icons.north_east_rounded),
        label: const Text('Pay'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.gutter,
              Space.md,
              Space.gutter,
              0,
            ),
            child: Row(
              children: [
                _Total(label: 'owed to you', value: owed, color: p.accent),
                const SizedBox(width: Space.sm),
                _Total(label: 'you owe', value: owe, color: p.ink),
              ],
            ),
          ),
          if (approvals.isNotEmpty) ...[
            SectionLabel('Needs your approval'),
            for (final a in approvals)
              ListTile(
                leading: Avatar(id: a.from, size: 40),
                title: Text(
                  '${e.nameOf(a.from)} wants to pay ${_money(a.amount)}',
                ),
                subtitle: Text(
                  a.memo.isEmpty ? 'over the limit you set' : a.memo,
                  style: Txt.small(p.muted),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconBtn(
                      Icons.close_rounded,
                      tooltip: 'Decline',
                      onTap: () => pay.decline(a),
                    ),
                    IconBtn(
                      Icons.check_rounded,
                      tooltip: 'Accept',
                      color: p.accent,
                      onTap: () => pay.approve(a),
                    ),
                  ],
                ),
              ),
          ],
          if (requests.isNotEmpty) ...[
            SectionLabel('Asked to pay'),
            for (final r in requests)
              ListTile(
                leading: Avatar(id: r.peer, size: 40),
                title: Text('${e.nameOf(r.peer)} asks ${_money(r.amount)}'),
                subtitle: Text(
                  r.memo.isEmpty
                      ? timeAgo(r.at)
                      : '${r.memo} · ${timeAgo(r.at)}',
                  style: Txt.small(p.muted),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconBtn(
                      Icons.close_rounded,
                      tooltip: 'Dismiss',
                      onTap: () => pay.dismissRequest(r.id),
                    ),
                    TextButton(
                      onPressed: () async {
                        await payFlow(
                          context,
                          ref,
                          r.peer,
                          amount: r.amount,
                          memo: r.memo,
                        );
                        if (pay.outgoing(r.peer) != null)
                          pay.dismissRequest(r.id);
                      },
                      child: const Text('Pay'),
                    ),
                  ],
                ),
              ),
          ],
          SectionLabel('Credit lines'),
          if (balances.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
              child: Text(
                'No payments yet. Pay a friend, or set how much they may owe you from their page.',
                style: Txt.small(p.muted),
              ),
            ),
          for (final entry
              in (balances.entries.toList()
                ..sort((a, b) => b.value.abs().compareTo(a.value.abs()))))
            ListTile(
              leading: Avatar(id: entry.key, size: 40),
              title: Text(e.nameOf(entry.key)),
              subtitle: Text(
                entry.value == 0
                    ? 'settled'
                    : (entry.value > 0 ? 'owes you' : 'you owe'),
                style: Txt.small(p.muted),
              ),
              trailing: Text(
                Credits.format(entry.value.abs()),
                style: Txt.mono(
                  entry.value > 0 ? p.accent : p.ink,
                  size: 14,
                  w: FontWeight.w500,
                ),
              ),
              onTap: () => context.push('/wallet/${entry.key}'),
            ),
        ],
      ),
    );
  }

  void _explain(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final p = ctx.pal;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.gutter,
              0,
              Space.gutter,
              Space.lg,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Mutual credit', style: Txt.title(p.ink)),
                const SizedBox(height: Space.sm),
                Text(
                  'Credits are not a coin and nobody issues them. When you pay someone, you promise them that much; '
                  'when they pay you, they promise you. Each line is kept only by the two of you, and every payment '
                  'is signed by both phones and chained to the one before, so neither side can change history.\n\n'
                  'You decide how much each person may owe you. Payments beyond that wait for your approval. '
                  'There is no exchange rate, no bank and no way to take back a signed payment: settle by paying back.',
                  style: Txt.body(p.inkSoft),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Total extends StatelessWidget {
  const _Total({required this.label, required this.value, required this.color});
  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(Space.lg),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.lg),
          border: Border.all(color: p.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Txt.mono(p.muted, size: 11)),
            const SizedBox(height: 4),
            Text(Credits.format(value), style: Txt.title(color)),
          ],
        ),
      ),
    );
  }
}

/// One credit line: balance, limit, history, pay and request.
class PeerWalletScreen extends ConsumerStatefulWidget {
  const PeerWalletScreen({super.key, required this.peer});
  final String peer;

  @override
  ConsumerState<PeerWalletScreen> createState() => _PeerWalletScreenState();
}

class _PeerWalletScreenState extends ConsumerState<PeerWalletScreen> {
  bool? _verified;
  int _audited = -1;

  Future<void> _audit(int length) async {
    final pay = ref.read(paymentsProvider);
    if (pay == null || _audited == length) return;
    _audited = length;
    final ok = await pay.audit(widget.peer);
    if (mounted) setState(() => _verified = ok);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    ref.watch(paymentsTickProvider);
    final pay = ref.watch(paymentsProvider);
    final e = ref.watch(maybeEngineProvider);
    if (pay == null || e == null) return const Scaffold(body: Loading());
    final peer = widget.peer;
    final balance = pay.balance(peer);
    final history = pay.ledger(peer).reversed.toList();
    final out = pay.outgoing(peer);
    final limit = pay.limit(peer);
    WidgetsBinding.instance.addPostFrameCallback((_) => _audit(history.length));

    return Scaffold(
      appBar: AppBar(title: Text(e.nameOf(peer))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          const SizedBox(height: Space.lg),
          Center(child: Avatar(id: peer, size: 64)),
          const SizedBox(height: Space.md),
          Center(
            child: Text(
              balance == 0
                  ? 'All settled'
                  : (balance > 0
                        ? '${e.nameOf(peer)} owes you'
                        : 'You owe ${e.nameOf(peer)}'),
              style: Txt.small(p.muted),
            ),
          ),
          Center(
            child: Text(
              Credits.format(balance.abs()),
              style: Txt.display(balance > 0 ? p.accent : p.ink),
            ),
          ),
          const SizedBox(height: Space.lg),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.south_west_rounded, size: 18),
                    label: const Text('Request'),
                    onPressed: () async {
                      final draft = await _askMoney(
                        context,
                        kind: _MoneyKind.ask,
                        who: e.nameOf(peer),
                        balance: pay.balance(peer),
                      );
                      if (draft == null || !context.mounted) return;
                      await pay.request(peer, draft.amount, memo: draft.memo);
                      if (context.mounted)
                        toast(context, 'Asked for ${_money(draft.amount)}');
                    },
                  ),
                ),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.north_east_rounded, size: 18),
                    label: const Text('Pay'),
                    onPressed: out != null
                        ? null
                        : () => payFlow(context, ref, peer),
                  ),
                ),
              ],
            ),
          ),
          if (out != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.gutter,
                Space.md,
                Space.gutter,
                0,
              ),
              child: Text(
                '${_money(out.amount)} sent, waiting for ${e.nameOf(peer)} to sign it.',
                style: Txt.small(p.muted),
              ),
            ),
          SectionLabel('Your limit for them'),
          RowTile(
            icon: Icons.handshake_outlined,
            title: limit == 0
                ? 'Ask me about every payment'
                : 'They may owe you up to ${_money(limit)}',
            subtitle:
                'Payments that stay within this are accepted automatically.',
            onTap: () async {
              final draft = await _askMoney(
                context,
                kind: _MoneyKind.limit,
                who: e.nameOf(peer),
                balance: pay.balance(peer),
                current: limit,
              );
              if (draft == null) return;
              pay.setLimit(peer, draft.amount);
            },
          ),
          SectionLabel(
            'History',
            trailing: _verified == null || history.isEmpty
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _verified!
                            ? Icons.verified_rounded
                            : Icons.gpp_bad_outlined,
                        size: 14,
                        color: _verified! ? p.accent : p.danger,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _verified!
                            ? 'every entry signed by both'
                            : 'chain does not verify',
                        style: Txt.mono(
                          _verified! ? p.accent : p.danger,
                          size: 10.5,
                        ),
                      ),
                    ],
                  ),
          ),
          if (history.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
              child: Text('Nothing yet.', style: Txt.small(p.muted)),
            ),
          for (final h in history)
            _Entry(entry: h, me: e.me.id, name: e.nameOf(peer)),
        ],
      ),
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry({required this.entry, required this.me, required this.name});
  final LedgerEntry entry;
  final String me;
  final String name;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final mine = entry.from == me;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: mine ? p.raised : p.accentSoft,
        child: Icon(
          mine ? Icons.north_east_rounded : Icons.south_west_rounded,
          size: 18,
          color: mine ? p.inkSoft : p.accent,
        ),
      ),
      title: Text(mine ? 'You paid $name' : '$name paid you'),
      subtitle: Text(
        '${entry.memo.isEmpty ? '' : '${entry.memo} · '}${timeAgo(entry.ts)} · #${entry.seq}',
        style: Txt.small(p.muted),
      ),
      trailing: Text(
        Credits.format(mine ? -entry.amount : entry.amount, sign: true),
        style: Txt.mono(mine ? p.ink : p.accent, size: 13, w: FontWeight.w500),
      ),
    );
  }
}

/// Shown on profiles: the balance with this person, opening their page.
class WalletChip extends StatelessWidget {
  const WalletChip({super.key, required this.peer});
  final String peer;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () => sendMentos(context, preset: peer),
      icon: const Icon(Icons.toll_rounded, size: 16),
      label: const Text('Send Mentos'),
    );
  }
}

enum _MoneyKind { pay, ask, limit }

class _MoneyDraft {
  const _MoneyDraft(this.amount, this.memo);
  final int amount;
  final String memo;
}

String _balanceLine(int balance) {
  if (balance == 0) return 'No credit between you yet.';
  if (balance > 0) return 'They currently owe you ${_money(balance)}.';
  return 'You currently owe them ${_money(-balance)}.';
}

String _whole(int minor) => minor % Credits.scale == 0
    ? '${minor ~/ Credits.scale}'
    : Credits.format(minor);

Future<_MoneyDraft?> _askMoney(
  BuildContext context, {
  required _MoneyKind kind,
  required String who,
  required int balance,
  int current = 0,
}) {
  return showInputSheet<_MoneyDraft>(
    context,
    (_) =>
        _MoneySheet(kind: kind, who: who, balance: balance, current: current),
  );
}

class _MoneySheet extends StatefulWidget {
  const _MoneySheet({
    required this.kind,
    required this.who,
    required this.balance,
    required this.current,
  });
  final _MoneyKind kind;
  final String who;
  final int balance;
  final int current;

  @override
  State<_MoneySheet> createState() => _MoneySheetState();
}

class _MoneySheetState extends State<_MoneySheet> {
  late final TextEditingController _amount = TextEditingController(
    text: widget.kind == _MoneyKind.limit && widget.current > 0
        ? _whole(widget.current)
        : '',
  );
  final _memo = TextEditingController();

  static const _presets = [500, 1000, 2500, 5000, 10000];

  @override
  void dispose() {
    _amount.dispose();
    _memo.dispose();
    super.dispose();
  }

  int? get _parsed {
    var t = _amount.text.trim().replaceAll(',', '.');
    if (t.endsWith('.')) t = t.substring(0, t.length - 1);
    if (t.isEmpty) return widget.kind == _MoneyKind.limit ? 0 : null;
    if (widget.kind == _MoneyKind.limit &&
        (t == '0' || t == '0.0' || t == '0.00'))
      return 0;
    return Credits.parse(t);
  }

  bool get _ok => _parsed != null;

  String get _title => switch (widget.kind) {
    _MoneyKind.pay => 'Pay ${widget.who}',
    _MoneyKind.ask => 'Ask ${widget.who}',
    _MoneyKind.limit => 'Limit for ${widget.who}',
  };

  String get _body => switch (widget.kind) {
    _MoneyKind.pay =>
      '${_balanceLine(widget.balance)} It counts once they sign it. A signed payment cannot be taken back, only balanced by paying back.',
    _MoneyKind.ask =>
      '${_balanceLine(widget.balance)} They can pay this, ignore it, or pay a different amount.',
    _MoneyKind.limit =>
      'Payments from ${widget.who} within this are accepted on their own. Anything above it waits for you.',
  };

  String get _action {
    final a = _parsed;
    return switch (widget.kind) {
      _MoneyKind.pay => a == null ? 'Pay' : 'Pay ${_money(a)}',
      _MoneyKind.ask => a == null ? 'Ask' : 'Ask for ${_money(a)}',
      _MoneyKind.limit =>
        a == null
            ? 'Save'
            : (a == 0 ? 'Always ask me' : 'Allow up to ${_money(a)}'),
    };
  }

  void _setAmount(int minor) {
    final text = _whole(minor);
    _amount.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() {});
  }

  void _submit() {
    final a = _parsed;
    if (a == null) return;
    Navigator.pop(
      context,
      _MoneyDraft(a, widget.kind == _MoneyKind.limit ? '' : _memo.text.trim()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final raw = _amount.text.trim();
    final pendingDot = raw.endsWith('.') || raw.endsWith(',');
    final typed = raw.isNotEmpty && !pendingDot && _parsed == null;
    final presets = widget.kind == _MoneyKind.limit
        ? const [0, ..._presets]
        : _presets;
    return InputSheet(
      title: _title,
      body: _body,
      action: _action,
      enabled: _ok,
      onAction: _submit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetLabel('Amount', trailing: 'credits'),
          TextField(
            controller: _amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: widget.kind == _MoneyKind.limit
                ? TextInputAction.done
                : TextInputAction.next,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
            ],
            onChanged: (_) => setState(() {}),
            onSubmitted: widget.kind == _MoneyKind.limit
                ? (_) => _submit()
                : null,
            decoration: InputDecoration(
              hintText: widget.kind == _MoneyKind.limit
                  ? '0 to always ask'
                  : '0.00',
              counterText: '',
            ),
          ),
          if (typed) ...[
            const SizedBox(height: 6),
            Text('Use a number like 12 or 12.50', style: Txt.small(p.danger)),
          ],
          const SizedBox(height: Space.md),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final minor in presets)
                SheetChip(
                  minor == 0 ? 'Always ask' : _whole(minor),
                  selected: _parsed == minor,
                  onTap: () => _setAmount(minor),
                ),
            ],
          ),
          if (widget.kind != _MoneyKind.limit) ...[
            const SizedBox(height: Space.lg),
            SheetLabel(
              'Note',
              trailing: '${_memo.text.length}/${Credits.maxMemo}',
            ),
            TextField(
              controller: _memo,
              maxLength: Credits.maxMemo,
              minLines: 2,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: 'What it is for',
                counterText: '',
              ),
            ),
          ],
        ],
      ),
    );
  }
}
