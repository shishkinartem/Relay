# Running Relay locally

**Status:** Current
**Scope:** building and running a local macOS build, permissions, and packaging a build to send
**Review when:** the Flutter version, the Xcode pre-action, or the signing setup changes

## Building and running on macOS

```bash
flutter pub get
flutter run -d macos
```

Or the built app:

```bash
flutter build macos --debug
open build/macos/Build/Products/Debug/relay.app
```

Launch it with `open`, not by running the binary directly. macOS attributes
screen-recording permission to the *responsible* process, so a binary started
from a shell is judged as that shell and enumerates no sources.

### From Xcode

Open `macos/Runner.xcworkspace` and press Run. The scheme has a pre-action that
regenerates `macos/Flutter/ephemeral` first, which is what makes this work.

That regeneration is not optional. Flutter rewrites those files on every
`flutter pub get` — including the implicit one inside `flutter test` — and
writes the generated Swift package at its own hardcoded macOS 12.0 floor, below
what `recorder_macos` requires. It also points `FLUTTER_TARGET` at a temporary
file that a finished `flutter test integration_test` has already deleted. Either
one fails an Xcode build on a tree `flutter build` is perfectly happy with. If
Run ever fails with *"requires minimum platform version 13.5"* or a missing
target file, the pre-action did not run — do it by hand:

```bash
flutter build macos --config-only --debug
```

### Screen recording permission

The first launch shows the preflight screen with *Screen & window recording —
Not granted*. Grant it, then **relaunch**: macOS only applies screen-recording
access to a process on its next start.

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
```

Microphone and camera are different: if either is refused, the recording still
happens without that input
([why](../adr/2026-08-23-optional-inputs-degrade-instead-of-blocking.md)).

**A rebuild does not cost you the grant** — as long as the build is signed with a
real identity. TCC stores the *designated requirement*, and for an
`Apple Development` or `Developer ID` signature that names the bundle id and the
certificate rather than the code, so every build signed with the same identity
still satisfies it. Verify with `codesign -d -r- <app>`.

The exception is ad-hoc signing (`CODE_SIGN_IDENTITY = -`), where the requirement
is a `cdhash` and therefore does change on every build. Only then is a reset the
right answer:

```bash
./tool/reset-permissions.sh   # ad-hoc builds only — it deletes a working grant otherwise
```

If an identity-signed build is denied, it is almost always the launch method, not
the signature: see
[macos-tcc-and-launchservices.md](macos-tcc-and-launchservices.md).

Signing lives in `macos/Runner/Configs/Signing.xcconfig` and is overridable per
machine through a git-ignored `Signing.local.xcconfig`. Building with no Apple
account at all works: set `CODE_SIGN_IDENTITY = -` in
`macos/Runner/Configs/Signing.xcconfig`, or override the team per machine in a
git-ignored `Signing.local.xcconfig` beside it.

Signing is not about distribution here. macOS attributes a TCC grant — screen
recording, camera, microphone — to the code signature, and an ad-hoc signature
changes on every rebuild, so the grant has to be given again each time (§23).
A stable identity makes it stick. The team id is the **OU** field of the
certificate, not the value in brackets after the name:

```bash
security find-certificate -c "Apple Development: you@example.com" -p | openssl x509 -noout -subject
```

Signing does **not** open the macOS data-protection keychain: that needs the
`keychain-access-groups` entitlement, which needs a provisioning profile this
project does not carry. Relay falls back to the login keychain for destination
credentials and logs `keychain_fallback` once when it does. Nothing is stored
outside the keychain either way.

## Sending a build to someone

```bash
./tool/package-dmg.sh --build
```

That produces `build/relay-<version>.dmg`. It is only a container: whether the
recipient can open it is decided by the signature inside, and only a **Developer
ID Application** signature plus notarization opens with a double click. The
script says which of the three cases the current bundle is in, and refuses to
submit an un-signable bundle for notarization.

[`docs/development/how-to-install.md`](how-to-install.md) explains the whole build and
distribution story for both platforms in plain language, including the Windows
side, which ships as a folder rather than as a single file.

## Tests

```bash
./tool/validate.sh
```

That runs, across the workspace: `dart format --set-exit-if-changed`,
`flutter analyze`, and every package's tests.

The default suite is fast and hermetic. Two suites are opt-in because they need
a machine:

```bash
# Renders every screen to build/design_review/ for the design comparison
# the UI Definition of Done requires.
flutter test test/tools/render_screens_test.dart --run-skipped

# Real capture on this host. Needs screen-recording permission.
flutter test integration_test -d macos --run-skipped
```
