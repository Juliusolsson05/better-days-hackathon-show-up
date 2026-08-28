import 'package:flutter/material.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/notifications.dart';

/// DSN is passed at build time rather than committed. A Sentry DSN is not a secret in the
/// API-key sense -- it only permits writing events -- but keeping it out of the repo means
/// a fork does not silently report into our project.
const _dsn = String.fromEnvironment('SENTRY_DSN');

/// Pass --dart-define=USE_SUPABASE=true to run against the real backend, together with
/// --dart-define=SUPABASE_URL=... and --dart-define=SUPABASE_ANON_KEY=... . Without the
/// flag the app runs entirely on MockRepository and never touches Supabase.
const _useSupabase = bool.fromEnvironment('USE_SUPABASE');
const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const _supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

Future<void> main() async {
  if (_dsn.isEmpty) {
    // No DSN configured: run normally rather than crashing on startup. Local dev and CI
    // should not require a Sentry project to exist.
    await _boot();
    return;
  }

  await SentryFlutter.init(
    (options) {
      options.dsn = _dsn;
      // Release builds are what run on the demo phone, and they have no attached console --
      // which is the entire reason this exists. Debug events would just be noise, since
      // the simulator prints them anyway.
      options.debug = false;
      options.environment = const String.fromEnvironment('ENV', defaultValue: 'dev');
      // Full sampling: this is a hackathon build with a handful of users, and a missed
      // error costs far more than the quota does.
      options.tracesSampleRate = 1.0;
      options.attachScreenshot = true;
      options.attachViewHierarchy = true;
    },
    appRunner: _boot,
  );
}

/// Initialises Supabase when the real-backend flag is set, then starts the app. Shared by
/// the Sentry and no-Sentry paths so the swap behaves the same either way.
Future<void> _boot() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before runApp so a tap that cold-started the app is already queued when the shell
  // subscribes. Deliberately does NOT prompt for permission -- see NotificationService.
  await NotificationService.instance.init();
  if (_useSupabase) {
    assert(
      _supabaseUrl.isNotEmpty && _supabaseAnonKey.isNotEmpty,
      'USE_SUPABASE=true needs SUPABASE_URL and SUPABASE_ANON_KEY dart-defines',
    );
    await Supabase.initialize(url: _supabaseUrl, anonKey: _supabaseAnonKey);
  }
  runApp(const ShowUpApp());
}
