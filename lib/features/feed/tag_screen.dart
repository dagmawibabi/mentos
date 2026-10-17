import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../net/engine.dart';
import '../../net/views.dart';
import '../../state/providers.dart';
import '../../widgets/ui.dart';
import 'post_card.dart';

/// Posts with one hashtag, gathered from everything this phone can see:
/// the home feed and every space it belongs to. There is no global index;
/// the page grows as more of the network reaches this phone.
final taggedProvider = StreamProvider.autoDispose.family<List<PostView>, String>((ref, tag) {
  final e = ref.watch(maybeEngineProvider);
  if (e == null) return Stream.value(const []);
  return e.watch((k) => k.contains(Ch.feed) || k.any((x) => x.startsWith('item:') || x.startsWith('sfeed:')), () => e.tagged(tag));
});

class TagScreen extends ConsumerWidget {
  const TagScreen({super.key, required this.tag});
  final String tag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final posts = ref.watch(taggedProvider(tag)).value ?? const <PostView>[];
    final e = ref.watch(engineProvider);
    final related = e.trendingTags(limit: 16).where((t) => t.tag != tag.toLowerCase()).toList();
    return Scaffold(
      appBar: AppBar(title: Text('#$tag')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, 0),
            child: Text(
              '${posts.length} ${posts.length == 1 ? 'post' : 'posts'} on this phone',
              style: Txt.small(p.muted),
            ),
          ),
          if (related.isNotEmpty)
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: 8),
                children: [
                  for (final t in related)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ActionChip(
                        label: Text('#${t.tag}'),
                        onPressed: () => context.pushReplacement('/tag/${Uri.encodeComponent(t.tag)}'),
                      ),
                    ),
                ],
              ),
            ),
          if (posts.isEmpty)
            const EmptyState(
              icon: Icons.tag_rounded,
              title: 'Nothing here yet',
              body: 'Posts from people you follow and spaces you are in show up when they use this tag.',
            ),
          for (final post in posts) PostCard(key: ValueKey(post.id), post: post),
        ],
      ),
    );
  }
}

/// Post text with tappable #tags and @mentions highlighted.
class TaggedText extends StatelessWidget {
  const TaggedText({super.key, required this.text, required this.style, this.maxLines});
  final String text;
  final TextStyle style;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final matches = Engine.hashtag.allMatches(text).toList();
    if (matches.isEmpty) {
      return Text(text, style: style, maxLines: maxLines, overflow: maxLines == null ? null : TextOverflow.ellipsis);
    }
    final spans = <InlineSpan>[];
    var at = 0;
    for (final m in matches) {
      if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
      final tag = m.group(1)!;
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: GestureDetector(
            onTap: () => context.push('/tag/${Uri.encodeComponent(tag.toLowerCase())}'),
            child: Text('#$tag', style: style.copyWith(color: p.accent, fontWeight: FontWeight.w500)),
          ),
        ),
      );
      at = m.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: maxLines,
      overflow: maxLines == null ? TextOverflow.visible : TextOverflow.ellipsis,
    );
  }
}
