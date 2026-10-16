import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mentos/core/theme/app_theme.dart';
import 'package:mentos/core/theme/tokens.dart';
import 'package:mentos/widgets/input_sheet.dart';

void main() {
  Future<void> show(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      MaterialApp(theme: buildTheme(Palette.light), home: home),
    );
  }

  Future<void> frames(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets(
    'prompt keeps the field, count, and suggestions above the keyboard',
    (tester) async {
      String? result;
      await show(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await prompt(
                  context,
                  title: 'Nickname',
                  body: 'Only you see this',
                  initial: 'Ada',
                  action: 'Save',
                  suggestions: const ['Ada', 'Bo'],
                  selectAll: true,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await frames(tester);
      expect(find.text('Nickname'), findsOneWidget);
      expect(find.text('Only you see this'), findsOneWidget);
      expect(find.text('3 / 80'), findsOneWidget);
      expect(find.text('Bo'), findsOneWidget);
      expect(tester.takeException(), isNull);

      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await frames(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Save'), findsOneWidget);

      await tester.tap(find.text('Bo'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await frames(tester);
      expect(result, 'Bo');
    },
  );

  testWidgets('a tag sheet previews the slug and refuses one already used', (
    tester,
  ) async {
    ({String name, String about})? result;
    await show(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result = await askNamed(
                context,
                title: 'New room',
                action: 'Create',
                slug: true,
                hideAbout: true,
                taken: const ['general'],
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await frames(tester);
    await tester.enterText(find.byType(TextField), 'Hello room');
    await tester.pump();
    expect(find.text('#hello-room'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'general');
    await tester.pump();
    expect(find.text('#general is already used'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Create'))
          .onPressed,
      isNull,
    );

    await tester.enterText(find.byType(TextField), 'trading');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await frames(tester);
    expect(result?.name, 'trading');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a delay sheet turns a chip into minutes', (tester) async {
    int? result;
    await show(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result = await pickMinutes(
                context,
                title: 'Post later',
                body: 'Publishes from this phone.',
                action: 'Schedule',
                choices: const [15, 60],
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await frames(tester);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Schedule'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('1 hour'));
    await tester.pump();
    await tester.tap(find.text('Schedule · 1 hour'));
    await frames(tester);
    expect(result, 60);
    expect(tester.takeException(), isNull);
  });
}
