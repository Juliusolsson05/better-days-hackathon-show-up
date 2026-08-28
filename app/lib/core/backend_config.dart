/// Compile-time backend selection shared by bootstrapping and repository construction.
///
/// Supabase is the default because a missing flag must never turn a release or a documented
/// integration run into a convincing fixture-only app. Mocks remain available, but selecting
/// them is an explicit act (`--dart-define=USE_SUPABASE=false`) so the console output and the
/// resulting behavior agree with the developer's intent.
const useSupabaseBackend = bool.fromEnvironment(
  'USE_SUPABASE',
  defaultValue: true,
);

const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

/// Validates the configuration in ordinary Dart code rather than an assertion.
///
/// Assertions are stripped from the release build used on the physical demo phone. Leaving the
/// credential check behind `assert` therefore converted a useful local error into a blank launch
/// or a late SDK failure in the only build where diagnosis is hardest.
void requireValidSupabaseConfiguration() {
  if (!useSupabaseBackend) return;
  if (supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty) return;

  throw StateError(
    'Supabase is the default backend and requires SUPABASE_URL and '
    'SUPABASE_ANON_KEY dart-defines. Use USE_SUPABASE=false only for an '
    'intentional fixture-only run.',
  );
}
