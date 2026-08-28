import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import '../../state/app_state.dart';

/// Email OTP, shown only against the real backend. Two steps on one screen: enter an
/// address, then the six-digit code it was mailed. No password, no magic link -- the
/// code keeps the whole thing in-app.
class AuthScreen extends StatefulWidget {
  final AppState state;
  const AuthScreen(this.state, {super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

enum _Step { email, code }

class _AuthScreenState extends State<AuthScreen> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  _Step _step = _Step.email;
  bool _busy = false;
  String? _error;

  /// Seconds until "send a new code" is allowed again. Providers rate-limit OTP sends,
  /// so a spammed button just earns a 429; the countdown makes the wait legible instead.
  int _resendIn = 0;
  Timer? _cooldown;

  static final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
  String get _trimmedEmail => _email.text.trim();
  bool get _emailValid => _emailRe.hasMatch(_trimmedEmail);
  bool get _codeValid => _code.text.trim().length == 6;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = _humanize(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _humanize(Object e) {
    final s = e.toString().toLowerCase();
    if (s.contains('socketexception') ||
        s.contains('failed host lookup') ||
        s.contains('clientexception') ||
        s.contains('timeout') ||
        s.contains('network')) {
      return "Can't reach the server. Check your connection and try again.";
    }
    if (s.contains('otp_expired') || s.contains('expired')) {
      return 'That code has expired. Send a new one.';
    }
    if (s.contains('invalid') ||
        s.contains('token has expired or is invalid')) {
      return "That code doesn't match. Check it and try again.";
    }
    if (s.contains('rate limit') ||
        s.contains('too many') ||
        s.contains('429')) {
      return 'Too many attempts. Wait a minute, then try again.';
    }
    return 'Something went wrong. Try again.';
  }

  void _startCooldown([int seconds = 30]) {
    _cooldown?.cancel();
    setState(() => _resendIn = seconds);
    _cooldown = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _resendIn--);
      if (_resendIn <= 0) t.cancel();
    });
  }

  Future<void> _sendCode() => _run(() async {
    await widget.state.sendEmailOtp(_trimmedEmail);
    if (!mounted) return;
    setState(() => _step = _Step.code);
    _startCooldown();
  });

  Future<void> _verify() =>
      _run(() => widget.state.verifyEmailOtp(_trimmedEmail, _code.text.trim()));

  void _onCodeChanged(String value) {
    setState(() => _error = null);
    // Verifying the instant the sixth digit lands saves a deliberate tap, and paste is
    // the common case for a code that arrived in another app.
    if (value.trim().length == 6 && !_busy) _verify();
  }

  void _backToEmail() {
    _cooldown?.cancel();
    setState(() {
      _step = _Step.email;
      _code.clear();
      _error = null;
      _resendIn = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final onEmail = _step == _Step.email;
    final canResend = !_busy && _resendIn == 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Show Up'),
        leading: onEmail
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _busy ? null : _backToEmail,
              ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
        children: [
          ScreenIntro(
            'You go alone.\nSo does everyone else.',
            onEmail
                ? 'Sign in with your email. We send a code, no password.'
                : 'Enter the six-digit code we sent to $_trimmedEmail.',
          ),
          const SizedBox(height: 32),
          if (onEmail) ...[
            const _Label('Email'),
            TextField(
              controller: _email,
              onChanged: (_) => setState(() => _error = null),
              onSubmitted: (_) => _emailValid && !_busy ? _sendCode() : null,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.send,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(hintText: 'you@example.com'),
            ),
          ] else ...[
            const _Label('Code'),
            TextField(
              controller: _code,
              onChanged: _onCodeChanged,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              autofillHints: const [AutofillHints.oneTimeCode],
              decoration: const InputDecoration(
                hintText: '123456',
                counterText: '',
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: canResend ? _sendCode : null,
              child: Text(
                _resendIn > 0
                    ? 'Send a new code (${_resendIn}s)'
                    : 'Send a new code',
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(
                color: negative,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy || (onEmail ? !_emailValid : !_codeValid)
                ? null
                : (onEmail ? _sendCode : _verify),
            child: _busy
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: ink,
                    ),
                  )
                : Text(onEmail ? 'Send code' : 'Verify'),
          ),
          if (!onEmail)
            TextButton(
              onPressed: _busy ? null : _backToEmail,
              child: const Text('Use a different email'),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _cooldown?.cancel();
    _email.dispose();
    _code.dispose();
    super.dispose();
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}
