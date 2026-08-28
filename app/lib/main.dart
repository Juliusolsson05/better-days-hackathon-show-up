import 'package:flutter/material.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/backend_config.dart';
import 'core/notifications.dart';
import 'data/supabase_repository.dart';
import 'models/models.dart';

/// DSN is passed at build time rather than committed. A Sentry DSN is not a secret in the
/// API-key sense -- it only permits writing events -- but keeping it out of the repo means
/// a fork does not silently report into our project.
const _dsn = String.fromEnvironment('SENTRY_DSN');
const _environment = String.fromEnvironment('ENV', defaultValue: 'dev');

Future<void> main() async {
  if (_dsn.isEmpty) {
    // No DSN configured: run normally rather than crashing on startup. Local dev and CI
    // should not require a Sentry project to exist.
    await _boot();
    return;
  }

  await SentryFlutter.init((options) {
    options.dsn = _dsn;
    // Release builds are what run on the demo phone, and they have no attached console --
    // which is the entire reason this exists. Debug events would just be noise, since
    // the simulator prints them anyway.
    options.debug = false;
    options.environment = _environment;
    // This app handles faces, phone numbers, interests, and private group chat. Crash telemetry
    // must diagnose code without copying those product surfaces into a third-party system.
    options.sendDefaultPii = false;
    options.tracesSampleRate = _environment == 'prod' ? 0.1 : 1.0;
    options.attachScreenshot = false;
    // ignore: experimental_member_use
    options.attachViewHierarchy = false;
  }, appRunner: _boot);
}

/// Initialises the only backend available to the production entrypoint, then starts the app.
/// Reference fixtures have a separate composition root and can never be selected by a release
/// define that was omitted, misspelled, or overridden by CI.
Future<void> _boot() async {
  WidgetsFlutterBinding.ensureInitialized();
  // This must run before any plugin or SDK initialization so a misconfigured release fails for
  // the actual missing input. The same compile-time decision is imported by app.dart; duplicating
  // the flag in two files previously made it possible to initialize one backend and construct
  // the other after a seemingly harmless default-value edit.
  requireValidSupabaseConfiguration();
  // Before runApp so a tap that cold-started the app is already queued when the shell
  // subscribes. Deliberately does NOT prompt for permission -- see NotificationService.
  // Wrapped because a device with the plugin missing or unregistered must still boot:
  // losing the ladder degrades the experience, a crash on the splash screen ends it.
  try {
    await NotificationService.instance.init();
  } catch (error, stack) {
    debugPrint('[ladder] init failed, notifications disabled: $error\n$stack');
  }
  await Supabase.initialize(url: supabaseUrl, publishableKey: supabaseAnonKey);
  final client = Supabase.instance.client;
  runApp(
    ShowUpApp(
      repository: SupabaseRepository(client),
      initialPhase: client.auth.currentSession == null
          ? Phase.auth
          : Phase.onboarding,
    ),
  );
}
