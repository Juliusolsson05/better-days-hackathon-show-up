import 'package:flutter/material.dart';

/// Minimal on purpose. One accent, generous spacing, dark. Styling is not the point yet --
/// this exists so screens look deliberate rather than like raw Material defaults.
const accent = Color(0xFFE8734A);
const bg = Color(0xFF14110F);
const surface = Color(0xFF1E1A17);

ThemeData buildTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: bg,
    colorScheme: base.colorScheme.copyWith(
      primary: accent, secondary: accent, surface: surface,
    ),
    appBarTheme: const AppBarTheme(backgroundColor: bg, elevation: 0, centerTitle: false),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent, foregroundColor: Colors.black,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true, fillColor: surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none,
      ),
    ),
  );
}

class Avatar extends StatelessWidget {
  final String emoji;
  final double size;
  const Avatar(this.emoji, {super.key, this.size = 40});
  @override
  Widget build(BuildContext context) => Container(
        width: size, height: size,
        decoration: const BoxDecoration(color: surface, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: Text(emoji, style: TextStyle(fontSize: size * 0.5)),
      );
}
