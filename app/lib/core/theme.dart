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

/// A round avatar. [source] is either an emoji (the mock's convention), a short bit of
/// text to show as-is, or an http(s) URL -- the real backend passes `profiles.photo_url`,
/// so a URL loads the image and anything else renders as a glyph. An empty string or a
/// failed image load falls back to a neutral face.
class Avatar extends StatelessWidget {
  final String source;
  final double size;
  const Avatar(this.source, {super.key, this.size = 40});

  bool get _isUrl => source.startsWith('http://') || source.startsWith('https://');

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
        decoration: const BoxDecoration(color: surface, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: Text(text, style: TextStyle(fontSize: size * 0.5)),
      );
}
