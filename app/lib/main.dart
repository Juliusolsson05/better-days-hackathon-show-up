import 'package:flutter/material.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'app.dart';

/// DSN is passed at build time rather than committed. A Sentry DSN is not a secret in the
/// API-key sense -- it only permits writing events -- but keeping it out of the repo means
/// a fork does not silently report into our project.
const _dsn = String.fromEnvironment('SENTRY_DSN');

void main() async {
  if (_dsn.isEmpty) {
    // No DSN configured: run normally rather than crashing on startup. Local dev and CI
    // should not require a Sentry project to exist.
    return runApp(const ShowUpApp());
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
    appRunner: () => runApp(const ShowUpApp()),
  );
}
