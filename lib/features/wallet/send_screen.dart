import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/pay/coin.dart';
import '../../state/calls.dart';
import '../../state/providers.dart';
import '../../widgets/ui.dart';

/// Writes one payment: amount, recipient, and an optional note, on a single page.
class SendMentosScreen extends ConsumerStatefulWidget {
  const SendMentosScreen({super.key, this.to});

  /// Public key to preselect. The person can still be changed.
  final String? to;

  @override
  ConsumerState<SendMentosScreen> createState() => _SendMentosScreenState();
}

class _SendMentosScreenState extends ConsumerState<SendMentosScreen> {
  final _amount = TextEditingController();
  final _address = TextEditingController();
  final _note = TextEditingController();
  bool _busy = false;
  String? _failure;

  static final _hex = RegExp(r'^[0-9a-f]+$');
  static final _addressId = RegExp(r'^[0-9a-f]{64}$');

  @override
  void initState() {
    super.initState();
    final to = widget.to?.trim().toLowerCase();
    if (to != null && to.isNotEmpty) _address.text = to;
    for (final c in [_amount, _address, _note]) {
      c.addListener(_edited);
    }
  }

  void _edited() {
    if (_failure != null) _failure = null;
    setState(() {});
  }

  @override
  void dispose() {
    for (final c in [_amount, _address, _note]) {
      c.removeListener(_edited);
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    ref.watch(coinTickProvider);
    final coin = ref.watch(coinProvider);
    final e = ref.watch(maybeEngineProvider);
    if (coin == null || e == null) return const Scaffold(body: Loading());

    final balance = coin.balance();
    final raw = _amount.text.trim();
    final amount = Coin.parse(raw);
    final note = _note.text;
    final fee = amount == null ? 0 : Coin.serviceFee(amount, note);
    final id = _address.text.trim().toLowerCase();
    final people = e.people().where((x) => !x.blocked && x.id != e.me.id).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final lookingUpName = id.isNotEmpty && !_hex.hasMatch(id);
    final shown = lookingUpName
        ? people.where((x) => x.name.toLowerCase().contains(id)).toList()
        : people;
    final problem = _failure ?? _problem(raw, amount, note, fee, balance, id, e.me.id);
    final ready = problem == null && amount != null && _addressId.hasMatch(id) && !_busy;
    final known = people.where((x) => x.id == id).firstOrNull;

    return Scaffold(
      appBar: AppBar(title: const Text('Send')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, Space.lg),
              children: [
                Row(
                  children: [
                    Text('MENTOS', style: Txt.label(p.accent)),
                    const Spacer(),
                    Text('${Coin.format(balance)} available', style: Txt.mono(p.muted, size: 11)),
                  ],
                ),
                Theme(
                  data: Theme.of(context).copyWith(
                    inputDecorationTheme: const InputDecorationTheme(
                      filled: false,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                    ),
                  ),
                  child: TextField(
                    key: const ValueKey('send-amount'),
                    controller: _amount,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                    style: Txt.display(p.ink).copyWith(fontSize: 56, height: 1.05),
                    cursorColor: p.accent,
                    decoration: InputDecoration(
                      hintText: '0.00',
                      hintStyle: Txt.display(p.faint).copyWith(fontSize: 56, height: 1.05),
                    ),
                  ),
                ),
                Container(height: 1, color: amount == null ? p.line : p.accent),
                if (fee > 0) ...[
                  const SizedBox(height: Space.sm),
                  Text('Service fee ${Coin.format(fee)}', style: Txt.mono(p.muted, size: 11)),
                ],
                if (problem != null) ...[
                  const SizedBox(height: Space.sm),
                  Text(problem, style: Txt.small(p.danger)),
                ],
                const SizedBox(height: Space.xl),
                Text('PAY TO', style: Txt.label(p.muted)),
                const SizedBox(height: Space.sm),
                if (known != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.sm),
                    child: Text(known.name, style: Txt.heading(p.ink)),
                  ),
                TextField(
                  key: const ValueKey('send-address'),
                  controller: _address,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: Txt.mono(p.ink, size: 13),
                  decoration: const InputDecoration(hintText: 'Name or address'),
                ),
                if (shown.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.md),
                    child: Text(
                      people.isEmpty
                          ? 'Nobody is saved on this phone yet. Paste their address.'
                          : 'No one by that name.',
                      style: Txt.small(p.muted),
                    ),
                  ),
                for (final person in shown)
                  _Person(
                    person: person,
                    selected: person.id == id,
                    onTap: () {
                      _address.value = TextEditingValue(
                        text: person.id,
                        selection: TextSelection.collapsed(offset: person.id.length),
                      );
                    },
                  ),
                const SizedBox(height: Space.lg),
                Text('NOTE', style: Txt.label(p.muted)),
                const SizedBox(height: Space.sm),
                TextField(
                  key: const ValueKey('send-note'),
                  controller: _note,
                  textCapitalization: TextCapitalization.sentences,
                  maxLength: Coin.maxMemo,
                  decoration: const InputDecoration(
                    hintText: 'What it is for (optional)',
                    counterText: '',
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, Space.md),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: ready ? () => _send(coin, id, amount, note) : null,
                  child: Text(_busy ? 'Sending…' : amount == null ? 'Send' : 'Send ${Coin.format(amount)}'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String? _problem(String raw, int? amount, String note, int fee, int balance, String id, String me) {
    if (raw.isNotEmpty && amount == null) return 'Enter an amount like 1 or 1.50';
    if (note.length > Coin.maxMemo) return 'Notes stop at ${Coin.maxMemo} characters';
    if (amount != null && amount + fee > balance) return 'You have ${Coin.format(balance)}';
    if (id.isEmpty || !_hex.hasMatch(id)) return null;
    if (id.length > 64) return 'An address is 64 characters, 0–9 and a–f';
    if (id.length == 64 && id == me) return 'That address is this phone';
    return null;
  }

  Future<void> _send(CoinLedger coin, String id, int amount, String note) async {
    setState(() => _busy = true);
    try {
      await coin.pay(id, amount, memo: note.trim());
      if (!mounted) return;
      toast(context, 'Sent ${Coin.format(amount)} Mentos');
      if (context.canPop()) context.pop();
    } catch (err) {
      if (!mounted) return;
      final message = err is StateError
          ? err.message
          : err is ArgumentError
          ? '${err.message ?? err}'
          : '$err';
      setState(() {
        _busy = false;
        _failure = message;
      });
    }
  }
}

class _Person extends StatelessWidget {
  const _Person({required this.person, required this.selected, required this.onTap});
  final Peer person;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.only(top: Space.sm),
      child: Material(
        color: selected ? p.accentSoft : p.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          side: BorderSide(color: selected ? p.accent : p.line),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.md),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.md),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(person.name, style: Txt.bodyStrong(p.ink)),
                      Text(shortId(person.id), style: Txt.mono(p.muted, size: 11)),
                    ],
                  ),
                ),
                if (selected) Icon(Icons.check_rounded, size: 18, color: p.accent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
