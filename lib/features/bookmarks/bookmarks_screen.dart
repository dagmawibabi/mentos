import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../state/providers.dart';
import '../../widgets/ui.dart';
import '../feed/post_card.dart';

class BookmarksScreen extends ConsumerWidget {
  const BookmarksScreen({super.key, this.embedded = false});
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.pal;
    final posts = ref.watch(bookmarksProvider).value ?? const [];
    final hidden = ref.read(engineProvider).hiddenBookmarks().first;
    final body = posts.isEmpty && hidden == 0
        ? const EmptyState(
            icon: Icons.bookmark_border_rounded,
            title: 'No bookmarks',
            body: 'Tap the bookmark on any post to find it here later.',
          )
        : ListView(
            padding: const EdgeInsets.fromLTRB(0, Space.sm, 0, Space.xl),
            children: [
              if (hidden > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.gutter, Space.sm),
                  child: Text(
                    '$hidden saved ${hidden == 1 ? 'post is' : 'posts are'} hidden until ${hidden == 1 ? 'its author is' : 'their authors are'} online. '
                    'Bookmarks remember where a post is, not a copy of it.',
                    style: Txt.mono(p.faint, size: 11),
                  ),
                ),
              for (final post in posts) PostCard(post: post),
            ],
          );
    if (embedded) return body;
    return Scaffold(appBar: AppBar(title: const Text('Bookmarks')), body: body);
  }
}
