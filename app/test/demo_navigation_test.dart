import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:showup/app.dart';

void main() {
  testWidgets('post-event jump prepares and completes the real feedback flow', (
    tester,
  ) async {
    // The control is stage infrastructure, so this starts at the same fresh onboarding route as a
    // newly installed demo build. Reaching Tom-specific copy proves the jump prepared both the
    // mock group and private assignment instead of merely replacing the phase enum.
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const ShowUpApp());
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byTooltip('Jump to step'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('4 - Post-event feedback'));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('What stuck'), findsOneWidget);
    expect(find.text('What did you learn from Tom?'), findsOneWidget);

    await tester.enterText(
      find.byType(TextField),
      'Tom taught me to listen for how a record was mixed.',
    );
    await tester.tap(find.text('Next'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Who made it?'), findsOneWidget);

    await tester.tap(find.text('Next'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Swap numbers with anyone?'), findsOneWidget);

    await tester.tap(find.text('Maya'));
    await tester.tap(find.text('Done'));
    await tester.pump(const Duration(seconds: 1));

    expect(find.textContaining('picked each other'), findsNothing);
    expect(find.text('Maya'), findsOneWidget);
    expect(find.text('+1 415 555 0100'), findsOneWidget);
  });
}
