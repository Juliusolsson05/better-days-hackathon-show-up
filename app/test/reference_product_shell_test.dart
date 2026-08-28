import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:showup/features/product/product_shell.dart';

void main() {
  testWidgets('a locked group carries its single venue into chat', (
    tester,
  ) async {
    // This starts at the group hub because the regression lived in the route handoff: the hub
    // correctly rendered one resolved venue, then chat discarded that fact and reopened all three.
    await tester.pumpWidget(
      const MaterialApp(home: GroupHubScreen(locked: true)),
    );

    await tester.tap(find.text('Open chat →'));
    await tester.pumpAndSettle();

    expect(find.text("WHERE YOU'RE MEETING"), findsOneWidget);
    expect(find.text('The Copper Kettle'), findsOneWidget);
    expect(find.text('Lantern & Vine'), findsNothing);
    expect(find.text('Fern & Fig'), findsNothing);
    expect(find.text('Pick the table'), findsNothing);
    expect(find.textContaining('votes'), findsNothing);
  });

  testWidgets('an unresolved group chat retains the open venue ballot', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: GroupChatMockScreen()));

    expect(find.text('Pick the table'), findsOneWidget);
    expect(find.text('The Copper Kettle'), findsOneWidget);
    expect(find.text('Lantern & Vine'), findsOneWidget);
    expect(find.text('Fern & Fig'), findsOneWidget);
  });
}
