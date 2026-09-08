<h1 align="center">Relay</h1>

<p align="center">
  <strong>A desktop screen recorder that sends the recording somewhere useful.</strong><br>
  Records a screen or a window, then uploads it — to Telegram or WebDAV.
</p>

<p align="center">
  <a href="https://github.com/shishkinartem/Relay/actions/workflows/ci.yml">
    <img alt="CI" src="https://github.com/shishkinartem/Relay/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%20%7C%20Windows-lightgrey">
  <img alt="Flutter" src="https://img.shields.io/badge/Flutter-3.47.1-02569B?logo=flutter&logoColor=white">
  <img alt="Output" src="https://img.shields.io/badge/output-MP4%20%C2%B7%20H.264%20%C2%B7%20AAC-blue">
</p>

<p align="center">
  <img src="docs/images/recorder.png" alt="Recorder panel" width="380">
</p>

<p align="center">
  <img src="docs/images/control-strip.png" alt="Recording control strip" width="560">
</p>

---

Most screen recorders stop at the file. Relay treats delivery as part of the job: when the
recording ends you either send it or delete it, and the local file is never removed until a
remote copy is confirmed.

- One entire screen or one application window, cursor included.
- Camera composited into the video as a picture-in-picture — dragged where you want it,
  shaped by one of three presets.
- Pick the camera and microphone from your real devices, before **and during** a
  recording; the microphone shows a live level so you can choose one by speaking.
- Microphone and system audio mixed into one track.
- The control strip goes wherever you drag it, and is excluded from the capture — it
  never appears in the output.
- Pause and resume; 720p or 1080p, 30 or 60 fps.
- Send to **Telegram** or **WebDAV** — neither needs a developer account, an API console,
  or a payment method.

<p align="center">
  <img src="docs/images/ready.png" alt="Post-recording screen" width="380">
</p>

## Install

There is no tagged release yet. A build is either one you make below, or one someone hands you
— and for Windows, one you download from CI (the `Windows build` job publishes
`relay-windows-x64` on every run).

### macOS

Requires **macOS 13.5 or newer**. The bundle is universal (`x86_64` + `arm64`), but only Apple
Silicon has ever been run.

1. Open `relay-<version>.dmg` and drag **relay.app** onto **Applications**. Install it there and
   nowhere else: LaunchServices and TCC resolve `com.relay.relay` by whichever copy they rank
   first, so a stray copy in a build tree can quietly take the permission you granted.
2. The app is signed **Apple Development** — not Developer ID, not notarized — so Gatekeeper
   refuses it on every Mac but the one that built it, reporting the app as damaged or the
   developer as unverifiable. Clear the quarantine flag:
   ```bash
   xattr -dr com.apple.quarantine /Applications/relay.app
   ```
3. Launch it from Finder, or by full path — never the binary inside the bundle:
   ```bash
   open /Applications/relay.app
   ```
   macOS attributes a screen-recording request to the *responsible* process. A binary started
   from a shell is judged as that shell, and Relay then enumerates zero screens.
4. Relay opens on a preflight screen. Press **Allow screen recording…**, switch Relay on under
   **Privacy & Security → Screen & System Audio Recording**, then use **Quit and reopen Relay** —
   macOS applies the answer only at the next start. Microphone and camera are different: refuse
   either and the recording still happens, without that track.
5. Open **Settings → Upload destination → Set up** and connect **Telegram** (a bot token and a
   chat id, both obtained inside the messenger) or **WebDAV** (address, user name, app password).
   Credentials are verified before they are stored, so a typo is reported there and then. Until
   one is connected, Send reports *not configured* and keeps the file.

Screen recording is granted **once, not once per update**: a certificate-based signature gives a
designated requirement that TCC stores instead of the code's hash, so a later build by the same
developer still satisfies it. Only an ad-hoc signature loses the grant on every rebuild.

