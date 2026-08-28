import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:showup/app.dart';

void main() {
  testWidgets('reference onboarding requires two interests before photo', (
    tester,
  ) async {
    // Onboarding is a tall ListView; the default 800x600 surface leaves the submit button
    // unbuilt, so the finder sees nothing rather than a disabled button.
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const ShowUpApp());
    await tester.pump();

    // The introduction is informational, exactly like the mock, so Continue is available.
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
    await tester.tap(find.text('Continue'));
    await tester.pump();

    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await tester.tap(find.text('Books'));
    await tester.tap(find.text('Hiking'));
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );

    // MockRepository.signIn() simulates latency; let it land before the tree is torn
    // down, or the binding fails the test on a pending timer.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('skipping onboarding opens the reference product shell', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393 * 3, 852 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const ShowUpApp());
    await tester.pump();
    await tester.tap(find.text('Skip onboarding'));
    await tester.pumpAndSettle();

    expect(find.text('Tables looking for one more'), findsOneWidget);
    expect(find.text('My groups'), findsOneWidget);
    // Mock sign-in intentionally has a short latency; settle it before teardown so this
    // navigation assertion does not leave repository infrastructure pending.
    await tester.pump(const Duration(seconds: 1));
  });
}
