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
      primary: accent,
      secondary: accent,
      surface: surface,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: bg,
      elevation: 0,
      centerTitle: false,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: Colors.black,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    ),
  );
}

/// A round avatar keeps the durable emoji separate from the short-lived private photo URL.
/// Signed storage URLs expire, whereas the emoji is safe to cache and remains a recognizable
/// fallback. Treating one string as both values made an expired URL indistinguishable from a
/// real avatar choice and left reopened group screens full of broken-image placeholders.
class Avatar extends StatelessWidget {
  final String emoji;
  final double size;
  final String? imageUrl;
  const Avatar(this.emoji, {super.key, this.size = 40, this.imageUrl});

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      color: surface,
      alignment: Alignment.center,
      child: Text(emoji, style: TextStyle(fontSize: size * 0.5)),
    );

    // Profile photos are private signed URLs and therefore expire. `errorBuilder` is not a
    // decorative fallback: without it, a group reopened after expiry replaces every person
    // with a broken-image icon until the whole group is fetched again.
    return ClipOval(
      child: imageUrl == null
          ? fallback
          : Image.network(
              imageUrl!,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }
}
