import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:showup/core/theme.dart';
import 'package:showup/data/mock_repository.dart';
import 'package:showup/features/onboarding/onboarding_screen.dart';
import 'package:showup/reference_app.dart';
import 'package:showup/state/app_state.dart';

void main() {
  testWidgets('approved onboarding collects every production field', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const ReferenceShowUpApp());
    await tester.pump();

    expect(
      find.text('A table of four to six people who all came alone.'),
      findsOneWidget,
    );
    expect(find.text('Continue'), findsOneWidget);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('A little about you'), findsOneWidget);
    expect(find.byKey(const Key('display-name-input')), findsOneWidget);
    expect(find.byKey(const Key('phone-input')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('display-name-input')),
      'Julius',
    );
    await tester.enterText(
      find.byKey(const Key('phone-input')),
      '(415) 555-0123',
    );
    await tester.pump();
    tester.testTextInput.hide();
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('What would you actually show up for?'), findsOneWidget);
    expect(find.text('Slow coffee'), findsOneWidget);
    expect(find.text('Live music'), findsOneWidget);
    expect(find.text('Add your own interest'), findsOneWidget);

    // The reference requires two interests, so one selection cannot advance the flow.
    await tester.tap(find.text('Slow coffee'));
    await tester.pump();
    expect(find.text('Add a photo'), findsNothing);

    await tester.tap(find.text('Live music'));
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Add a photo'), findsOneWidget);
    expect(find.text('Tap to upload'), findsOneWidget);
    expect(find.text('What are you passionate about?'), findsOneWidget);
    expect(find.text('Find my table'), findsOneWidget);
  });

  testWidgets('production completion submits interests and photo', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final repo = MockRepository();
    final state = AppState(repo);
    var completed = false;
    addTearDown(repo.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: OnboardingScreen(
          state,
          pickPhoto: () async => XFile('assets/mock/maya.jpg'),
          onComplete: () => completed = true,
        ),
      ),
    );

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('display-name-input')),
      'Julius',
    );
    await tester.enterText(find.byKey(const Key('phone-input')), '4155550123');
    await tester.pump();
    tester.testTextInput.hide();
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Slow coffee'));
    await tester.enterText(
      find.byKey(const Key('custom-interest-input')),
      'Robotics',
    );
    await tester.tap(find.byKey(const Key('add-custom-interest')));
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tap to upload'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('about-yourself-input')),
      'I build small robots and can talk about hardware all night.',
    );
    await tester.pump();
    await tester.tap(find.text('Find my table'));
    // This focused harness does not include app.dart's ListenableBuilder, so the completed
    // phase cannot replace the still-spinning onboarding route. Advance through the mock network
    // delay directly and assert the state transition instead of waiting for a tree swap that only
    // the full shell owns.
    await tester.pump(const Duration(seconds: 1));

    expect(completed, isTrue);
    expect(await repo.hasProfile(), isTrue);
  });

  testWidgets('production onboarding rejects an incomplete private phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final repo = MockRepository();
    final state = AppState(repo);
    addTearDown(repo.dispose);
    await tester.pumpWidget(
      MaterialApp(theme: buildTheme(), home: OnboardingScreen(state)),
    );
    await tester.pump();

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('display-name-input')),
      'Julius',
    );
    await tester.enterText(find.byKey(const Key('phone-input')), '415');
    await tester.tap(find.text('Continue'));
    await tester.pump();
    expect(find.text('A little about you'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('phone-input')), '4155550123');
    await tester.pump();
    tester.testTextInput.hide();
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('What would you actually show up for?'), findsOneWidget);
  });
}
