#!/usr/bin/env bash
# Launch the app on the connected iPhone.
#
# RELEASE, not debug, and that is not an optimisation. Flutter debug builds use JIT, which
# iOS restricts: the OS SIGKILLs the process before the Dart VM Service can attach, and it
# presents as a white screen that dies after a few seconds with nothing wrong in the code.
# Release builds are AOT-compiled and launch standalone.
#
# The tradeoff is no attached console -- which is why the Sentry DSN is passed here.
#
# For iteration, use the simulator instead: debug and hot reload work fine there.
#   flutter run -d "iPhone 16 Pro"
set -euo pipefail
cd "$(dirname "$0")/.."

set -a; source .env; set +a

: "${SUPABASE_URL:?set SUPABASE_URL in .env}"
: "${SUPABASE_ANON_KEY:?set SUPABASE_ANON_KEY in .env}"

# A localhost URL is the phone's OWN loopback, not this Mac -- it will fail silently.
if [[ "$SUPABASE_URL" == *"127.0.0.1"* || "$SUPABASE_URL" == *"localhost"* ]]; then
  LAN=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
  echo "warning: SUPABASE_URL points at localhost, which the phone cannot reach."
  [[ -n "$LAN" ]] && echo "         for the local stack use: http://${LAN}:54321"
fi

DEVICE="${1:-$(flutter devices --machine 2>/dev/null \
  | python3 -c "import json,sys; d=[x for x in json.load(sys.stdin) if x.get('targetPlatform','').startswith('ios') and not x.get('emulator')]; print(d[0]['id'] if d else '')")}"
[[ -n "$DEVICE" ]] || { echo "no physical iOS device found — is it plugged in and unlocked?"; exit 1; }

# A locked phone fails at INSTALL, and flutter reports it as the generic
# "Could not run build/ios/iphoneos/Runner.app", which sends you hunting through
# signing and provisioning for a problem that is solved by tapping the screen.
if xcrun devicectl device info lockState --device "$DEVICE" 2>/dev/null | grep -qi "locked: *true\|passcodeRequired"; then
  echo "the iPhone is locked — unlock it and keep it awake, then re-run"
  exit 1
fi

# Mock is the default so the device build never silently depends on a backend being up.
# USE_SUPABASE=true in .env (or the environment) switches to the real one; main.dart only
# calls Supabase.initialize under the same flag.
USE_SUPABASE="${USE_SUPABASE:-false}"
if [[ "$USE_SUPABASE" == "true" ]]; then
  # main.dart guards this with an assert, which Dart strips in release -- and release is
  # the only mode that works on a device. So check it here, where it will actually run.
  : "${SUPABASE_URL:?USE_SUPABASE=true needs SUPABASE_URL}"
  : "${SUPABASE_ANON_KEY:?USE_SUPABASE=true needs SUPABASE_ANON_KEY}"
  echo "→ real backend: $SUPABASE_URL"
else
  echo "→ MockRepository (set USE_SUPABASE=true for the real backend)"
fi

echo "→ release build to $DEVICE"
# .env lives at the repo root, the Flutter project one level down in app/.
cd app
exec flutter run --release -d "$DEVICE" \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY" \
  --dart-define=USE_SUPABASE="$USE_SUPABASE" \
  --dart-define=SENTRY_DSN="${SENTRY_DSN:-}" \
  --dart-define=ENV="${ENV:-dev}"