Recordings go to `~/Movies/Relay`, settings to
`~/Library/Application Support/com.relay.relay/settings.json`, credentials to the Keychain. All
three survive reinstalling the app.

### Windows

Requires **Windows 10 build 19041 (2004) or newer**, x64 — the plugin checks that build number
at startup and refuses to run below it.

Also requires the **Microsoft Visual C++ 2015–2022 Redistributable (x64)**. This is not
optional and not an OS component: `relay.exe` and every plugin DLL link `/MD` against
`vcruntime140.dll`, `vcruntime140_1.dll` and `msvcp140.dll`, and nothing in the build copies
them. On a machine that has never had Visual Studio the app does not start — it shows a
*`vcruntime140_1.dll` was not found* dialog, which looks like Relay being broken. Install it
from Microsoft first. (Windows **N / KN** editions additionally need the *Media Feature Pack*:
the recorder links Media Foundation, and without it the process fails to start rather than
degrading.)

There is no installer and no single file. The build *is* the folder: `relay.exe` is a launcher
that needs its neighbours (`flutter_windows.dll`, the plugin DLLs, `data\`). Download
`relay-windows-x64` from the latest green CI run, unzip it anywhere, run `relay.exe`.
SmartScreen will object to an unknown publisher — *More info* → *Run anyway*; this project
configures no Authenticode certificate.

Windows asks for no permission to capture the screen; microphone and camera are governed by
*Settings → Privacy*. Recordings go to `%USERPROFILE%\Videos\Relay`.

**Nobody has ever run Relay on Windows.** The C++ half compiles under MSVC in CI and its native
unit tests pass there — that is the entire body of evidence, and a compiler cannot tell you a
recording comes out. The [compatibility matrix](docs/development/compatibility-matrix.md) is the
authority on what is actually verified, and
[the Windows smoke test](docs/development/windows-smoke-test.md) is the ordered script for
changing that.

## Build from source

Requires **Flutter 3.47.1** (the version CI pins) and the platform's own toolchain: Xcode for
macOS, Visual Studio 2022 with the *Desktop development with C++* workload for Windows. Flutter
does not cross-compile desktop targets — each platform is built on itself.

```bash
flutter pub get
flutter build macos --release
open build/macos/Build/Products/Release/relay.app

./tool/package-dmg.sh --build   # wrap it for someone else -> build/relay-<version>.dmg
./tool/validate.sh              # format, analyze, every package's tests
```

```powershell
# on a Windows machine
flutter pub get
flutter build windows --release
```

Building with no Apple account works — put `CODE_SIGN_IDENTITY = -` in a git-ignored
`macos/Runner/Configs/Signing.local.xcconfig` — at the price of re-granting screen recording
after every rebuild, because an ad-hoc designated requirement is the code's own hash.
`./tool/package-dmg.sh --sign "Developer ID Application: …" --notarize <profile>` is the one
combination that opens with a double click on any Mac, and it needs a paid membership.

## Documentation

| | |
|---|---|
| [Connecting Telegram or WebDAV](docs/upload-destinations.md) | step-by-step setup, and lifting Telegram's 50 MB limit |
| [Running locally](docs/development/running-locally.md) | Xcode, permissions, tests, packaging a build to send |
| [Engineering docs](docs/README.md) | architecture, testing, design system, decisions |
| [`TECHNICAL_SPEC.md`](TECHNICAL_SPEC.md) | product and technical behaviour — the source of truth |

## Status

macOS is built, run and tested. Windows compiles under MSVC in CI and its native unit
tests pass there, but nobody has run the application — see the
[compatibility matrix](docs/development/compatibility-matrix.md) for exactly what is and
is not verified. Linux is deferred by design.

## Contributing

```bash
./tool/validate.sh
```

Behavioural changes need tests; anything expensive to reverse needs an
[ADR](docs/adr/README.md). House rules are in
[`docs/development/code-quality.md`](docs/development/code-quality.md).

## Licence

None yet — which means all rights reserved. Add one before expecting reuse.
