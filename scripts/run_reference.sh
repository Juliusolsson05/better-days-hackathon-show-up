#!/usr/bin/env bash
# Launch the fixture-only design/rehearsal target explicitly. Production's main.dart never imports
# MockRepository or ProductShell, so this separate target is the only way to enter static screens.
set -euo pipefail
cd "$(dirname "$0")/../app"

exec flutter run -t lib/main_reference.dart "$@"
