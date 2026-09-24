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

### macOS

Requires **macOS 13.5+**.

1. Download `relay-<version>-macos.dmg` from the [Releases](https://github.com/shishkinartem/Relay/releases) page.
2. Drag **relay.app** into **Applications**.
3. The app is not notarized, so macOS blocks the first launch. Run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/relay.app
   ```
4. Open Relay, press **Allow screen recording…**, switch Relay on in System Settings, then
   **Quit and reopen Relay**.

### Windows

Requires **Windows 10 (2004) or 11**, x64.

1. Download `relay-<version>-windows-x64.zip` from the [Releases](https://github.com/shishkinartem/Relay/releases) page.
2. Extract it and run `relay.exe` from the **Relay** folder — keep the folder together.
3. SmartScreen does not know the publisher: **More info → Run anyway**.

To send recordings, connect Telegram or WebDAV in **Settings** —
[how](docs/upload-destinations.md).

## Build from source

Requires Flutter 3.47.1, and Xcode or Visual Studio 2022 (*Desktop development with C++*).

```bash
flutter pub get
flutter build macos --release   # or: flutter build windows --release
./tool/validate.sh              # format, analyze, tests
```

No Apple certificate? Put `CODE_SIGN_IDENTITY = -` in a git-ignored
`macos/Runner/Configs/Signing.local.xcconfig`.

## Documentation

| | |
|---|---|
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
