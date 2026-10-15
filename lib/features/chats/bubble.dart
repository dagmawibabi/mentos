import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../net/views.dart';
import '../../state/providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/media.dart';
import '../../widgets/nsfw.dart';
import '../feed/post_card.dart';
import 'delivery_window.dart';

class Bubble extends ConsumerWidget {
  const Bubble({
    super.key,
    required this.m,
    required this.scope,
    required this.firstInGroup,
    required this.lastInGroup,
    required this.showAuthor,
    required this.onLongPress,
    required this.onReply,
    this.onTapReply,
    this.highlight = false,
  });

  final MessageView m;
  final String scope;
  final bool firstInGroup;
  final bool lastInGroup;
  final bool showAuthor;
  final VoidCallback onLongPress;
  final VoidCallback onReply;
  final VoidCallback? onTapReply;
  final bool highlight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final e = ref.read(engineProvider);
    final mine = m.mine;
    final bg = mine ? p.bubbleMine : p.surface;
    final fg = mine ? p.bubbleMineInk : p.ink;
    final sub = fg.withValues(alpha: .55);
    final visual = m.media.where((x) => x.isImage || x.isVideo).toList();
    final voice = m.media.where((x) => x.isAudio).toList();
    final files = m.media
        .where((x) => !x.isImage && !x.isVideo && !x.isAudio)
        .toList();
    final mediaOnly =
        m.text.isEmpty &&
        visual.isNotEmpty &&
        m.replyTo == null &&
        m.poll == null;

    const r = Radius.circular(Radii.bubble);
    const t = Radius.circular(6);
    final radius = BorderRadius.only(
      topLeft: !mine && !firstInGroup ? t : r,
      bottomLeft: !mine && !lastInGroup ? t : r,
      topRight: mine && !firstInGroup ? t : r,
      bottomRight: mine && !lastInGroup ? t : r,
    );

