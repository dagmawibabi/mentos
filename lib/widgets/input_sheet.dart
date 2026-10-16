import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/app_theme.dart';
import '../core/theme/tokens.dart';

/// Opens a sheet that sits above the keyboard and sizes to its content.
Future<T?> showInputSheet<T>(BuildContext context, WidgetBuilder builder) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: builder,
  );
}

/// A tappable pill. Filled ink means it is the current choice.
class SheetChip extends StatelessWidget {
  const SheetChip(
    this.label, {
    super.key,
    required this.onTap,
    this.selected = false,
  });
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Material(
      color: selected ? p.ink : p.raised,
      borderRadius: BorderRadius.circular(Radii.pill),
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        borderRadius: BorderRadius.circular(Radii.pill),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Txt.small(selected ? p.bg : p.ink)
                  .copyWith(fontWeight: FontWeight.w500),
            ),
          ),
        ),
      ),
    );
  }
}

class SheetLabel extends StatelessWidget {
  const SheetLabel(this.text, {super.key, this.trailing});
  final String text;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(child: Text(text.toUpperCase(), style: Txt.label(p.muted))),
          if (trailing != null)
            Text(trailing!, style: Txt.mono(p.faint, size: 11)),
        ],
      ),
    );
  }
}

/// Title, explanation, fields, and a full-width action pinned above the keyboard.
class InputSheet extends StatelessWidget {
  const InputSheet({
    super.key,
    required this.title,
    this.body,
    required this.child,
    required this.action,
    this.onAction,
    this.enabled = true,
    this.footer,
    this.secondary,
    this.onSecondary,
    this.secondaryDanger = false,
  });

