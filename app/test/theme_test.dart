import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:showup/core/theme.dart';

void main() {
  test('the brand palette keeps one action accent on the sage canvas', () {
    final theme = buildTheme();

    expect(theme.colorScheme.primary, const Color(0xFF9FE870));
    expect(theme.colorScheme.onPrimary, const Color(0xFF0E0F0C));
    expect(theme.scaffoldBackgroundColor, const Color(0xFFE8EBE6));
    expect(theme.colorScheme.surface, const Color(0xFFFFFFFF));
  });

  test('cards, actions, and fields retain their distinct shape roles', () {
    final theme = buildTheme();
    final card = theme.cardTheme.shape! as RoundedRectangleBorder;
    final button =
        theme.filledButtonTheme.style!.shape!.resolve(const <WidgetState>{})!
            as RoundedRectangleBorder;
    final input =
        theme.inputDecorationTheme.enabledBorder! as OutlineInputBorder;

    expect(card.borderRadius, BorderRadius.circular(cardRadius));
    expect(button.borderRadius, BorderRadius.circular(999));
    expect(input.borderRadius, BorderRadius.circular(inputRadius));
  });
}
