#!/usr/bin/env bash
# Installs the locally built app into /Applications, and re-installs it later.
#
# Why this is not a copy command: ditto merges into an existing bundle instead
# of replacing it, so a file left over from an older build survives and breaks
# the code signature ("a sealed resource is missing or invalid"), after which
# macOS treats the app as damaged. This script therefore copies to a staging
# name beside the destination, verifies the signature there, and only then
# swaps it in — /Applications is on the same volume as build/, so the swap is
# a rename. The destination is never removed before a good copy exists.
#
# Why it quits the app first: replacing files under a running process can crash
# it, and the survivor keeps a stale LaunchServices and TCC identity. Detection
# is by executable path, never `pgrep -f relay`, because this repository lives
# in a directory called Relay and that pattern matches this script's own shell.
#
# Nothing outside the bundle is touched: recordings in ~/Movies/Relay, settings
# in ~/Library/Application Support/com.relay.relay and Keychain credentials all
# live elsewhere and survive an update. Privacy permissions are a separate step
# the script prints at the end; see README.md and tool/reset-permissions.sh.
#
# RELAY_INSTALL_DIR overrides the destination directory, which defaults to
# /Applications. It exists so the copy/verify/swap path can be exercised against
# a scratch directory without touching a real install; a bundle installed
# anywhere else is not a supported place to run the app from, because
# LaunchServices and TCC resolve com.relay.relay by whichever copy they rank
# first. Screen recording permission in particular is unlikely to behave. The
# override changes only the destination: the quit step below is keyed on the
# bundle id, so a running app is still quit even when installing elsewhere.
set -euo pipefail

cd "$(dirname "$0")/.."

BUNDLE_ID=com.relay.relay
INSTALL_DIR="${RELAY_INSTALL_DIR:-/Applications}"
# A trailing slash would make DEST a different string from the paths lsregister
# reports, and the leftover-copy scan below compares them literally.
while [ "${INSTALL_DIR%/}" != "$INSTALL_DIR" ] && [ "$INSTALL_DIR" != / ]; do
  INSTALL_DIR="${INSTALL_DIR%/}"
done
DEST="$INSTALL_DIR/relay.app"
STAGE="$INSTALL_DIR/.relay-installing-$$.app"
BACKUP="$INSTALL_DIR/.relay-previous-$$.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

CONFIGURATION=Release
BUILD_FIRST=no
DRY_RUN=no

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }

usage() {
  printf 'usage: tool/install.sh [--release|--debug] [--build] [--dry-run]\n\n'
  printf '  --release   install the release bundle (default)\n'
  printf '  --debug     install the debug bundle instead\n'
  printf '  --build     build that configuration first\n'
  printf '  --dry-run   print every action without performing it\n\n'
  printf 'RELAY_INSTALL_DIR overrides the destination directory (%s).\n' "$INSTALL_DIR"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --release) CONFIGURATION=Release ;;
    --debug) CONFIGURATION=Debug ;;
    --build) BUILD_FIRST=yes ;;
    --dry-run) DRY_RUN=yes ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n\n' "$1"; usage; exit 2 ;;
  esac
  shift
done

# Every mutating command goes through run, so --dry-run stays honest.
run() {
  if [ "$DRY_RUN" = yes ]; then
    printf '  would run: %s\n' "$*"
  else
    "$@"
  fi
}

if [ "$(uname -s)" != Darwin ]; then
  printf 'This installer is macOS only. Windows is not built yet; see README.md.\n'
  exit 1
fi

if [ ! -d "$INSTALL_DIR" ]; then
  printf 'No such directory: %s\n' "$INSTALL_DIR"
  printf 'RELAY_INSTALL_DIR must name a directory that already exists.\n'
  exit 1
fi

if [ ! -w "$INSTALL_DIR" ]; then
  printf '%s is not writable by this account.\n' "$INSTALL_DIR"
  if [ "$INSTALL_DIR" = /Applications ]; then
    printf 'It is normally group-writable by admin; use an admin account.\n'
  fi
  exit 1
