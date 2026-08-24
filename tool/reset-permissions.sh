#!/usr/bin/env bash
# Clears this application's privacy records so macOS prompts again.
#
# DESTRUCTIVE AND IRREVERSIBLE. `tccutil reset` deletes this machine's granted
# ScreenCapture, Microphone and Camera records for the bundle id.
#
# WHEN THIS IS THE RIGHT TOOL: only for an AD-HOC signed build
# (`CODE_SIGN_IDENTITY = -`). There the designated requirement is a cdhash, so
# every rebuild really is a new application to TCC and the grant is gone.
#
# WHEN IT IS NOT: an Apple Development or Developer ID signed build. Its
# designated requirement names the bundle id and the certificate, not the code,
# so a rebuild keeps its grant — and running this throws that grant away for
# nothing. Measured on this host 2026-08-25; check yours with:
#
#   codesign -d -r- build/macos/Build/Products/Debug/relay.app
#
# A denial on an identity-signed build is almost always the launch method, not
# the signature: a binary exec'd from a shell (`flutter run`, or any direct
# exec of the bundle binary) is attributed to the shell. Diagnose first —
# docs/development/macos-tcc-and-launchservices.md.
#
set -euo pipefail

BUNDLE_ID="${1:-com.relay.relay}"

for service in ScreenCapture Microphone Camera; do
  tccutil reset "$service" "$BUNDLE_ID" || true
done

printf '\nCleared ScreenCapture, Microphone and Camera for %s.\n' "$BUNDLE_ID"
printf 'Launch the app; macOS will ask again.\n'
