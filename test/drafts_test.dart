import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/core/theme/app_theme.dart';
import 'package:mentos/core/theme/tokens.dart';
import 'package:mentos/features/feed/drafts_screen.dart';
import 'package:mentos/net/views.dart';
import 'package:mentos/state/session.dart';

class _SignedOut extends SessionNotifier {
  @override
  Session build() => const SessionSignedOut();
}

void main() {
  test('scheduled rows saved before they had an id still load', () {
    final post = HeldPost.fromJson({
      'text': 'later',
      'at': 1_700_000_000_000,
      'ai': true,
      'nsfw': true,
    });
    expect(post, isNotNull);
    expect(post!.id, isEmpty);
    expect(post.text, 'later');
    expect(post.ai, isTrue);
    expect(post.nsfw, isTrue);
    expect(post.keep, isTrue);
    expect(post.key, isNotEmpty);

    final again = HeldPost.fromJson(post.copyWith(id: 'abc').toJson());
    expect(again!.id, 'abc');
    expect(again.text, 'later');
    expect(again.ai, isTrue);
  });

  test('a draft keeps its poll and where it will post', () {
    final post = HeldPost(
      id: 'd1',
      text: '',
      title: 'Thread',
      at: 10,
      spaceId: 'space',
      boardId: 'ideas',
      poll: const Poll('Pick one', ['a', 'b']),
    );
    final loaded = HeldPost.fromJson(post.toJson());
    expect(loaded!.title, 'Thread');
    expect(loaded.spaceId, 'space');
    expect(loaded.boardId, 'ideas');
    expect(loaded.poll!.options, ['a', 'b']);
    expect(loaded.preview, 'Thread');
    expect(loaded.hasBody, isTrue);
  });

  testWidgets('drafts screen explains the empty list', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWith(_SignedOut.new)],
        child: MaterialApp(
          theme: buildTheme(Palette.light),
          home: const DraftsScreen(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Nothing waiting'), findsOneWidget);
    expect(find.textContaining('Schedule a post'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
