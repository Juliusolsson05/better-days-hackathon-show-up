import 'package:flutter/material.dart';

import 'core/theme.dart';
import 'data/mock_repository.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/product/product_shell.dart';
import 'state/app_state.dart';

/// Explicit composition root for screenshot review and rehearsals.
///
/// Production never imports this library. Keeping the fixture repository and static product shell
/// on this side of the entrypoint boundary makes it impossible for a missing build define to ship
/// a convincing fake group, vote, or chat to real users.
class ReferenceShowUpApp extends StatefulWidget {
  const ReferenceShowUpApp({super.key});

  @override
  State<ReferenceShowUpApp> createState() => _ReferenceShowUpAppState();
}

class _ReferenceShowUpAppState extends State<ReferenceShowUpApp> {
  late final MockRepository _repository = MockRepository();
  late final AppState _state = AppState(_repository);
  var _showProduct = false;

  @override
  void dispose() {
    _repository.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Show Up — Reference',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    home: _showProduct
        ? ProductShell(_state)
        : OnboardingScreen(
            _state,
            referenceUiPreview: true,
            onReferenceComplete: () => setState(() => _showProduct = true),
          ),
  );
}
