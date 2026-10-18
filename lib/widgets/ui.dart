import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/app_theme.dart';
import '../core/theme/tokens.dart';
import '../data/models.dart';

export 'input_sheet.dart';

/// Small mono label used as a section eyebrow.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing, this.padding});
  final String text;
  final Widget? trailing;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding:
          padding ??
          const EdgeInsets.fromLTRB(
            Space.gutter,
            Space.xl,
            Space.gutter,
            Space.sm,
          ),
      child: Row(
        children: [
          Expanded(child: Text(text.toUpperCase(), style: Txt.label(p.muted))),
          ?trailing,
        ],
      ),
    );
  }
}

/// Where a piece of content lives right now. The signature of the app:
/// live (author reachable), kept (a copy someone agreed to hold), or local.
enum Provenance { live, kept, local, mine }

class ProvenanceTag extends StatelessWidget {
  const ProvenanceTag(this.kind, {super.key, this.compact = false});
  final Provenance kind;
  final bool compact;

  static Provenance of(Item i) =>
      i.owned ? Provenance.mine : (i.kept ? Provenance.kept : Provenance.live);

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final (label, fg, bg, filled) = switch (kind) {
      Provenance.live => ('live', p.accent, p.accentSoft, true),
      Provenance.kept => ('kept', p.inkSoft, p.raised, false),
      Provenance.local => ('local', p.muted, p.raised, false),
      Provenance.mine => ('yours', p.muted, Colors.transparent, false),
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 5 : 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Radii.pill),
        border: kind == Provenance.mine ? Border.all(color: p.line) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: filled ? fg : Colors.transparent,
              border: filled ? null : Border.all(color: fg, width: 1),
            ),
          ),
          const SizedBox(width: 4),
          Text(label, style: Txt.mono(fg, size: 10, w: FontWeight.w500)),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.action,
    this.compact = false,
  });
  final IconData icon;
  final String title;
  final String? body;
  final Widget? action;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    // Scrolls instead of overflowing when it lands in a short box.
    return Center(
      child: SingleChildScrollView(
        primary: false,
        padding: EdgeInsets.symmetric(
          horizontal: 40,
          vertical: compact ? 24 : 48,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: p.raised,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(icon, color: p.muted, size: 24),
            ),
            const SizedBox(height: Space.lg),
            Text(title, style: Txt.heading(p.ink), textAlign: TextAlign.center),
            if (body != null) ...[
              const SizedBox(height: Space.sm),
              Text(
                body!,
                style: Txt.small(p.muted),
                textAlign: TextAlign.center,
              ),
            ],
            if (action != null) ...[const SizedBox(height: Space.xl), action!],
          ],
        ),
      ),
    );
  }
}

class IconBtn extends StatelessWidget {
  const IconBtn(
    this.icon, {
    super.key,
    this.onTap,
    this.color,
    this.size = 22,
    this.tooltip,
    this.active = false,
  });
  final IconData icon;
  final VoidCallback? onTap;
  final Color? color;
  final double size;
  final String? tooltip;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final btn = InkResponse(
      onTap: onTap == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              onTap!();
            },
      radius: 22,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Icon(
          icon,
          size: size,
          color:
              color ?? (active ? p.accent : (onTap == null ? p.faint : p.ink)),
        ),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

/// Subtle press-down scale for tappable surfaces.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
  });
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              HapticFeedback.mediumImpact();
              widget.onLongPress!();
            },
      child: AnimatedScale(
        scale: _down ? .98 : 1,
        duration: Motion.fast,
        curve: Motion.curve,
        child: widget.child,
      ),
    );
  }
}

class SheetAction {
  const SheetAction(
    this.icon,
    this.label,
    this.onTap, {
    this.danger = false,
    this.subtitle,
  });
  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;
  final bool danger;
}

Future<void> showActions(
  BuildContext context,
  List<SheetAction> actions, {
  String? title,
  Widget? header,
}) {
  return showModalBottomSheet(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (ctx) {
      final p = ctx.pal;
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ?header,
            if (title != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.gutter,
                  0,
                  Space.gutter,
                  Space.sm,
                ),
                child: Text(title, style: Txt.label(p.muted)),
              ),
            for (final a in actions)
              ListTile(
                leading: Icon(
                  a.icon,
                  color: a.danger ? p.danger : p.ink,
                  size: 22,
                ),
                title: Text(
                  a.label,
                  style: Txt.bodyStrong(a.danger ? p.danger : p.ink),
                ),
                subtitle: a.subtitle == null ? null : Text(a.subtitle!),
                onTap: () {
                  Navigator.pop(ctx);
                  a.onTap();
                },
              ),
            const SizedBox(height: Space.sm),
          ],
        ),
      );
    },
  );
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
  bool danger = false,
}) async {
  final p = context.pal;
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text('Cancel', style: Txt.bodyStrong(p.muted)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action, style: Txt.bodyStrong(danger ? p.danger : p.ink)),
        ),
      ],
    ),
  );
  return r ?? false;
}

void toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
}

class CountBadge extends StatelessWidget {
  const CountBadge(this.count, {super.key, this.muted = false});
  final int count;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    if (count <= 0) return const SizedBox.shrink();
    return Container(
      constraints: const BoxConstraints(minWidth: 20),
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: muted ? p.raised : p.accent,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: Txt.mono(
          muted ? p.muted : p.accentInk,
          size: 11,
          w: FontWeight.w500,
        ),
      ),
    );
  }
}

/// A row in settings-like lists.
class RowTile extends StatelessWidget {
  const RowTile({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.trailing,
    this.onTap,
    this.danger = false,
  });
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.gutter,
          vertical: 14,
        ),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 21, color: danger ? p.danger : p.inkSoft),
              const SizedBox(width: Space.lg),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Txt.bodyStrong(danger ? p.danger : p.ink)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!, style: Txt.small(p.muted)),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: Space.md),
              trailing!,
            ],
            if (trailing == null && onTap != null)
              Icon(Icons.chevron_right_rounded, color: p.faint, size: 20),
          ],
        ),
      ),
    );
  }
}

class SwitchTile extends StatelessWidget {
  const SwitchTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.icon,
  });
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => RowTile(
    title: title,
    subtitle: subtitle,
    icon: icon,
    onTap: onChanged == null ? null : () => onChanged!(!value),
    trailing: Switch(value: value, onChanged: onChanged),
  );
}

/// Segmented control: flat, ink-on-paper.
class Segmented<T> extends StatelessWidget {
  const Segmented({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
  });
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: p.raised,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(
        children: [
          for (final e in options.entries)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(e.key),
                child: AnimatedContainer(
                  duration: Motion.fast,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: e.key == value ? p.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(Radii.sm + 1),
                    border: e.key == value ? Border.all(color: p.line) : null,
                  ),
                  child: Text(
                    e.value,
                    style: Txt.small(e.key == value ? p.ink : p.muted)
                        .copyWith(fontWeight: FontWeight.w500),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class Hairline extends StatelessWidget {
  const Hairline({super.key, this.indent = 0});
  final double indent;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(left: indent),
    child: Container(height: 1, color: context.pal.line),
  );
}

class Loading extends StatelessWidget {
  const Loading({super.key});
  @override
  Widget build(BuildContext context) => Center(
    child: SizedBox(
      width: 20,
      height: 20,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: context.pal.muted,
      ),
    ),
  );
}