    final meta = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (m.expires != null) ...[
          Icon(
            Icons.timer_outlined,
            size: 11,
            color: mediaOnly ? Colors.white : sub,
          ),
          const SizedBox(width: 3),
        ],
        if (m.edited)
          Text(
            'edited · ',
            style: Txt.mono(mediaOnly ? Colors.white : sub, size: 10),
          ),
        Text(
          clock(m.ts),
          style: Txt.mono(mediaOnly ? Colors.white : sub, size: 10),
        ),
        if (mine) ...[
          const SizedBox(width: 4),
          _Ticks(
            d: m.delivery,
            color: mediaOnly ? Colors.white : sub,
            read: p.accent,
          ),
        ],
      ],
    );

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (m.forwarded)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.shortcut_rounded, size: 13, color: sub),
                const SizedBox(width: 4),
                Text('Forwarded', style: Txt.mono(sub, size: 10.5)),
              ],
            ),
          ),
        if (m.replyTo != null)
          GestureDetector(
            onTap: onTapReply,
            child: Container(
              margin: const EdgeInsets.fromLTRB(6, 6, 6, 0),
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
              decoration: BoxDecoration(
                color: fg.withValues(alpha: .07),
                borderRadius: BorderRadius.circular(12),
                border: Border(
                  left: BorderSide(color: mine ? p.accent : p.ink, width: 2.5),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.nameOf(m.replyTo!.author),
                    style: Txt.small(fg)
                        .copyWith(fontWeight: FontWeight.w600, fontSize: 12),
                  ),
                  Text(
                    m.replyTo!.text.isNotEmpty
                        ? m.replyTo!.text
                        : (m.replyTo!.media.isNotEmpty
                              ? _mediaLabel(m.replyTo!)
                              : 'Message'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Txt.small(sub),
                  ),
                ],
              ),
            ),
          ),
        if (visual.isNotEmpty)
          Padding(
            padding: EdgeInsets.all(mediaOnly ? 0 : 4),
            child: MediaGrid(
              media: visual,
              item: m.item,
              radius: mediaOnly ? 0 : Radii.bubble - 4,
              maxHeight: 320,
            ),
          ),
        for (final v in voice)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 12, 2),
            child: VoicePlayer(media: v, item: m.item, fg: fg, track: bg),
          ),
        for (final f in files)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
            child: FileTile(
              media: f,
              item: m.item,
              fg: fg,
              bg: fg.withValues(alpha: .06),
            ),
          ),
        if (m.poll != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: SizedBox(
              width: 240,
              child: PollView(
                state: m.poll!,
                fg: fg,
                track: fg.withValues(alpha: .08),
                onVote: (i) =>
                    e.vote(scope, m.id, m.poll!.myVote == i ? null : i),
              ),
            ),
          ),
        if (m.text.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Text(m.text, style: Txt.body(fg).copyWith(height: 1.38)),
          ),
        if (!mediaOnly)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 10, 7),
            child: Align(
              alignment: Alignment.centerRight,
              widthFactor: 1,
              child: meta,
            ),
          ),
      ],
    );

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showAuthor && !mine)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Text(
              e.nameOf(m.author),
              style: Txt.small(p.inkSoft)
                  .copyWith(fontWeight: FontWeight.w600, fontSize: 12.5),
            ),
          ),
        NsfwGate(nsfw: m.nsfw, child: body),
      ],
    );

    final bubble = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * .78,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: radius,
        border: mine ? null : Border.all(color: p.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: mediaOnly
          ? Stack(
              children: [
                content,
                Positioned(
                  right: 8,
                  bottom: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: meta,
                  ),
                ),
              ],
            )
          : content,
    );

    final reactions = m.reactionCounts;

    return _SwipeToReply(
      onReply: onReply,
      child: AnimatedContainer(
        duration: Motion.slow,
        color: highlight ? p.accentSoft : Colors.transparent,
        padding: EdgeInsets.fromLTRB(
          Space.md,
          firstInGroup ? 6 : 1.5,
          Space.md,
          reactions.isEmpty ? 1.5 : 0,
        ),
        child: Row(
          mainAxisAlignment: mine
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (!mine && showAuthor)
              Padding(
                padding: EdgeInsets.only(
                  right: 8,
                  bottom: reactions.isEmpty ? 0 : 18,
                ),
                child: lastInGroup
                    ? Avatar(id: m.author, size: 28, presence: false)
                    : const SizedBox(width: 28),
              ),
            Flexible(
              child: GestureDetector(
                onLongPress: onLongPress,
                child: Column(
                  crossAxisAlignment: mine
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    bubble,
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.sizeOf(context).width * .78,
                      ),
                      child: MessageDeliveryProgress(
                        message: m,
                        onOpen: () => showMessageDelivery(context, e, m),
                      ),
                    ),
                    if (reactions.isNotEmpty)
                      Transform.translate(
                        offset: const Offset(0, -6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Wrap(
                            spacing: 4,
                            children: [
                              for (final r in reactions.entries)
                                GestureDetector(
                                  onTap: () {
                                    final mineR = m.reactions[e.me.id];
                                    e.react(
                                      scope,
                                      m.id,
                                      mineR == r.key ? null : r.key,
                                    );
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: m.reactions[e.me.id] == r.key
                                          ? p.accentSoft
                                          : p.surface,
                                      borderRadius: BorderRadius.circular(
                                        Radii.pill,
                                      ),
                                      border: Border.all(
                                        color: m.reactions[e.me.id] == r.key
                                            ? p.accent
                                            : p.line,
                                      ),
                                    ),
                                    child: Text(
                                      r.value > 1
                                          ? '${r.key} ${r.value}'
                                          : r.key,
                                      style: Txt.small(p.ink)
                                          .copyWith(fontSize: 13),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _mediaLabel(MessageView m) {
  final x = m.media.first;
  if (x.isVoice) return 'Voice message';
  if (x.isImage) return 'Photo';
  if (x.isVideo) return 'Video';
  if (x.isAudio) return 'Audio';
  return x.name;
}

String previewOf(MessageView m) {
  if (m.text.isNotEmpty) return m.text;
  if (m.poll != null) return 'Poll: ${m.poll!.poll.question}';
  if (m.media.isNotEmpty) return _mediaLabel(m);
  return 'Message';
}

class _Ticks extends StatelessWidget {
  const _Ticks({required this.d, required this.color, required this.read});
  final Delivery d;
  final Color color;
  final Color read;

  @override
  Widget build(BuildContext context) {
    final icon = switch (d) {
      Delivery.queued => Icon(Icons.schedule_rounded, size: 12, color: color),
      Delivery.sending => Icon(Icons.schedule_rounded, size: 12, color: color),
      Delivery.failed => Icon(
        Icons.error_outline_rounded,
        size: 13,
        color: color,
      ),
      Delivery.sent => Icon(Icons.check_rounded, size: 13, color: color),
      Delivery.delivered => Icon(
        Icons.done_all_rounded,
        size: 13,
        color: color,
      ),
      Delivery.read => Icon(Icons.done_all_rounded, size: 13, color: read),
      Delivery.cancelled => Icon(Icons.block_rounded, size: 13, color: color),
      Delivery.saved => Icon(Icons.save_outlined, size: 13, color: color),
    };
    return Tooltip(
      message: d.label,
      child: Semantics(label: d.label, child: icon),
    );
  }
}

class _SwipeToReply extends StatefulWidget {
  const _SwipeToReply({required this.child, required this.onReply});
  final Widget child;
  final VoidCallback onReply;

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply> {
  double _dx = 0;
  bool _fired = false;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return GestureDetector(
      onHorizontalDragUpdate: (d) {
        setState(() => _dx = (_dx + d.delta.dx).clamp(0, 72));
        if (_dx > 56 && !_fired) {
          _fired = true;
          widget.onReply();
        }
      },
      onHorizontalDragEnd: (_) => setState(() {
        _dx = 0;
        _fired = false;
      }),
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          Opacity(
            opacity: (_dx / 56).clamp(0, 1),
            child: Padding(
              padding: const EdgeInsets.only(left: 18),
              child: Icon(Icons.reply_rounded, color: p.muted, size: 20),
            ),
          ),
          AnimatedContainer(
            duration: _dx == 0 ? Motion.base : Duration.zero,
            curve: Motion.curve,
            transform: Matrix4.translationValues(_dx, 0, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}

/// Animated "…" while someone types.
class TypingDots extends StatefulWidget {
  const TypingDots({super.key, this.color});
  final Color? color;

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? context.pal.muted;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++)
            Container(
              width: 5,
              height: 5,
              margin: const EdgeInsets.symmetric(horizontal: 1.5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(
                  alpha:
                      .3 +
                      .7 *
                          (((_c.value * 3 - i) % 3) < 1
                              ? 1 - ((_c.value * 3 - i) % 3)
                              : 0),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
