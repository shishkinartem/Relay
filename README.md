<h1 align="center">Relay</h1>

<p align="center">
  <strong>A desktop screen recorder that sends the recording somewhere useful.</strong><br>
  macOS and Windows · one screen or one window · camera PiP · mic + system audio · one MP4 out.
</p>

<p align="center">
  <a href="https://github.com/shishkinartem/Relay/actions/workflows/ci.yml">
    <img alt="CI" src="https://github.com/shishkinartem/Relay/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%20%7C%20Windows-lightgrey">
  <img alt="Flutter" src="https://img.shields.io/badge/Flutter-3.47.1-02569B?logo=flutter&logoColor=white">
  <img alt="Output" src="https://img.shields.io/badge/output-MP4%20%C2%B7%20H.264%20%C2%B7%20AAC-blue">
</p>

---

Most screen recorders stop at the file. Relay treats **delivery** as part of the job:
when the recording ends you either send it or delete it, and the local file is never
removed until a remote copy is confirmed.

The two upload destinations were chosen against one constraint — **neither needs a
developer account, an API console, or a payment method.** A Telegram bot is created
inside the messenger; WebDAV needs an app password from storage you already have.

## What it does

- **Capture** one entire screen or one selected application window, cursor included,
  chosen from a source list inside the app rather than the OS picker.
- **Composite the camera** into the video itself as a picture-in-picture — at the
  camera's own aspect ratio, never cropped, never stretched. The preview is mirrored;
  the recording is not.
- **Mix microphone and system audio** into one track. Refusing either degrades the
  session instead of blocking it: a denied mic records silence-free video, not an error.
- **Keep the controls out of the recording.** The control strip is an always-on-top
  native panel that is explicitly excluded from the capture — it never appears in the
  output.
- **Pause and resume** mid-session.
- **720p or 1080p, 30 or 60 fps**, written as fragmented MP4 so an interrupted session
  leaves a playable file rather than a corrupt one.
- **Send to Telegram or WebDAV**, or start a new recording and keep the file.

## Status

| | |
|---|---|
| **macOS** | Built, run and tested on macOS 26.5. This is the developed platform. |
| **Windows** | Fully written — Windows.Graphics.Capture, WASAPI, Media Foundation — and unit-tested in CI, but **never compiled or run on a real Windows machine.** No MSVC host was available. See the [compatibility matrix](docs/development/compatibility-matrix.md). |
| **Linux** | Deferred by design, not by accident: the platform contract is capability-driven so an implementation can be added without touching feature code. |

Relay is a specification-driven project. Product behaviour lives in
[`TECHNICAL_SPEC.md`](TECHNICAL_SPEC.md), decisions that were expensive to reverse live
as [ADRs](docs/adr/README.md), and the layering rules are
[enforced by a test](test/architecture_test.dart) rather than described in prose.

## Documentation

| | |
|---|---|
| [`TECHNICAL_SPEC.md`](TECHNICAL_SPEC.md) | product and technical behaviour — the source of truth |
| [`docs/`](docs/README.md) | engineering documentation index |
| [`docs/adr/`](docs/adr/README.md) | 12 recorded architecture decisions |
| [`docs/development/how-to-install.md`](docs/development/how-to-install.md) | building, installing and distributing, in plain language (Russian) |
| [`design/`](design/README.md) | the connected design — open `design/preview.html` |
| [`CLAUDE.md`](CLAUDE.md) | always-on rules for coding agents working in this repo |

## Requirements

| | |
|---|---|
| Flutter | 3.47.1 (Dart 3.13.1) |
| macOS | 13.5 or later, Xcode 26 |
| Windows | 10 build 19041 or later, MSVC + Windows SDK — **not built or tested; see the compatibility matrix** |

## Running it

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
([why](docs/adr/2026-08-23-optional-inputs-degrade-instead-of-blocking.md)).

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
[macos-tcc-and-launchservices.md](docs/development/macos-tcc-and-launchservices.md).

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

[`docs/development/how-to-install.md`](docs/development/how-to-install.md) explains the whole build and
distribution story for both platforms in plain language, including the Windows
side, which ships as a folder rather than as a single file.

## Connecting an upload destination

