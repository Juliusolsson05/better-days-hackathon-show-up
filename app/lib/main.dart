import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';

/// Pass --dart-define=USE_SUPABASE=true to run against the real backend, together with
/// --dart-define=SUPABASE_URL=... and --dart-define=SUPABASE_ANON_KEY=... . Without the
/// flag the app runs entirely on MockRepository and never touches Supabase.
const _useSupabase = bool.fromEnvironment('USE_SUPABASE');
const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const _supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

Future<void> main() async {
  if (_useSupabase) {
    WidgetsFlutterBinding.ensureInitialized();
    assert(
      _supabaseUrl.isNotEmpty && _supabaseAnonKey.isNotEmpty,
      'USE_SUPABASE=true needs SUPABASE_URL and SUPABASE_ANON_KEY dart-defines',
    );
    await Supabase.initialize(url: _supabaseUrl, anonKey: _supabaseAnonKey);
  }
  runApp(const ShowUpApp());
}
