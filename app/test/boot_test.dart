import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:showup/app.dart';

void main() {
  testWidgets('boots at iPhone size without throwing', (tester) async {
    // iPhone 15 Pro logical size. The other test uses an oversized surface to reach the
    // submit button, which would hide anything that only breaks at real phone dimensions.
    tester.view.physicalSize = const Size(393 * 3, 852 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const ShowUpApp());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
    expect(find.text('SOLO MEETUPS'), findsOneWidget);
  });
}
