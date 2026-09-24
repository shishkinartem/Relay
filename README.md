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
- Pause and resume, and an optional countdown before the recording starts.
- The source's own resolution by default, or 720p / 1080p; 30 or 60 fps.
- Send to **Telegram** or **WebDAV** — neither needs a developer account, an API console,
  or a payment method — and optionally keep a copy after sending.

<p align="center">
  <img src="docs/images/ready.png" alt="Post-recording screen" width="380">
</p>

## Install

Download the build for your computer from the newest entry on the
**[Releases page](https://github.com/shishkinartem/Relay/releases)** — a `.dmg` for macOS 13.5
or later, a `.zip` for 64-bit Windows 10 (version 2004) or later and Windows 11.
**[The installation guide](docs/install.md)** walks through every step below, and what to do
when one of them goes wrong.

### macOS

1. Open the `.dmg` and drag **relay** onto **Applications**.
2. Relay is not notarized by Apple, so macOS reports it as damaged until the download flag is
   cleared:
   ```bash
   xattr -dr com.apple.quarantine /Applications/relay.app
   ```
3. Open Relay from Applications, press **Allow screen recording…**, switch **relay** on in
   **System Settings → Privacy & Security → Screen & System Audio Recording**, then **Quit and
   reopen Relay**. Microphone and camera are asked for when first used, and are optional.

### Windows

1. Extract the `.zip` and keep the **Relay** folder together — `relay.exe` needs the files beside
   it. The Visual C++ runtime is included.
2. Run `relay.exe`. SmartScreen does not know the publisher: **More info → Run anyway**.
3. Screen capture needs no permission; microphone and camera follow **Settings → Privacy &
   security**.

### Then, on either

Open **Settings → Upload destination → Set up** and connect **Telegram** (a bot token and a chat
id, both obtained inside the messenger) or **WebDAV** (address, user name, app password) — see
[Connecting an upload destination](docs/upload-destinations.md). Credentials are checked before
they are stored, and until one is connected, Send keeps the file and says why.

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
| [Installing Relay](docs/install.md) | downloading, first launch, updating, uninstalling, troubleshooting |
| [Connecting Telegram or WebDAV](docs/upload-destinations.md) | step-by-step setup, and lifting Telegram's 50 MB limit |
| [Running locally](docs/development/running-locally.md) | Xcode, permissions, tests, packaging a build to send |
| [Releasing](docs/development/releasing.md) | turning a tag into a published release |
| [Engineering docs](docs/README.md) | architecture, testing, design system, decisions |
| [`TECHNICAL_SPEC.md`](TECHNICAL_SPEC.md) | product and technical behaviour — the source of truth |

## Status

macOS is built, run and tested. Windows is built and run, and still in testing: it has been
through three rounds on Windows 11, each followed by fixes, and has known issues open. The
[compatibility matrix](docs/development/compatibility-matrix.md) says exactly what is and is not
verified on each platform. Linux is deferred by design.

## Contributing

```bash
./tool/validate.sh
```

Behavioural changes need tests; anything expensive to reverse needs an
[ADR](docs/adr/README.md). House rules are in
[`docs/development/code-quality.md`](docs/development/code-quality.md).

## Licence

None yet — which means all rights reserved. Add one before expecting reuse.
