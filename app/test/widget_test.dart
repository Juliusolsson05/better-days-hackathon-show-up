import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:showup/app.dart';
import 'package:showup/core/theme.dart';
import 'package:showup/data/mock_repository.dart';
import 'package:showup/features/onboarding/onboarding_screen.dart';
import 'package:showup/models/models.dart';
import 'package:showup/state/app_state.dart';

void main() {
  testWidgets('approved onboarding follows the three reference steps', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Supabase is now the safe default for every real launch. Widget tests do not execute main()
    // (and therefore cannot initialize its SDK), so fixture mode must be requested explicitly.
    await tester.pumpWidget(const ShowUpApp(useMockRepositoryForTesting: true));
    await tester.pump();

    expect(
      find.text('A table of four to six people who all came alone.'),
      findsOneWidget,
    );
    expect(find.text('Continue'), findsOneWidget);

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

  testWidgets('reference completion submits interests and photo', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final repo = MockRepository();
    final state = AppState(repo, referenceUiPreview: true);
    addTearDown(repo.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: OnboardingScreen(
          state,
          pickPhoto: () async => XFile('assets/mock/maya.jpg'),
        ),
      ),
    );

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

    expect(state.phase, Phase.home);
    expect(state.me?.tags, containsAll(<String>['slow-coffee', 'robotics']));
    expect(
      state.me?.passion,
      'I build small robots and can talk about hardware all night.',
    );
  });

  testWidgets('production onboarding still requires private profile fields', (
    tester,
  ) async {
    // The live backend still requires fields absent from the approved mock. Keeping this test
    // makes the presentation split explicit until those fields receive an approved design.
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final repo = MockRepository();
    final state = AppState(repo);
    addTearDown(repo.dispose);
    await tester.pumpWidget(
      MaterialApp(theme: buildTheme(), home: OnboardingScreen(state)),
    );
    await tester.pump();

    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );

    await tester.enterText(find.byType(TextField).first, 'Julius');
    await tester.enterText(
      find.byType(TextField).last,
      'I boulder four times a week and read routes badly.',
    );
    await tester.tap(find.text('climbing'));
    await tester.pump();

    // Name/interests/passion are not enough. A photo is how groupmates recognise one another,
    // and a phone is the value mutual selection eventually discloses; allowing a profile
    // without them creates a user who can match but cannot complete the product loop.
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });
}
