import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models.dart';
import '../../widgets/ui.dart';

const storyReactions = ['❤️', '😂', '😮', '😢', '🔥', '👏'];
const _emojiStickers = [
  '😀',
  '😂',
  '🥹',
  '😍',
  '😎',
  '🤯',
  '🥳',
  '😴',
  '🤔',
  '🙌',
  '👀',
  '💯',
  '🔥',
  '✨',
  '🎉',
  '❤️',
  '💚',
  '🌙',
  '☀️',
  '🌧️',
  '🍕',
  '☕',
  '🎧',
  '📍',
];

/// One sticker as it appears on a story.
class StickerChip extends StatelessWidget {
  const StickerChip({super.key, required this.sticker, this.name});
  final StorySticker sticker;

  /// Display name for a mention.
  final String? name;

  @override
  Widget build(BuildContext context) {
    final s = sticker;
    Widget pill(
      Widget child, {
      Color bg = Colors.white,
      EdgeInsets? pad,
    }) => Container(
      padding: pad ?? const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Radii.md),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 2)),
        ],
      ),
      child: child,
    );
    final child = switch (s.kind) {
      StickerKind.emoji => Text(s.value, style: const TextStyle(fontSize: 56)),
      StickerKind.text => pill(
        Text(
          s.value,
          textAlign: TextAlign.center,
          style: Txt.bodyStrong(Colors.black).copyWith(fontSize: 18),
        ),
        bg: Colors.white.withValues(alpha: .92),
      ),
      StickerKind.link => pill(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.link_rounded, size: 18, color: Color(0xFF2563EB)),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: Text(
                (s.label?.isNotEmpty ?? false)
                    ? s.label!
                    : (Uri.tryParse(s.value)?.host ?? s.value),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Txt.bodyStrong(const Color(0xFF2563EB)),
              ),
            ),
          ],
        ),
      ),
      StickerKind.mention => pill(
        Text(
          '@${name ?? s.label ?? 'someone'}',
          style: Txt.bodyStrong(const Color(0xFF7C3AED)).copyWith(fontSize: 17),
        ),
      ),
      StickerKind.ask => pill(
        SizedBox(
          width: 210,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                s.value,
                textAlign: TextAlign.center,
                style: Txt.bodyStrong(Colors.black),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F1F1),
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Text(
                  'Type something…',
                  textAlign: TextAlign.center,
                  style: Txt.small(Colors.black45),
                ),
              ),
            ],
          ),
        ),
        pad: const EdgeInsets.all(12),
      ),
    };
    return Transform.scale(scale: s.scale, child: child);
  }
}

/// Stickers on a story being watched. Links open, mentions open the
/// profile, and a question opens the reply box with the question attached.
class StickerLayer extends StatelessWidget {
  const StickerLayer({
    super.key,
    required this.stickers,
    required this.nameOf,
    this.onAsk,
    this.onPause,
  });
  final List<StorySticker> stickers;
  final String Function(String id) nameOf;
  final ValueChanged<String>? onAsk;
  final VoidCallback? onPause;