fi

# --- source bundle -----------------------------------------------------------

SRC="$PWD/build/macos/Build/Products/$CONFIGURATION/relay.app"
LOWER_CONFIGURATION="$(printf '%s' "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')"

if [ "$BUILD_FIRST" = yes ]; then
  step "building $LOWER_CONFIGURATION"
  run flutter build macos "--$LOWER_CONFIGURATION"
fi

# Not gated on --dry-run: a plan drawn up for a bundle that does not exist is
# misleading. --build is the exception, since the build that would create it was
# itself only printed.
if [ ! -d "$SRC" ] && [ "$BUILD_FIRST" = no ]; then
  printf 'No %s bundle at %s\n\n' "$CONFIGURATION" "$SRC"
  printf 'Build it first:\n'
  printf '  flutter build macos --%s\n' "$LOWER_CONFIGURATION"
  printf 'or let this script do it:\n'
  printf '  ./tool/install.sh --%s --build\n' "$LOWER_CONFIGURATION"
  exit 1
fi

# The linked executable is rewritten by every build, so it dates the bundle.
# Anything under build/, Pods/, .dart_tool/ or ephemeral/ is generated output
# and would otherwise report a false positive on every run. .DS_Store is
# excluded for the same reason and is not hypothetical: opening macos/ in
# Finder rewrites it and made this check refuse a perfectly current bundle.
if [ -d "$SRC" ] && [ "$BUILD_FIRST" = no ]; then
  NEWER="$(find lib macos packages pubspec.yaml pubspec.lock \
    -newer "$SRC/Contents/MacOS/relay" -type f \
    -not -path '*/build/*' \
    -not -path '*/Pods/*' \
    -not -path '*/.dart_tool/*' \
    -not -path '*/ephemeral/*' \
    -not -path '*/.symlinks/*' \
    -not -name '.DS_Store' \
    2>/dev/null | wc -l | tr -d ' ' || true)"

  if [ "$NEWER" != 0 ]; then
    printf 'The %s bundle is older than %s source file(s).\n' "$CONFIGURATION" "$NEWER"
    printf 'Installing it would ship stale code.\n\n'
    printf 'Rebuild first:\n'
    printf '  ./tool/install.sh --%s --build\n' "$LOWER_CONFIGURATION"
    exit 1
  fi
fi

if [ -d "$SRC" ]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$SRC/Contents/Info.plist" 2>/dev/null || printf 'unknown')"
  BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$SRC/Contents/Info.plist" 2>/dev/null || printf '?')"
else
  VERSION=unknown
  BUILD_NUMBER='?'
fi

step 'source'
printf '  %s\n' "$SRC"
printf '  version %s (%s), %s configuration\n' "$VERSION" "$BUILD_NUMBER" "$CONFIGURATION"

# --- quit any running copy ---------------------------------------------------

step 'running instances'

# pgrep -x matches the process name exactly, then ps -o comm= gives the full
# executable path so a copy inside a bundle can be told from anything else that
# happens to be called relay.
RUNNING=
for pid in $(pgrep -x relay 2>/dev/null || true); do
  exe="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
  case "$exe" in
    */relay.app/Contents/MacOS/relay)
      printf '  pid %s  %s\n' "$pid" "$exe"
      RUNNING="$RUNNING $pid"
      ;;
  esac
done

if [ -z "$RUNNING" ]; then
  printf '  none\n'
