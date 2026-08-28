import 'package:flutter/material.dart';

// These names stay short because feature code reads them constantly. They are semantic,
// not a bag of decorative swatches: if a screen needs another shade, first ask whether it
// is actually a new role. That constraint prevents the app drifting back into one-off
// opacity colors that only work against one background.
const accent = Color(0xFF9FE870);
const accentActive = Color(0xFFCDFFAD);
const accentPale = Color(0xFFE2F6D5);
const bg = Color(0xFFE8EBE6);
const surface = Color(0xFFFFFFFF);
const ink = Color(0xFF0E0F0C);
const inkDeep = Color(0xFF163300);
const bodyInk = Color(0xFF454745);
const mutedInk = Color(0xFF686B68);
const line = Color(0xFFD2D6CF);
const positive = Color(0xFF2EAD4B);
const warning = Color(0xFFFFD11A);
const negative = Color(0xFFD03238);

const cardRadius = 24.0;
const inputRadius = 12.0;

/// The app deliberately ships one light visual language for the hackathon demo.
///
/// This is Wise-inspired rather than a Material-default recolor: surface contrast replaces
/// elevation, buttons are pills, cards use the larger 24px radius, and type hierarchy does
/// most of the expressive work. The system font is intentional. Wise Sans is proprietary,
/// while a bundled third-party display font would add binary weight and a new failure mode
/// to an offline physical-device demo.
ThemeData buildTheme() {
  const scheme = ColorScheme.light(
    primary: accent,
    onPrimary: ink,
    secondary: inkDeep,
    onSecondary: surface,
    error: negative,
    onError: surface,
    surface: surface,
    onSurface: ink,
    outline: line,
    outlineVariant: line,
  );

  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  final text = base.textTheme.copyWith(
    displayLarge: const TextStyle(
      color: ink,
      fontSize: 40,
      height: 0.98,
      fontWeight: FontWeight.w900,
      letterSpacing: -1.4,
    ),
    displayMedium: const TextStyle(
      color: ink,
      fontSize: 32,
      height: 1.05,
      fontWeight: FontWeight.w900,
      letterSpacing: -1,
    ),
    headlineLarge: const TextStyle(
      color: ink,
      fontSize: 28,
      height: 1.12,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.6,
    ),
    headlineMedium: const TextStyle(
      color: ink,
      fontSize: 24,
      height: 1.2,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.35,
    ),
    titleLarge: const TextStyle(
      color: ink,
      fontSize: 20,
      height: 1.3,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
    ),
    titleMedium: const TextStyle(
      color: ink,
      fontSize: 16,
      height: 1.5,
      fontWeight: FontWeight.w600,
    ),
    bodyLarge: const TextStyle(color: bodyInk, fontSize: 16, height: 1.5),
    bodyMedium: const TextStyle(color: bodyInk, fontSize: 14, height: 1.43),
    bodySmall: const TextStyle(color: mutedInk, fontSize: 12, height: 1.35),
    labelLarge: const TextStyle(
      color: ink,
      fontSize: 16,
      fontWeight: FontWeight.w700,
    ),
  );

  final pill = RoundedRectangleBorder(borderRadius: BorderRadius.circular(999));
  final inputShape = OutlineInputBorder(
    borderRadius: BorderRadius.circular(inputRadius),
    borderSide: const BorderSide(color: ink, width: 1.2),
  );

  return base.copyWith(
    scaffoldBackgroundColor: bg,
    colorScheme: scheme,
    textTheme: text,
    primaryTextTheme: text,
    appBarTheme: const AppBarTheme(
      backgroundColor: bg,
      foregroundColor: ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: ink,
        fontSize: 18,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.25,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled) ? line : accent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled) ? mutedInk : ink,
        ),
        overlayColor: const WidgetStatePropertyAll(accentActive),
        minimumSize: const WidgetStatePropertyAll(Size.fromHeight(52)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 24),
        ),
        shape: WidgetStatePropertyAll(pill),
        elevation: const WidgetStatePropertyAll(0),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ink,
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        side: const BorderSide(color: ink, width: 1.2),
        shape: pill,
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: inkDeep,
        shape: pill,
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      hintStyle: const TextStyle(color: mutedInk),
      labelStyle: const TextStyle(color: bodyInk),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      border: inputShape,
      enabledBorder: inputShape,
      focusedBorder: inputShape.copyWith(
        borderSide: const BorderSide(color: inkDeep, width: 2),
      ),
      errorBorder: inputShape.copyWith(
        borderSide: const BorderSide(color: negative, width: 1.5),
      ),
      focusedErrorBorder: inputShape.copyWith(
        borderSide: const BorderSide(color: negative, width: 2),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: surface,
      selectedColor: accentPale,
      disabledColor: line,
      side: const BorderSide(color: line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      labelStyle: const TextStyle(color: ink, fontWeight: FontWeight.w600),
      secondaryLabelStyle: const TextStyle(
        color: ink,
        fontWeight: FontWeight.w700,
      ),
      checkmarkColor: inkDeep,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    ),
    cardTheme: const CardThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(cardRadius)),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(cardRadius)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: ink,
      contentTextStyle: const TextStyle(color: surface, fontSize: 14),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: inkDeep,
      linearTrackColor: line,
    ),
    dividerTheme: const DividerThemeData(color: line, thickness: 1, space: 1),
    iconTheme: const IconThemeData(color: ink),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? accent : surface,
      ),
      checkColor: const WidgetStatePropertyAll(ink),
      side: const BorderSide(color: ink, width: 1.3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? ink : mutedInk,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? accent : line,
      ),
    ),
  );
}

/// Repeated screen hierarchy belongs here so onboarding, auth, and post-meetup do not
/// slowly invent different headline scales for the same structural role.
class ScreenIntro extends StatelessWidget {
  const ScreenIntro(this.title, this.body, {super.key});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: Theme.of(context).textTheme.displayMedium),
      const SizedBox(height: 12),
      Text(body, style: Theme.of(context).textTheme.bodyLarge),
    ],
  );
}

/// A round avatar. [source] is either an emoji (the mock's convention), a short bit of
/// text to show as-is, or an http(s) URL. Emoji are retained because they are selected by
/// users as chat identity, not added as decorative interface chrome.
class Avatar extends StatelessWidget {
  final String source;
  final double size;
  const Avatar(this.source, {super.key, this.size = 40});

  bool get _isUrl =>
      source.startsWith('http://') || source.startsWith('https://');

  @override
  Widget build(BuildContext context) {
    if (_isUrl) {
      return ClipOval(
        child: Image.network(
          source,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _glyph('🙂'),
        ),
      );
    }
    return _glyph(source.isEmpty ? '🙂' : source);
  }

  Widget _glyph(String text) => Container(
    width: size,
    height: size,
    decoration: const BoxDecoration(color: accentPale, shape: BoxShape.circle),
    alignment: Alignment.center,
    child: Text(text, style: TextStyle(fontSize: size * 0.5)),
  );
}