  Future<void> _open(BuildContext context, StorySticker s) async {
    onPause?.call();
    switch (s.kind) {
      case StickerKind.link:
        final uri = Uri.parse(s.value);
        final go = await confirm(
          context,
          title: 'Open link?',
          body: s.value,
          action: 'Open',
        );
        if (go) await launchUrl(uri, mode: LaunchMode.externalApplication);
      case StickerKind.mention:
        GoRouter.of(context).push('/u/${s.value}');
      case StickerKind.ask:
        onAsk?.call(s.value);
      case StickerKind.emoji || StickerKind.text:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        return Stack(
          children: [
            for (final s in stickers)
              Positioned(
                left: s.x * c.maxWidth,
                top: s.y * c.maxHeight,
                child: FractionalTranslation(
                  translation: const Offset(-.5, -.5),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap:
                        s.kind == StickerKind.emoji ||
                            s.kind == StickerKind.text
                        ? null
                        : () => _open(context, s),
                    child: StickerChip(
                      sticker: s,
                      name: s.kind == StickerKind.mention
                          ? nameOf(s.value)
                          : null,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Stickers on a story being composed: drag to move, pinch to resize,
/// long-press to remove.
class EditableStickerLayer extends StatelessWidget {
  const EditableStickerLayer({
    super.key,
    required this.stickers,
    required this.onChanged,
    required this.nameOf,
  });
  final List<StorySticker> stickers;
  final ValueChanged<List<StorySticker>> onChanged;
  final String Function(String id) nameOf;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        return Stack(
          children: [
            for (final (i, s) in stickers.indexed)
              Positioned(
                left: s.x * c.maxWidth,
                top: s.y * c.maxHeight,
                child: FractionalTranslation(
                  translation: const Offset(-.5, -.5),
                  child: _Draggable(
                    sticker: s,
                    size: c.biggest,
                    onChanged: (next) => onChanged([...stickers]..[i] = next),
                    onRemove: () => onChanged([...stickers]..removeAt(i)),
                    child: StickerChip(
                      sticker: s,
                      name: s.kind == StickerKind.mention
                          ? nameOf(s.value)
                          : null,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Draggable extends StatefulWidget {
  const _Draggable({
    required this.sticker,
    required this.size,
    required this.onChanged,
    required this.onRemove,
    required this.child,
  });
  final StorySticker sticker;
  final Size size;
  final ValueChanged<StorySticker> onChanged;
  final VoidCallback onRemove;
  final Widget child;

  @override
  State<_Draggable> createState() => _DraggableState();
}

class _DraggableState extends State<_Draggable> {
  double _startScale = 1;

  @override
  Widget build(BuildContext context) {
    final s = widget.sticker;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onScaleStart: (_) => _startScale = s.scale,
      onScaleUpdate: (d) {
        final w = widget.size.width <= 0 ? 1 : widget.size.width;
        final h = widget.size.height <= 0 ? 1 : widget.size.height;
        widget.onChanged(
          s.copyWith(
            x: (s.x + d.focalPointDelta.dx / w).clamp(0.0, 1.0),
            y: (s.y + d.focalPointDelta.dy / h).clamp(0.0, 1.0),
            scale: d.pointerCount > 1
                ? (_startScale * d.scale).clamp(.5, 3.0)
                : s.scale,
          ),
        );
      },
      onLongPress: () async {
        final ok = await confirm(
          context,
          title: 'Remove sticker?',
          body: 'It comes off this story.',
          action: 'Remove',
          danger: true,
        );
        if (ok) widget.onRemove();
      },
      child: widget.child,
    );
  }
}

/// Lets the person pick and fill in a sticker. [people] are (id, name)
/// pairs that can be mentioned.
Future<StorySticker?> pickSticker(
  BuildContext context,
  List<(String, String)> people,
) async {
  final kind = await showModalBottomSheet<Object>(
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
              Text('Stickers', style: Txt.title(p.ink)),
              const SizedBox(height: Space.md),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (k, icon, label) in [
                    (StickerKind.text, Icons.text_fields_rounded, 'Text'),
                    (StickerKind.link, Icons.link_rounded, 'Link'),
                    (
                      StickerKind.mention,
                      Icons.alternate_email_rounded,
                      'Mention',
                    ),
                    (StickerKind.ask, Icons.help_outline_rounded, 'Question'),
                  ])
                    ActionChip(
                      avatar: Icon(icon, size: 18),
                      label: Text(label),
                      onPressed: () => Navigator.pop(ctx, k),
                    ),
                ],
              ),
              const SizedBox(height: Space.lg),
              GridView.count(
                crossAxisCount: 8,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final e in _emojiStickers)
                    InkWell(
                      onTap: () => Navigator.pop(ctx, e),
                      child: Center(
                        child: Text(e, style: const TextStyle(fontSize: 26)),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
  if (kind == null || !context.mounted) return null;
  if (kind is String) return StorySticker(kind: StickerKind.emoji, value: kind);
  switch (kind as StickerKind) {
    case StickerKind.text:
      final t = await prompt(
        context,
        title: 'Text sticker',
        body: 'It lands on the story. Drag and pinch it after.',
        hint: 'Say it',
        action: 'Add',
        maxLength: 120,
        allowEmpty: false,
        multiline: true,
        minLines: 2,
      );
      if (t == null || t.trim().isEmpty) return null;
      return StorySticker(kind: StickerKind.text, value: t.trim(), y: .3);
    case StickerKind.ask:
      final t = await prompt(
        context,
        title: 'Ask a question',
        body: 'People reply from the story. You can move it after.',
        initial: 'Ask me anything',
        action: 'Add',
        maxLength: 120,
        allowEmpty: false,
        selectAll: true,
        multiline: true,
        minLines: 2,
      );
      if (t == null || t.trim().isEmpty) return null;
      return StorySticker(kind: StickerKind.ask, value: t.trim(), y: .62);
    case StickerKind.link:
      return showInputSheet<StorySticker>(context, (_) => const _LinkSheet());
    case StickerKind.mention:
      if (people.isEmpty) {
        toast(context, 'Connect with someone first');
        return null;
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
                for (final (id, name) in people)
                  ListTile(
                    title: Text(name),
                    onTap: () => Navigator.pop(ctx, id),
                  ),
              ],
            ),
          ),
        ),
      );
      if (id == null) return null;
      return StorySticker(
        kind: StickerKind.mention,
        value: id,
        label: people.firstWhere((x) => x.$1 == id).$2,
        y: .4,
      );
    case StickerKind.emoji:
      return null;
  }
}

class _LinkSheet extends StatefulWidget {
  const _LinkSheet();

  @override
  State<_LinkSheet> createState() => _LinkSheetState();
}

class _LinkSheetState extends State<_LinkSheet> {
  final _url = TextEditingController();
  final _label = TextEditingController();

  @override
  void dispose() {
    _url.dispose();
    _label.dispose();
    super.dispose();
  }

  String get _normalized {
    var t = _url.text.trim();
    if (t.isEmpty) return '';
    if (!t.contains('://')) t = 'https://$t';
    return t;
  }

  StorySticker? get _sticker {
    final url = _normalized;
    if (url.isEmpty) return null;
    final parsed = StorySticker.fromJson({'t': 'link', 'v': url});
    if (parsed == null) return null;
    final label = _label.text.trim();
    return StorySticker(
      kind: StickerKind.link,
      value: url,
      label: label.isEmpty ? null : label,
      y: .72,
    );
  }

  String? get _host {
    final u = Uri.tryParse(_normalized);
    if (u == null || u.host.isEmpty) return null;
    return u.host;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final sticker = _sticker;
    final host = _host;
    final typed = _url.text.trim().isNotEmpty;
    return InputSheet(
      title: 'Link sticker',
      body: 'Opens in the browser. A label replaces the address on the story.',
      action: 'Add',
      enabled: sticker != null,
      onAction: () => Navigator.pop(context, sticker),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetLabel('Link', trailing: '${_url.text.length}/300'),
          TextField(
            controller: _url,
            autofocus: true,
            maxLength: 300,
            keyboardType: TextInputType.url,
            textCapitalization: TextCapitalization.none,
            autocorrect: false,
            enableSuggestions: false,
            smartDashesType: SmartDashesType.disabled,
            smartQuotesType: SmartQuotesType.disabled,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'example.com',
              counterText: '',
            ),
          ),
          const SizedBox(height: 6),
          Text(
            !typed
                ? 'https:// is added if you leave it off.'
                : (sticker == null
                      ? 'That does not look like a web link'
                      : host ?? ''),
            style: typed && sticker == null
                ? Txt.small(p.danger)
                : Txt.mono(p.muted, size: 12),
          ),
          const SizedBox(height: Space.lg),
          SheetLabel('Label', trailing: '${_label.text.length}/60'),
          TextField(
            controller: _label,
            maxLength: 60,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (sticker != null) Navigator.pop(context, sticker);
            },
            decoration: InputDecoration(
              hintText: host ?? 'Optional',
              counterText: '',
            ),
          ),
        ],
      ),
    );
  }
}
