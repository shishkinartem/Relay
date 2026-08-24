#!/usr/bin/env bash
# Wraps the release bundle in a DMG that can be handed to someone else.
#
# A DMG is only a container. What decides whether the recipient can open the
# application is the *signature inside it*, and there are exactly three levels:
#
#   ad-hoc / Apple Development   Gatekeeper refuses it on any Mac but the one
#                                that built it. The recipient has to clear the
#                                quarantine flag by hand (this script prints
#                                the command). Fine for yourself and for people
#                                you can talk to; not something to publish.
#   Developer ID Application     Gatekeeper still refuses it, because since
#                                macOS 10.15 signing alone is not enough.
#   Developer ID + notarized     Opens with a double click, everywhere. This is
#                                the only combination that is actually
#                                sendable, and it needs a paid Apple Developer
#                                Program membership.
#
# There is a second reason to care, specific to a screen recorder: macOS keys
# screen-recording permission to the signature's designated requirement. Both
# Developer ID and Apple Development produce a certificate-based requirement,
# which is stable across rebuilds, so the recipient grants the permission once.
# An ad-hoc signature (CODE_SIGN_IDENTITY = -) produces a cdhash-based one and
# does lose the grant on every build. What Developer ID adds over Apple
# Development is notarization and distributability, not permission stability.
# See docs/development/macos-tcc-and-launchservices.md.
#
# The DMG is built from the bundle that already exists, so what is shipped is
# what was tested. --build makes that bundle first.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION=Release
BUILD_FIRST=no
SIGN_IDENTITY=
NOTARIZE_PROFILE=
OUT=

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
warn() { printf '\033[1m!\033[0m %s\n' "$1"; }

usage() {
  printf 'usage: tool/package-dmg.sh [options]\n\n'
  printf '  --build                  build the release bundle first\n'
  printf '  --debug                  package the debug bundle instead\n'
  printf '  --sign <identity>        re-sign the app with this identity before\n'
  printf '                           packaging, e.g. "Developer ID Application: Name (TEAMID)"\n'
  printf '  --notarize <profile>     submit the DMG to Apple and staple the ticket.\n'
  printf '                           <profile> is a notarytool keychain profile; create one with\n'
  printf '                             xcrun notarytool store-credentials <profile> \\\n'
  printf '                               --apple-id <you@example.com> --team-id <TEAMID> \\\n'
  printf '                               --password <app-specific-password>\n'
  printf '  --out <path>             where to write the .dmg (default build/relay-<version>.dmg)\n'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --build) BUILD_FIRST=yes ;;
    --debug) CONFIGURATION=Debug ;;
    --release) CONFIGURATION=Release ;;
    --sign) SIGN_IDENTITY="${2:?--sign needs an identity}"; shift ;;
    --notarize) NOTARIZE_PROFILE="${2:?--notarize needs a keychain profile}"; shift ;;
    --out) OUT="${2:?--out needs a path}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n\n' "$1"; usage; exit 2 ;;
  esac
  shift
done

if [ "$(uname -s)" != Darwin ]; then
  printf 'A DMG can only be built on macOS. For Windows see docs/development/how-to-install.md.\n'
  exit 1
fi

LOWER_CONFIGURATION="$(printf '%s' "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')"
SRC="$PWD/build/macos/Build/Products/$CONFIGURATION/relay.app"

if [ "$BUILD_FIRST" = yes ]; then
  step "building $LOWER_CONFIGURATION"
  flutter build macos "--$LOWER_CONFIGURATION"
fi

if [ ! -d "$SRC" ]; then
  printf 'No %s bundle at %s\n\n' "$CONFIGURATION" "$SRC"
  printf 'Build it first:\n  ./tool/package-dmg.sh --build\n'
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$SRC/Contents/Info.plist" 2>/dev/null || printf '0.0.0')"
OUT="${OUT:-$PWD/build/relay-$VERSION.dmg}"

# --- signature ---------------------------------------------------------------

