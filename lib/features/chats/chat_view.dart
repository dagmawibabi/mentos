import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../net/views.dart';
import '../../state/providers.dart';
import '../../widgets/ui.dart';
import 'bubble.dart';
import 'composer.dart';
import 'delivery_window.dart';

const quickReactions = ['❤️', '👍', '😂', '😮', '😢', '🔥'];

class ChatView extends ConsumerStatefulWidget {
  const ChatView({
    super.key,
    required this.scope,
    this.group = false,
    this.banner,
    this.canModerate = false,
    this.emptyTitle = 'Say hello',
    this.emptyBody =
        'Messages are end-to-end encrypted and stay on your phones.',
  });

  final String scope;
  final bool group;
  final Widget? banner;
  final bool canModerate;
  final String emptyTitle;
  final String emptyBody;

  @override
  ConsumerState<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends ConsumerState<ChatView>
    with WidgetsBindingObserver {
  MessageView? _replyTo;
  MessageView? _editing;
  String? _highlight;
  final _keys = <String, GlobalKey>{};
  final _scroll = ScrollController();
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = state == AppLifecycleState.resumed;
    if (!_visible || !mounted) return;
    ref.read(engineProvider).markRead(widget.scope);
  }

  void _jumpTo(MessageView? m) {
    if (m == null) return;
    final ctx = _keys[m.id]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: Motion.slow,
      curve: Motion.curve,
      alignment: .5,
    );
    setState(() => _highlight = m.id);
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _highlight = null);
    });
  }

  void _actions(MessageView m) {
    final e = ref.read(engineProvider);
    final p = context.pal;
    HapticFeedback.mediumImpact();
    showActions(
      context,
      header: Padding(
        padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.md),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (final r in quickReactions)
              GestureDetector(
                onTap: () {
                  Navigator.pop(context);
                  e.react(
                    widget.scope,
                    m.id,
                    m.reactions[e.me.id] == r ? null : r,
                  );
                },
                child: Container(
                  width: 46,
                  height: 46,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: m.reactions[e.me.id] == r ? p.accentSoft : p.raised,
                    shape: BoxShape.circle,
                  ),
                  child: Text(r, style: const TextStyle(fontSize: 22)),
                ),
              ),
          ],
        ),
      ),
      [
        SheetAction(
          Icons.route_outlined,
          'Delivery progress',
          () => showMessageDelivery(context, e, m),
        ),
        if (m.canRetry)
          SheetAction(
            Icons.refresh_rounded,
            'Retry unconfirmed recipients',
            () => e.retryMessage(m.id),
          ),
        if (m.canCancel)
          SheetAction(
            Icons.cancel_outlined,
            'Stop retrying',
            () => e.cancelMessage(m.id),
          ),
        SheetAction(
          Icons.reply_rounded,
          'Reply',
          () => setState(() => _replyTo = m),
        ),
        if (m.text.isNotEmpty)
          SheetAction(Icons.copy_rounded, 'Copy', () {
            Clipboard.setData(ClipboardData(text: m.text));
            toast(context, 'Copied');
          }),
        if (m.mine && m.text.isNotEmpty && m.media.isEmpty)
          SheetAction(
            Icons.edit_outlined,
            'Edit',
            () => setState(() => _editing = m),
          ),
        SheetAction(Icons.shortcut_rounded, 'Forward', () => _forward(m)),
        SheetAction(Icons.info_outline_rounded, 'Info', () => _info(m)),
        if (m.mine || widget.canModerate)
          SheetAction(
            Icons.delete_sweep_outlined,
            'Delete for everyone',
            () async {
              final ok = await confirm(
                context,
                title: 'Delete for everyone?',
                body: 'Removed here, and every peer that has it is told to delete it.',
                action: 'Delete',
                danger: true,
              );
              if (ok) await e.deleteItem(m.item);
            },
            danger: true,
          ),
        SheetAction(
          Icons.delete_outline_rounded,
          'Delete for me',
          () => e.deleteLocal(m.item),
          danger: true,
        ),
      ],
    );
  }

  void _info(MessageView m) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StreamBuilder<List<MessageView>>(
        stream: e.watch(
          (keys) => keys.contains(widget.scope),
          () => e.messages(widget.scope),
        ),
        builder: (ctx, snapshot) {
          final current =
              snapshot.data?.where((x) => x.id == m.id).firstOrNull ?? m;
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(ctx).height * .8,
              ),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Space.gutter,
                    0,
                    Space.gutter,
                    Space.xl,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Message info', style: Txt.heading(p.ink)),
                      const SizedBox(height: Space.lg),
                      _InfoRow('Created', '${dayLabel(m.ts)} ${clock(m.ts)}'),
                      _InfoRow('Author', m.mine ? 'You' : e.nameOf(m.author)),
                      _InfoRow(
                        'Stored',
                        m.item.owned
                            ? 'On this phone (yours)'
                            : (m.item.kept
                                  ? 'Kept here with consent'
                                  : 'Live — shown while the author is online'),
                      ),
                      if (m.mine) _InfoRow('Status', current.delivery.label),
                      if (current.delivery == Delivery.failed)
                        Text(
                          'Automatic retries paused. Retry now or wait for the recipient to reconnect.',
                          style: Txt.small(p.muted),
                        ),
                      for (final recipient in current.recipients) ...[
                        _InfoRow(
                          e.nameOf(recipient.peer),
                          recipient.state.label,
                        ),
                        if (recipient.error != null)
                          Text(recipient.error!, style: Txt.small(p.muted)),
                        if (recipient.attempts > 0)
                          Text(
                            '${recipient.attempts} send attempts',
                            style: Txt.small(p.muted),
                          ),
                        const SizedBox(height: Space.sm),
                      ],
                      if (current.canRetry ||
                          current.canCancel ||
                          current.delivery == Delivery.cancelled) ...[
                        Text(
                          'Retry contacts only people who have not confirmed receipt. Stopping retries cannot recall a message; an in-progress send may still arrive.',
                          style: Txt.small(p.muted),
                        ),
                        Wrap(
                          spacing: 8,
                          children: [
                            if (current.canRetry)
                              TextButton(
                                onPressed: () => e.retryMessage(m.id),
                                child: const Text('Retry'),
                              ),
                            if (current.canCancel)
                              TextButton(
                                onPressed: () => e.cancelMessage(m.id),
                                child: const Text('Stop retrying'),
                              ),
                          ],
                        ),
                      ],
                      if (m.expires != null)
                        _InfoRow(
                          'Disappears',
                          '${dayLabel(m.expires!)} ${clock(m.expires!)}',
                        ),
                      _InfoRow('Signature', 'Ed25519 · verified'),
                      _InfoRow('ID', shortId(m.id)),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _forward(MessageView m) async {
    final e = ref.read(engineProvider);
    final people = e.people().where((x) => !x.blocked).toList();
    final target = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * .6,
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.gutter,
                0,
                Space.gutter,
                Space.sm,
              ),
              child: Text('Forward to', style: Txt.heading(ctx.pal.ink)),
            ),
            for (final x in people)
              ListTile(
                title: Text(x.name),
                onTap: () => Navigator.pop(ctx, x.id),
              ),
          ],
        ),
      ),
    );
    if (target == null) return;
    await e.sendMessage(
      Scope.dm(e.me.id, target),
      text: m.text,
      media: m.media,
      forwarded: true,
    );
    if (mounted) toast(context, 'Forwarded to ${e.nameOf(target)}');
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final msgs =
        ref.watch(messagesProvider(widget.scope)).value ??
        const <MessageView>[];
    final typing = {...?ref.watch(typingProvider(widget.scope)).value}
      ..remove(e.me.id);

    ref.listen(messagesProvider(widget.scope), (_, _) {
      if (_visible) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => e.markRead(widget.scope),
        );
      }
    });

    final rows = <Object>[];
    final anchor = <int, GlobalKey>{};
    final seen = <String>{};
    for (var i = msgs.length - 1; i >= 0; i--) {
      rows.add(i);
      if (seen.add(msgs[i].id)) {
        anchor[i] = _keys.putIfAbsent(msgs[i].id, GlobalKey.new);
      }
      final day = dayLabel(msgs[i].ts);
      if (i == 0 || dayLabel(msgs[i - 1].ts) != day) rows.add(day);
    }

    return Column(
      children: [
        ?widget.banner,
        Expanded(
          child: msgs.isEmpty
              ? EmptyState(
                  icon: Icons.lock_outline_rounded,
                  title: widget.emptyTitle,
                  body: widget.emptyBody,
                )
              : ListView.builder(
                  controller: _scroll,
                  reverse: true,
                  padding: const EdgeInsets.only(
                    top: Space.md,
                    bottom: Space.sm,
                  ),
                  itemCount: rows.length + 1,
                  itemBuilder: (_, idx) {
                    if (idx == 0) {
                      return AnimatedSize(
                        duration: Motion.base,
                        child: typing.isEmpty
                            ? const SizedBox(width: double.infinity)
                            : Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  Space.gutter,
                                  6,
                                  Space.gutter,
                                  4,
                                ),
                                child: Row(
                                  children: [
                                    TypingDots(color: p.accent),
                                    const SizedBox(width: 8),
                                    Text(
                                      widget.group
                                          ? '${typing.map(e.nameOf).take(2).join(', ')} typing'
                                          : 'typing',
                                      style: Txt.mono(p.muted, size: 11),
                                    ),
                                  ],
                                ),
                              ),
                      );
                    }
                    final row = rows[idx - 1];
                    if (row is String) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: Space.md),
                        child: Center(
                          child: Text(
                            row.toUpperCase(),
                            style: Txt.label(p.faint),
                          ),
                        ),
                      );
                    }
                    final i = row as int;
                    final m = msgs[i];
                    final prev = i > 0 ? msgs[i - 1] : null;
                    final next = i < msgs.length - 1 ? msgs[i + 1] : null;
                    bool same(MessageView? a, MessageView b) =>
                        a != null &&
                        a.author == b.author &&
                        (a.ts - b.ts).abs() < 180000 &&
                        dayLabel(a.ts) == dayLabel(b.ts);
                    final key = anchor[i] ?? ValueKey('dup-$i-${m.id}');
                    return KeyedSubtree(
                      key: key,
                      child: Bubble(
                        m: m,
                        scope: widget.scope,
                        firstInGroup: !same(prev, m),
                        lastInGroup: !same(next, m),
                        showAuthor: widget.group,
                        highlight: _highlight == m.id,
                        onLongPress: () => _actions(m),
                        onReply: () => setState(() => _replyTo = m),
                        onTapReply: () => _jumpTo(m.replyTo),
                      ),
                    );
                  },
                ),
        ),
        Composer(
          scope: widget.scope,
          replyTo: _replyTo,
          editing: _editing,
          onCancelReply: () => setState(() => _replyTo = null),
          onCancelEdit: () => setState(() => _editing = null),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.k, this.v);
  final String k;
  final String v;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(k.toUpperCase(), style: Txt.label(p.muted)),
          ),
          Expanded(child: Text(v, style: Txt.small(p.ink))),
        ],
      ),
    );
  }
}
