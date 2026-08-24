#!/usr/bin/env bash
# The validation CLAUDE.md requires, across every workspace member.
#
# Fast and hermetic. Three things are deliberately NOT run here, and a pass
# below is not evidence about any of them:
#   1. the design-review renders and the platform integration tests, both tagged
#      opt-in in dart_test.yaml (see README.md);
#   2. `swift test` — the macOS native suite, in
#      packages/recorder_macos/macos/recorder_macos/core;
#   3. the Windows native suite (cmake + ctest), which needs a Windows host.
set -euo pipefail

cd "$(dirname "$0")/.."

FLUTTER_PACKAGES=(. packages/recorder_platform_interface packages/recorder_macos packages/recorder_windows)
DART_PACKAGES=(packages/upload_core packages/upload_telegram packages/upload_webdav)

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }

step 'format'
dart format --output=none --set-exit-if-changed .

step 'analyze'
flutter analyze

for package in "${FLUTTER_PACKAGES[@]}"; do
  if compgen -G "$package/test/*" > /dev/null; then
    step "flutter test $package"
    (cd "$package" && flutter test)
  else
    step "flutter test $package"
    printf '  skipped: no test files\n'
  fi
done

for package in "${DART_PACKAGES[@]}"; do
  step "dart test $package"
  (cd "$package" && dart test)
done

printf '\n\033[1mAll validation passed.\033[0m\n'
printf 'Not covered here: swift test (macOS native), ctest (Windows native),\n'
printf 'and the two --run-skipped suites. See CLAUDE.md.\n'