if [ -n "$SIGN_IDENTITY" ]; then
  step 'signing'
  # --deep is deprecated and does not re-sign nested frameworks correctly for
  # notarization; each Mach-O inside has to be signed from the inside out.
  # --options runtime is the hardened runtime, which notarization requires; the
  # entitlements are the ones the release build already declares.
  find "$SRC/Contents/Frameworks" -depth -name '*.framework' -o -name '*.dylib' 2>/dev/null |
    while IFS= read -r item; do
      codesign --force --timestamp --options runtime \
        --sign "$SIGN_IDENTITY" "$item"
    done
  codesign --force --timestamp --options runtime \
    --entitlements macos/Runner/Release.entitlements \
    --sign "$SIGN_IDENTITY" "$SRC"
fi

step 'what is inside'
SIGNATURE="$(codesign -dv --verbose=4 "$SRC" 2>&1 || true)"
AUTHORITY="$(printf '%s\n' "$SIGNATURE" | sed -n '/^Authority=/{s///p;q;}')"
printf '  %s\n' "$SRC"
printf '  version %s, %s configuration\n' "$VERSION" "$CONFIGURATION"
printf '  signed by: %s\n' "${AUTHORITY:-<unsigned>}"

SENDABLE=no
case "$AUTHORITY" in
  "Developer ID Application"*) SENDABLE=yes ;;
esac

if [ "$SENDABLE" = no ]; then
  warn 'This is not a Developer ID signature, so the DMG is not freely sendable.'
  warn 'The recipient will be told the application is damaged or cannot be'
  warn 'verified, and will have to clear the quarantine flag by hand:'
  printf '      xattr -dr com.apple.quarantine /Applications/relay.app\n'
  warn 'See docs/development/how-to-install.md for what it takes to avoid that.'
fi

if [ -n "$NOTARIZE_PROFILE" ] && [ "$SENDABLE" = no ]; then
  printf '\nNotarization needs a Developer ID Application signature; this bundle\n'
  printf 'has none, and Apple would reject the submission. Sign it first:\n'
  printf '  ./tool/package-dmg.sh --sign "Developer ID Application: ..." --notarize %s\n' \
    "$NOTARIZE_PROFILE"
  exit 1
fi

# --- stage and create --------------------------------------------------------

# mktemp -d, not a fixed path: two runs must not share a staging directory, and
# nothing outside it is ever removed.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/relay-dmg.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

step 'staging'
# ditto rather than cp -R: it carries the extended attributes the signature
# lives in, which cp -R silently drops — the copied bundle would then fail to
# verify.
ditto "$SRC" "$STAGE/relay.app"
# The /Applications symlink is what makes the window a drag-and-drop installer.
ln -s /Applications "$STAGE/Applications"
printf '  relay.app + a drop target for /Applications\n'

step 'creating the disk image'
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
# UDZO is the compressed read-only format every macOS can mount. -ov is not
# passed: the destination was just removed, and a stale image should be a
# visible error rather than something silently replaced.
hdiutil create \
  -volname "Relay $VERSION" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -quiet \
  "$OUT"

if [ -n "$SIGN_IDENTITY" ]; then
  step 'signing the disk image'
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$OUT"
fi

# --- notarization ------------------------------------------------------------

if [ -n "$NOTARIZE_PROFILE" ]; then
  step 'notarizing'
  printf '  submitting; Apple usually answers in a few minutes.\n'
  xcrun notarytool submit "$OUT" \
    --keychain-profile "$NOTARIZE_PROFILE" \
    --wait
  step 'stapling'
  # Stapling attaches the ticket to the image, so the recipient does not need
  # to be online the first time they open it.
  xcrun stapler staple "$OUT"
  xcrun stapler validate "$OUT"
fi

# --- report ------------------------------------------------------------------

step 'result'
printf '  %s\n' "$OUT"
printf '  %s\n' "$(du -h "$OUT" | cut -f1) compressed"

if [ -n "$NOTARIZE_PROFILE" ]; then
  printf '\n\033[1mSendable. It opens with a double click on any Mac.\033[0m\n'
else
  printf '\n\033[1mBuilt, but not notarized.\033[0m Gatekeeper will refuse it on\n'
  printf 'another Mac. The recipient has to run, after dragging it in:\n\n'
  printf '  xattr -dr com.apple.quarantine /Applications/relay.app\n\n'
  printf 'Then grant screen recording in System Settings and relaunch.\n'
fi
