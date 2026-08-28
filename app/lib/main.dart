import 'package:flutter/material.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/backend_config.dart';
import 'core/notifications.dart';

/// DSN is passed at build time rather than committed. A Sentry DSN is not a secret in the
/// API-key sense -- it only permits writing events -- but keeping it out of the repo means
/// a fork does not silently report into our project.
const _dsn = String.fromEnvironment('SENTRY_DSN');

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
    options.environment = const String.fromEnvironment(
      'ENV',
      defaultValue: 'dev',
    );
    // Full sampling: this is a hackathon build with a handful of users, and a missed
    // error costs far more than the quota does.
    options.tracesSampleRate = 1.0;
    options.attachScreenshot = true;
    // Sentry still marks hierarchy capture experimental even though it is the only practical
    // way to diagnose a release-only layout failure on an unattached demo phone. Keep the
    // suppression at the call site so a future stable SDK forces us to reconsider this choice.
    // ignore: experimental_member_use
    options.attachViewHierarchy = true;
  }, appRunner: _boot);
}

/// Initialises Supabase when the real-backend flag is set, then starts the app. Shared by
/// the Sentry and no-Sentry paths so the swap behaves the same either way.
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
  if (useSupabaseBackend) {
    // Supabase renamed the public client credential to "publishable key" to make its security
    // role harder to misunderstand. Keep the environment variable backward-compatible for the
    // demo scripts, but use the current SDK argument so a future major upgrade is not blocked.
    await Supabase.initialize(
      url: supabaseUrl,
      publishableKey: supabaseAnonKey,
    );
  }
  runApp(const ShowUpApp());
}
