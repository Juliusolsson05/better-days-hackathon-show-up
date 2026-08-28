import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  static final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
  bool get _emailValid => _emailRe.hasMatch(_email.text.trim());
  bool get _codeValid => _code.text.trim().length == 6;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      setState(() => _error = _humanize(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _humanize(Object e) {
    final s = e.toString();
    if (s.contains('otp_expired') || s.contains('expired')) {
      return 'That code has expired. Send a new one.';
    }
    if (s.contains('invalid') || s.contains('Token has expired or is invalid')) {
      return "That code doesn't match. Check it and try again.";
    }
    return 'Something went wrong. Try again.';
  }

  Future<void> _sendCode() => _run(() async {
        await widget.state.sendEmailOtp(_email.text.trim());
        setState(() => _step = _Step.code);
      });

  Future<void> _verify() =>
      _run(() => widget.state.verifyEmailOtp(_email.text.trim(), _code.text.trim()));

  @override
  Widget build(BuildContext context) {
    final onEmail = _step == _Step.email;
    return Scaffold(
      appBar: AppBar(title: const Text('Show Up')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          const Text('You go alone. So does everyone else.',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, height: 1.2)),
          const SizedBox(height: 8),
          Text(
            onEmail
                ? 'Sign in with your email — we send a code, no password.'
                : 'Enter the six-digit code we sent to ${_email.text.trim()}.',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
          ),
          const SizedBox(height: 28),
          if (onEmail) ...[
            const _Label('Email'),
            TextField(
              controller: _email,
              onChanged: (_) => setState(() {}),
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(hintText: 'you@example.com'),
            ),
          ] else ...[
            const _Label('Code'),
            TextField(
              controller: _code,
              onChanged: (_) => setState(() {}),
              keyboardType: TextInputType.number,
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(hintText: '123456', counterText: ''),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _busy ? null : _sendCode,
              child: const Text('Send a new code'),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Color(0xFFE8734A))),
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
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                  )
                : Text(onEmail ? 'Send code' : 'Verify'),
          ),
          if (!onEmail)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _step = _Step.email;
                        _code.clear();
                        _error = null;
                      }),
              child: const Text('Use a different email'),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
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
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
      );
}