Open **Settings → Upload destination → Set up**. Two destinations ship, and
neither needs a developer account, an API console or a payment method.
Credentials go to the macOS Keychain / Windows Credential Manager, never to a
file (§27).

| | Setup | Per-file limit | Good for |
|---|---|---|---|
| **Telegram** | a bot token and a chat id, both from inside the messenger | 50 MB, or 2000 MB with your own server | sending a clip to a chat |
| **WebDAV** | an app password from your storage provider | none | anything that does not fit in a chat |

### Telegram

1. In Telegram, message **@BotFather** and send `/newbot`. Follow the prompts
   and copy the HTTP API token.
2. Send your new bot a message — or add it to the group or channel you want
   recordings in and post one message there. A bot cannot open a conversation
   itself, so this step is what makes the chat reachable.
3. Open `https://api.telegram.org/bot<your token>/getUpdates` in a browser and
   copy the numeric `"chat":{"id":…}` from the message you just sent. A channel
   id starts with `-100`.
4. Paste the token and the chat id into **Set up** and press **Connect**. Relay
   calls `getMe` and `getChat` before storing anything, so a typo is reported
   there and then.

### WebDAV (Koofr, Nextcloud, …)

WebDAV is a protocol rather than a service, so this works with any server that
speaks it. The suggested provider is [Koofr](https://koofr.eu): 10 GB free,
WebDAV included on the free plan, and app passwords you can revoke one at a
time. That is roughly eleven hours of 720p recording.

1. Sign up at koofr.eu.
2. Open *Preferences → Password → app-specific passwords*, create one for Relay
   and copy it. This is not your account password — providers reject that one on
   WebDAV.
3. In Relay, fill in:

   | Field | Koofr | Nextcloud |
   |---|---|---|
   | WebDAV address | `https://app.koofr.net/dav/Koofr` | `https://<host>/remote.php/dav/files/<user>` |
   | User name | the email you signed up with | your Nextcloud user name |
   | App password | the generated one | *Settings → Security → Devices & sessions* |
   | Folder | optional, `Relay` by default | same |

4. Press **Connect**. Relay checks the credentials with `PROPFIND` and creates
   the folder with `MKCOL` before storing anything, so a wrong address or a
   rejected password is reported there and then.

There is no size limit beyond your storage quota. There is also no resume: WebDAV
has no standard way to continue a partial upload, so an interrupted transfer
starts over — the recording stays on disk either way (§13).

**Yandex.Disk is not recommended**, although it would work: its WebDAV is
throttled to roughly a minute per megabyte, which turns a 50 MB recording into
an hour-long upload.

**Disconnect** forgets the credentials and survives a restart.

## Lifting Telegram's 50 MB limit

Only worth doing if you want long recordings *in a Telegram chat specifically*;
otherwise use WebDAV above, which has no limit and needs no server.

The hosted Bot API accepts at most 50 MB per video — about a minute and a half
at 1080p30, three and a half at 720p30. Telegram publishes the server itself,
and running your own raises the ceiling to **2000 MB**. It is free: no fees, no plan, nothing to register beyond
an `api_id` for your own Telegram account.

> Finish the four steps above **first**. Step 3 reads `getUpdates` from the
> hosted API, and logging the bot out of it (step 3 below) locks you out of the
> hosted API for 10 minutes.

1. **Get an `api_id` and `api_hash`.** Sign in at
   [my.telegram.org](https://my.telegram.org) → *API development tools* → fill
   in any app name. These identify *your Telegram account*, not the bot, and are
   free. Keep them out of the repository.

2. **Run the server.** Either is fine; Docker is less work.

   ```bash
   docker run -d --name telegram-bot-api --restart=always \
     -p 8081:8081 -v telegram-bot-api-data:/var/lib/telegram-bot-api \
     -e TELEGRAM_API_ID=<api_id> -e TELEGRAM_API_HASH=<api_hash> \
     -e TELEGRAM_LOCAL=true \
     aiogram/telegram-bot-api:latest
   ```

   Or build [telegram-bot-api](https://github.com/tdlib/telegram-bot-api) from
   source — the project generates per-OS instructions at
   [tdlib.github.io/telegram-bot-api/build.html](https://tdlib.github.io/telegram-bot-api/build.html);
   there is no Homebrew formula — and run it:

   ```bash
   telegram-bot-api --api-id=<api_id> --api-hash=<api_hash> --local --http-port=8081
   ```

3. **Log the bot out of the hosted API.** A bot lives on one Bot API server at a
   time, and Telegram requires this before it runs locally. This is the step
   that is easy to miss.

   ```bash
   curl "https://api.telegram.org/bot<your token>/logOut"
   ```

4. **Point Relay at it.** Settings → Telegram → Set up → **Bot API base URL** =
   `http://127.0.0.1:8081` → **Connect**. Relay re-checks the token and the chat
   against the new endpoint, the `50 MB max` tag disappears from the
   destination, and the pre-flight stops refusing large recordings.

The server has to be running whenever you press Send. It runs on your machine —
nothing goes through it except your own uploads on their way to Telegram.

To go back to the hosted API, clear the base URL field, and call
`close` on the local server first:
`curl "http://127.0.0.1:8081/bot<your token>/close"`.

## Configuration

A build can be pre-seeded so it ships already connected. This is a development
and internal-deployment convenience; anything connected in Settings takes
precedence, and a disconnect is not undone by it.

```bash
cp .env.example .env
```

| Key | Used by |
|---|---|
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | Telegram Bot API |
| `TELEGRAM_BOT_API_BASE_URL` | optional; your own Bot API server, e.g. `http://127.0.0.1:8081` |

With no credentials from either route, Send reports a typed *not configured*
error and the recording stays on disk.

The file is looked for in this order, and the first one that exists wins:

1. `$RELAY_ENV_FILE`, if it is set;
2. `.env` in the working directory — `flutter run` from the repository root;
3. `.env` beside the executable — the whole Windows bundle is one directory;
4. `relay.app/Contents/Resources/.env` — inside a macOS bundle;
5. `.env` beside `settings.json` in application support — droppable into an
   installed build without touching a signed bundle.

There is more than one because a bare relative `.env` resolves against the
process working directory, which is the repository root under `flutter run` and
`/` for a bundle the Finder launched: the file used to work in development and
be silently ignored in an installed build. Startup logs `environment_loaded`
with the path it read and the key names — never a value.

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

## Layout

```text
lib/
├── app/                  composition root, shell, state-driven routing
├── core/                 settings, logging, formatting, environment, errors
├── design_system/        tokens, icons, components — ported from design/_ds
├── features/
│   ├── recorder/         session state machine, orchestration, screens
│   ├── settings/
│   └── post_recording/   ready, send, delete
└── upload/               coordinator, registry, credential storage

packages/
├── recorder_platform_interface/   the Flutter ↔ native contract, once
├── recorder_macos/                ScreenCaptureKit, AVFoundation, VideoToolbox
├── recorder_windows/              Windows.Graphics.Capture, WASAPI, Media Foundation
├── upload_core/                   destination-agnostic upload contract
├── upload_telegram/
└── upload_webdav/
```

Feature code depends on `recorder_platform_interface` and `upload_core` only.
It never imports a platform API, and never imports Telegram or WebDAV.

## Known gaps

- **Windows is written but not built.** No MSVC toolchain on the development
  host. See [the compatibility matrix](docs/development/compatibility-matrix.md).
- **Open specification decisions** are implemented conservatively and marked in
  code rather than silently resolved: §30.3 (non-16:9 sources), §30.4 (pause
  timeline — implemented as "paused time is excluded", the recommendation),
  §30.7 (main window changing display mid-recording), §30.8 / §30.9 (minimum OS
  versions).
- **Design gaps** the canvas does not cover — `preparing`, `stopping`,
  `finalizing`, `deleting` and the fatal capture errors — are built from
  existing components only, and marked `design gap:` in the source.
- **Soak tests (§24)** have not been run.
- **No licence file yet.** Without one the default is "all rights reserved", which
  blocks reuse — add one before making the repository public if that is not intended.

## Contributing

`CLAUDE.md` is the short version of the house rules; `docs/development/code-quality.md`
is the long one. Before opening a PR:

```bash
./tool/validate.sh
```

Behavioural changes need tests, and anything expensive to reverse needs an
[ADR](docs/adr/README.md).
