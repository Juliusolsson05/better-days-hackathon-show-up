import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:showup/app.dart';

void main() {
  testWidgets('onboarding gates submit until the profile is complete', (tester) async {
    // Onboarding is a tall ListView; the default 800x600 surface leaves the submit button
    // unbuilt, so the finder sees nothing rather than a disabled button.
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const ShowUpApp());
    await tester.pump();

    // The one decision this product asks for should not be reachable from an empty form:
    // an unmatchable profile is worse than no profile.
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);

    await tester.enterText(find.byType(TextField).first, 'Julius');
    await tester.enterText(
        find.byType(TextField).last, 'I boulder four times a week and read routes badly.');
    await tester.tap(find.text('climbing'));
    await tester.pump();

    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);

    // MockRepository.signIn() simulates latency; let it land before the tree is torn
    // down, or the binding fails the test on a pending timer.
    await tester.pump(const Duration(seconds: 1));
  });
}
