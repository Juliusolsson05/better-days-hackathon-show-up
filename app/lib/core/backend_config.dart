const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

/// Validates the configuration in ordinary Dart code rather than an assertion.
///
/// Assertions are stripped from the release build used on the physical demo phone. Leaving the
/// credential check behind `assert` therefore converted a useful local error into a blank launch
/// or a late SDK failure in the only build where diagnosis is hardest.
void requireValidSupabaseConfiguration() {
  if (supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty) return;

  throw StateError(
    'The production entrypoint requires SUPABASE_URL and SUPABASE_ANON_KEY '
    'dart-defines. Use lib/main_reference.dart for an intentional fixture-only run.',
  );
}