  final String title;
  final String? body;
  final Widget child;
  final String action;
  final VoidCallback? onAction;
  final bool enabled;
  final Widget? footer;
  final String? secondary;
  final VoidCallback? onSecondary;
  final bool secondaryDanger;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    final screen = MediaQuery.sizeOf(context).height;
    // Leave room for the drag handle. The bottom padding sits under the keyboard.
    final available = math.max(48.0, screen - inset - 28);
    final maxH = math.min(available, screen * 0.92);
    final safeBottom = inset > 0 ? 0.0 : MediaQuery.paddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              fit: FlexFit.loose,
              child: ListView(
                shrinkWrap: true,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(
                  Space.gutter,
                  0,
                  Space.gutter,
                  Space.md,
                ),
                children: [
                  Text(title, style: Txt.title(p.ink)),
                  if (body != null && body!.isNotEmpty) ...[
                    const SizedBox(height: Space.sm),
                    Text(body!, style: Txt.small(p.muted)),
                  ],
                  const SizedBox(height: Space.lg),
                  child,
                  if (footer != null) ...[
                    const SizedBox(height: Space.md),
                    footer!,
                  ],
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                Space.gutter,
                0,
                Space.gutter,
                Space.lg + safeBottom,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton(
                    onPressed: enabled ? onAction : null,
                    child: Text(action),
                  ),
                  if (secondary != null)
                    TextButton(
                      onPressed: onSecondary,
                      child: Text(
                        secondary!,
                        style: Txt.bodyStrong(
                          secondaryDanger ? p.danger : p.muted,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _slug(String name) =>
    name.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9\-_]+'), '-');

/// One text value. Replaces the old alert: the field stays above the keyboard,
/// with a count, suggestions, and a reason when the value will not be accepted.
Future<String?> prompt(
  BuildContext context, {
  required String title,
  String initial = '',
  String hint = '',
  String action = 'Save',
  int maxLength = 80,
  String? body,
  List<String> suggestions = const [],
  TextInputType? keyboard,
  bool obscure = false,
  bool? multiline,
  int minLines = 1,
  bool allowEmpty = true,
  bool selectAll = false,
  String? Function(String value)? validate,
  List<TextInputFormatter>? inputFormatters,
  TextCapitalization capitalization = TextCapitalization.sentences,
}) {
  return showInputSheet<String>(
    context,
    (_) => _PromptSheet(
      title: title,
      initial: initial,
      hint: hint,
      action: action,
      maxLength: maxLength,
      body: body,
      suggestions: suggestions,
      keyboard: keyboard,
      obscure: obscure,
      multiline: multiline,
      minLines: minLines,
      allowEmpty: allowEmpty,
      selectAll: selectAll,
      validate: validate,
      inputFormatters: inputFormatters,
      capitalization: capitalization,
    ),
  );
}

class _PromptSheet extends StatefulWidget {
  const _PromptSheet({
    required this.title,
    required this.initial,
    required this.hint,
    required this.action,
    required this.maxLength,
    required this.body,
    required this.suggestions,
    required this.keyboard,
    required this.obscure,
    required this.multiline,
    required this.minLines,
    required this.allowEmpty,
    required this.selectAll,
    required this.validate,
    required this.inputFormatters,
    required this.capitalization,
  });

  final String title;
  final String initial;
  final String hint;
  final String action;
  final int maxLength;
  final String? body;
  final List<String> suggestions;
  final TextInputType? keyboard;
  final bool obscure;
  final bool? multiline;
  final int minLines;
  final bool allowEmpty;
  final bool selectAll;
  final String? Function(String value)? validate;
  final List<TextInputFormatter>? inputFormatters;
  final TextCapitalization capitalization;

  @override
  State<_PromptSheet> createState() => _PromptSheetState();
}

class _PromptSheetState extends State<_PromptSheet> {
  late final TextEditingController _c;
  bool _hide = true;
  bool _tried = false;

  bool get _multi =>
      widget.multiline ?? (widget.maxLength > 160 && !widget.obscure);

  @override
  void initState() {
    super.initState();
    final text = widget.initial.length > widget.maxLength
        ? widget.initial.substring(0, widget.maxLength)
        : widget.initial;
    _c = TextEditingController(text: text);
    if (widget.selectAll && text.isNotEmpty && !_multi) {
      _c.selection = TextSelection(baseOffset: 0, extentOffset: text.length);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  String? _problem(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return widget.allowEmpty ? null : '';
    return widget.validate?.call(raw);
  }

  bool get _ok => _problem(_c.text) == null;

  String? get _message {
    final raw = _c.text;
    final v = raw.trim();
    if (v.isEmpty)
      return _tried && !widget.allowEmpty
          ? 'Enter something to continue'
          : null;
    return widget.validate?.call(raw);
  }

  void _apply(String s) {
    final next = s.length > widget.maxLength
        ? s.substring(0, widget.maxLength)
        : s;
    _c.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
    setState(() {});
  }

  void _submit() {
    if (!_ok) {
      setState(() => _tried = true);
      return;
    }
    Navigator.pop(context, _c.text);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final lines = _multi
        ? (widget.minLines > 1
              ? widget.minLines
              : (widget.maxLength >= 1000 ? 8 : 4))
        : 1;
    final plain =
        !widget.obscure &&
        widget.keyboard != TextInputType.url &&
        widget.keyboard != TextInputType.number &&
        widget.keyboard != TextInputType.visiblePassword;
    final message = _message;
    final n = _c.text.length;
    return InputSheet(
      title: widget.title,
      body: widget.body,
      action: widget.action,
      enabled: _ok,
      onAction: _submit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _c,
            autofocus: true,
            obscureText: widget.obscure && _hide,
            keyboardType: widget.obscure
                ? TextInputType.visiblePassword
                : (_multi
                      ? TextInputType.multiline
                      : (widget.keyboard ?? TextInputType.text)),
            textCapitalization: widget.capitalization,
            textInputAction: _multi
                ? TextInputAction.newline
                : TextInputAction.done,
            minLines: lines,
            maxLines: _multi ? null : 1,
            maxLength: widget.maxLength,
            autocorrect: plain,
            enableSuggestions: plain,
            smartDashesType: widget.capitalization == TextCapitalization.none
                ? SmartDashesType.disabled
                : SmartDashesType.enabled,
            smartQuotesType: widget.capitalization == TextCapitalization.none
                ? SmartQuotesType.disabled
                : SmartQuotesType.enabled,
            inputFormatters: widget.inputFormatters,
            onChanged: (_) => setState(() {}),
            onSubmitted: _multi ? null : (_) => _submit(),
            decoration: InputDecoration(
              hintText: widget.hint.isEmpty ? null : widget.hint,
              counterText: '',
              suffix: _c.text.isEmpty && !widget.obscure
                  ? null
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_c.text.isNotEmpty)
                          IconButton(
                            tooltip: 'Clear',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 32,
                            ),
                            onPressed: () {
                              _c.clear();
                              setState(() {});
                            },
                            icon: Icon(
                              Icons.close_rounded,
                              size: 18,
                              color: p.muted,
                            ),
                          ),
                        if (widget.obscure)
                          IconButton(
                            tooltip: _hide ? 'Show' : 'Hide',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 32,
                            ),
                            onPressed: () => setState(() => _hide = !_hide),
                            icon: Icon(
                              _hide
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              size: 18,
                              color: p.muted,
                            ),
                          ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: Text(message ?? '', style: Txt.small(p.danger))),
              Text(
                '$n / ${widget.maxLength}',
                style: Txt.mono(
                  n >= widget.maxLength ? p.danger : p.faint,
                  size: 11,
                ),
              ),
            ],
          ),
          if (widget.suggestions.isNotEmpty) ...[
            const SizedBox(height: Space.md),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final s in widget.suggestions)
                  SheetChip(
                    s,
                    selected: _c.text.trim() == s,
                    onTap: () => _apply(s),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Name plus an optional description. When [slug] is set, the saved name is
/// the tag people will see (`#general`), and [taken] blocks a tag already in use.
Future<({String name, String about})?> askNamed(
  BuildContext context, {
  required String title,
  String name = '',
  String about = '',
  String action = 'Save',
  String? body,
  String nameHint = 'Name',
  String aboutHint = 'What this is for',
  int nameMax = 48,
  int aboutMax = 240,
  bool slug = false,
  bool hideAbout = false,
  List<String> taken = const [],
}) {
  return showInputSheet<({String name, String about})>(
    context,
    (_) => _NamedSheet(
      title: title,
      name: name,
      about: about,
      action: action,
      body: body,
      nameHint: nameHint,
      aboutHint: aboutHint,
      nameMax: nameMax,
      aboutMax: aboutMax,
      slug: slug,
      hideAbout: hideAbout,
      taken: taken,
    ),
  );
}

/// A short tag such as a room or board name. Returns the slug, or null if dismissed.
Future<String?> askSlug(
  BuildContext context, {
  required String title,
  String initial = '',
  String hint = 'name',
  String action = 'Create',
  String? body,
  int maxLength = 32,
  List<String> taken = const [],
}) async {
  final drafted = await askNamed(
    context,
    title: title,
    name: initial,
    action: action,
    body: body,
    nameHint: hint,
    nameMax: maxLength,
    slug: true,
    hideAbout: true,
    taken: taken,
  );
  return drafted?.name;
}

class _NamedSheet extends StatefulWidget {
  const _NamedSheet({
    required this.title,
    required this.name,
    required this.about,
    required this.action,
    required this.body,
    required this.nameHint,
    required this.aboutHint,
    required this.nameMax,
    required this.aboutMax,
    required this.slug,
    required this.hideAbout,
    required this.taken,
  });

  final String title;
  final String name;
  final String about;
  final String action;
  final String? body;
  final String nameHint;
  final String aboutHint;
  final int nameMax;
  final int aboutMax;
  final bool slug;
  final bool hideAbout;
  final List<String> taken;

  @override
  State<_NamedSheet> createState() => _NamedSheetState();
}

class _NamedSheetState extends State<_NamedSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.name,
  );
  late final TextEditingController _about = TextEditingController(
    text: widget.about,
  );

  @override
  void initState() {
    super.initState();
    if (widget.name.isNotEmpty && widget.name.length <= widget.nameMax) {
      _name.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _name.text.length,
      );
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    super.dispose();
  }

  String get _tag => _slug(_name.text);

  bool get _clash =>
      widget.slug && widget.taken.map(_slug).contains(_tag) && _tag.isNotEmpty;

  bool get _ok {
    if (_name.text.trim().isEmpty) return false;
    if (!widget.slug) return true;
    return _tag.isNotEmpty && !_clash;
  }

  String? get _hint {
    if (!widget.slug) return null;
    if (_name.text.trim().isEmpty) return 'Use letters or numbers';
    if (_tag.isEmpty) return 'Use letters, numbers, or hyphens';
    if (_clash) return '#$_tag is already used';
    return '#$_tag';
  }

  void _submit() {
    if (!_ok) return;
    final name = widget.slug ? _tag : _name.text.trim();
    Navigator.pop(context, (
      name: name,
      about: widget.hideAbout ? '' : _about.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final hint = _hint;
    final bad =
        hint != null &&
        (hint.startsWith('Use ') || hint.endsWith('already used'));
    return InputSheet(
      title: widget.title,
      body: widget.body,
      action: widget.action,
      enabled: _ok,
      onAction: _submit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetLabel(
            widget.slug ? 'Tag' : 'Name',
            trailing: '${_name.text.length}/${widget.nameMax}',
          ),
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: widget.nameMax,
            textCapitalization: widget.slug
                ? TextCapitalization.none
                : TextCapitalization.words,
            textInputAction: widget.hideAbout
                ? TextInputAction.done
                : TextInputAction.next,
            autocorrect: !widget.slug,
            smartDashesType: widget.slug
                ? SmartDashesType.disabled
                : SmartDashesType.enabled,
            smartQuotesType: widget.slug
                ? SmartQuotesType.disabled
                : SmartQuotesType.enabled,
            onChanged: (_) => setState(() {}),
            onSubmitted: widget.hideAbout ? (_) => _submit() : null,
            decoration: InputDecoration(
              hintText: widget.nameHint,
              counterText: '',
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: 6),
            Text(
              hint,
              style: bad ? Txt.small(p.danger) : Txt.mono(p.muted, size: 12),
            ),
          ],
          if (!widget.hideAbout) ...[
            const SizedBox(height: Space.lg),
            SheetLabel(
              'Description',
              trailing: '${_about.text.length}/${widget.aboutMax}',
            ),
            TextField(
              controller: _about,
              maxLength: widget.aboutMax,
              minLines: 3,
              maxLines: null,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: widget.aboutHint,
                counterText: '',
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Shown under the name. Leave it empty to skip.',
              style: Txt.small(p.faint),
            ),
          ],
        ],
      ),
    );
  }
}

String _minuteLabel(int n) {
  if (n < 60) return '$n min';
  if (n % 60 == 0) {
    final h = n ~/ 60;
    return h == 1 ? '1 hour' : '$h hours';
  }
  return '$n min';
}

/// Picks a delay in minutes, from chips or a typed number. Null if dismissed.
Future<int?> pickMinutes(
  BuildContext context, {
  required String title,
  String? body,
  String action = 'Save',
  List<int> choices = const [15, 30, 60, 180],
  int maxMinutes = 10080,
}) {
  return showInputSheet<int>(
    context,
    (_) => _MinutesSheet(
      title: title,
      body: body,
      action: action,
      choices: choices,
      maxMinutes: maxMinutes,
    ),
  );
}

class _MinutesSheet extends StatefulWidget {
  const _MinutesSheet({
    required this.title,
    required this.body,
    required this.action,
    required this.choices,
    required this.maxMinutes,
  });

  final String title;
  final String? body;
  final String action;
  final List<int> choices;
  final int maxMinutes;

  @override
  State<_MinutesSheet> createState() => _MinutesSheetState();
}

class _MinutesSheetState extends State<_MinutesSheet> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  int? get _value => int.tryParse(_c.text.trim());

  String? get _error {
    final t = _c.text.trim();
    if (t.isEmpty) return null;
    final n = _value;
    if (n == null || n < 1) return 'Enter a number of minutes';
    if (n > widget.maxMinutes)
      return 'Up to ${_minuteLabel(widget.maxMinutes)}';
    return null;
  }

  bool get _ok {
    final n = _value;
    return n != null && n >= 1 && n <= widget.maxMinutes;
  }

  void _set(int n) {
    final text = '$n';
    _c.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final n = _value;
    return InputSheet(
      title: widget.title,
      body: widget.body,
      action: _ok ? '${widget.action} · ${_minuteLabel(n!)}' : widget.action,
      enabled: _ok,
      onAction: () => Navigator.pop(context, n),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in widget.choices)
                SheetChip(
                  _minuteLabel(c),
                  selected: n == c,
                  onTap: () => _set(c),
                ),
            ],
          ),
          const SizedBox(height: Space.lg),
          SheetLabel('Minutes'),
          TextField(
            controller: _c,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (_ok) Navigator.pop(context, n);
            },
            decoration: const InputDecoration(
              hintText: 'Or type a number',
              counterText: '',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 6),
            Text(_error!, style: Txt.small(p.danger)),
          ],
        ],
      ),
    );
  }
}