else
  printf '  quitting. An interrupted recording is left as a .part file and\n'
  printf '  offered for recovery at the next launch; nothing is deleted.\n'

  # Graceful first. This needs Automation approval for the calling terminal and
  # fails with -1743 when it is denied, so its status is ignored and the poll
  # below decides. It also targets whichever copy LaunchServices resolves.
  run osascript -e "tell application id \"$BUNDLE_ID\" to quit" || true

  if [ "$DRY_RUN" = no ]; then
    for pid in $RUNNING; do
      waited=0
      while [ "$waited" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
        sleep 0.1
        waited=$((waited + 1))
      done

      if kill -0 "$pid" 2>/dev/null; then
        printf '  pid %s ignored the quit, sending SIGTERM\n' "$pid"
        kill -TERM "$pid" 2>/dev/null || true
        waited=0
        while [ "$waited" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do
          sleep 0.1
          waited=$((waited + 1))
        done
      fi

      if kill -0 "$pid" 2>/dev/null; then
        printf '  WARNING: pid %s did not exit, forcing it. A recording in\n' "$pid"
        printf '  progress will be left as a .part file to recover.\n'
        kill -9 "$pid" 2>/dev/null || true
        sleep 0.5
      fi

      if kill -0 "$pid" 2>/dev/null; then
        printf 'Could not stop pid %s. Quit the app and run this again.\n' "$pid"
        exit 1
      fi
    done
    printf '  all stopped\n'
  fi
fi

# --- copy, verify, swap ------------------------------------------------------

# The only paths this script ever deletes are the two temporaries below, and a
# previous /Applications/relay.app by way of renaming it to $BACKUP first. This
# runs on every exit: after success $BACKUP is already gone, and after a failure
# mid-swap it puts the previous install back.
cleanup() {
  # Tolerated so that a failure here can never skip the restore below.
  if [ -d "$STAGE" ]; then rm -rf "$STAGE" || true; fi
  if [ -d "$BACKUP" ]; then
    if [ -d "$DEST" ]; then rm -rf "$BACKUP"; else mv "$BACKUP" "$DEST"; fi
  fi
}
trap cleanup EXIT

step 'copying'
# ditto, not cp -R or rsync: it carries extended attributes, ACLs and mtimes
# intact. Signatures of non-Mach-O resources live in com.apple.cs.* xattrs, and
# cp -R rewrites every directory mtime. macOS now ships openrsync, whose xattr
# flags differ from GNU rsync, so rsync is not portable here either.
run ditto "$SRC" "$STAGE"

step 'verifying the staged copy'
# Verified before the swap so a bad copy can never replace a working install.
# Gatekeeper (spctl) is deliberately not consulted: an Apple Development signed,
# un-notarized build is always rejected by assessment, and that is not a fault.
if [ "$DRY_RUN" = yes ]; then
  printf '  would run: codesign --verify --deep --strict %s\n' "$STAGE"
else
  if ! codesign --verify --deep --strict "$STAGE"; then
    printf '\nThe copied bundle does not verify. Nothing was installed.\n'
    exit 1
  fi
  printf '  signature intact\n'
fi

if [ -d "$DEST" ]; then
  step 'replacing the previous install'
  run mv "$DEST" "$BACKUP"
  run mv "$STAGE" "$DEST"
  run rm -rf "$BACKUP"
else
  step 'installing'
  run mv "$STAGE" "$DEST"
fi

step 'verifying the installed bundle'
if [ "$DRY_RUN" = yes ]; then
  printf '  would run: codesign --verify --deep --strict %s\n' "$DEST"
else
  codesign --verify --deep --strict "$DEST"
  # Captured once, because codesign writes this to stderr and there are three
  # fields to pull out of it. The Authority chain repeats up to the root, so
  # only the leaf is printed; sed quits after it rather than piping to head,
  # which would break the pipeline on SIGPIPE under pipefail.
  SIGNATURE="$(codesign -dv --verbose=4 "$DEST" 2>&1)"
  printf '%s\n' "$SIGNATURE" | sed -n 's/^Identifier=/  bundle id: /p'
  printf '%s\n' "$SIGNATURE" | sed -n '/^Authority=/{s//  signed by: /p;q;}'
  printf '%s\n' "$SIGNATURE" | sed -n 's/^TeamIdentifier=/  team:      /p'
fi

# --- LaunchServices ----------------------------------------------------------

step 'LaunchServices'
# lsd registers a bundle by itself moments after it appears; -f only makes that
# synchronous. lsregister is private and undocumented, and its flags do change:
# -kill was removed in macOS 26, and -domain never existed at all — it is a
# silent no-op that exits 0 and reads as success. Only -f, -u and -dump are used.
if [ -x "$LSREGISTER" ]; then
  run "$LSREGISTER" -f "$DEST"
  if [ "$DRY_RUN" = no ]; then
    printf '  registered %s\n' "$DEST"
  fi
else
  printf '  lsregister not found; macOS registers the bundle on its own.\n'
fi

# Other copies sharing this bundle id are worth naming: reset-permissions.sh and
# `open -a relay` are keyed by id or name and cannot tell them apart. A copy in
# /Applications outranks any build-tree copy regardless of version, so leftovers
# are hygiene rather than a problem — but a record whose bundle is gone is pure
# residue, and only -u clears it (-gc and a domain rescan both leave it).
if [ -x "$LSREGISTER" ]; then
  REGISTERED="$("$LSREGISTER" -dump 2>/dev/null |
    sed -n 's/^path:[[:space:]]*\(.*\/relay\.app\) (0x.*$/\1/p' || true)"

  while IFS= read -r path; do
    if [ -z "$path" ] || [ "$path" = "$DEST" ]; then
      continue
    fi
    if [ -d "$path" ]; then
      printf '  also registered: %s\n' "$path"
    else
      printf '  stale record, bundle is gone: %s\n' "$path"
      printf '    clear it with: %s -u "%s"\n' "$LSREGISTER" "$path"
    fi
  done <<EOF
$REGISTERED
EOF
fi

# --- what the user has to do next --------------------------------------------

step 'next steps'
printf '    open %s\n\n' "$DEST"
printf '  Launch with open and the full path. Never the binary inside the\n'
printf '  bundle, and not `open -a relay`. macOS attributes a privacy request\n'
printf '  to the *responsible* process, so a binary exec'"'"'d from a shell is\n'
printf '  judged as that shell — which holds no screen-recording grant — and\n'
printf '  the app then enumerates no sources. `open -a relay` resolves the\n'
printf '  name through LaunchServices and may pick a build-tree copy.\n\n'
printf '  A rebuild does NOT invalidate the grant. The designated requirement\n'
printf '  of this signature names the bundle id and the signing certificate,\n'
printf '  not a cdhash, so every build signed with the same identity satisfies\n'
printf '  the stored requirement. Verify with:\n\n'
printf '    codesign -d -r- %s\n\n' "$DEST"
printf '  Do NOT run tool/reset-permissions.sh to "fix" a denial. It deletes a\n'
printf '  working grant. A denial after a rebuild almost always means the app\n'
printf '  was launched by a shell or by `flutter run`, not that the permission\n'
printf '  expired. Check the attribution instead:\n\n'
printf '    /usr/bin/log show --last 15m --predicate '"'"'subsystem == "com.apple.TCC"'"'"' \\\n'
printf '      --info --debug | grep AUTHREQ_ATTRIBUTION | grep com.relay.relay\n\n'
printf '  Use the absolute /usr/bin/log. Some shells carry a `log` function or\n'
printf '  alias that shadows it and answers "too many arguments" with an empty\n'
printf '  result, which reads as "no TCC records exist".\n\n'
printf '  A line with no `responsible=` field is the app answering for itself,\n'
printf '  which is what a grant needs. A line naming another process as\n'
printf '  responsible is the launch method being wrong.\n\n'
printf '  Only the attribution line names the app. tccd splits one request\n'
printf '  across three lines joined by msgID — AUTHREQ_CTX carries the service,\n'
printf '  AUTHREQ_ATTRIBUTION the client and the responsible process, and\n'
printf '  AUTHREQ_RESULT the authValue — so grepping the result lines for\n'
printf '  "relay" matches nothing and looks, wrongly, like no records exist.\n'

if [ "$DRY_RUN" = yes ]; then
  printf '\n\033[1mDry run: nothing was changed.\033[0m\n'
else
  printf '\n\033[1mInstalled %s version %s (%s) at %s.\033[0m\n' \
    "$LOWER_CONFIGURATION" "$VERSION" "$BUILD_NUMBER" "$DEST"
fi
