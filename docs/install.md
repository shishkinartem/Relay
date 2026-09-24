# Installing Relay

**Status:** Current
**Scope:** getting a published build onto a Mac or a Windows PC, the first launch, updating,
uninstalling, and the problems people actually hit
**Review when:** the release assets, the minimum OS versions, the signing, or a first-launch
screen change

Relay is a desktop screen recorder for macOS and Windows. Every release is published on the
[Releases page](https://github.com/shishkinartem/Relay/releases) with one download per platform.
To build it yourself instead, see [Build from source](../README.md#build-from-source).

> **Where each platform stands.** macOS is the platform Relay is developed and tested on. The
> Windows build installs, runs and records, and is still being tested — what is and is not
> verified there is in the [compatibility matrix](development/compatibility-matrix.md).

## Download

Open the [Releases page](https://github.com/shishkinartem/Relay/releases), take the newest
entry — while Relay is in testing these are marked *Pre-release* — and download the file for your
computer from its **Assets**:

| File | For |
|---|---|
| `relay-<version>-macos.dmg` | macOS 13.5 or later. One app for Apple silicon and Intel — though only Apple silicon has been tested |
| `relay-<version>-windows-x64.zip` | Windows 10 version 2004 (build 19041) or later, and Windows 11, 64-bit |
| `SHA256SUMS.txt` | checksums, if you want to check the download |

To check a download against `SHA256SUMS.txt`:

```bash
shasum -a 256 relay-<version>-macos.dmg
```

```powershell
Get-FileHash .\relay-<version>-windows-x64.zip -Algorithm SHA256
```

## macOS

### Install

1. Open the `.dmg` and drag **relay** onto **Applications**. Keep this one copy only: macOS gives
   the screen-recording permission to whichever copy of the app it finds first, so a second copy
   somewhere else can quietly take it.
2. Clear the download flag. Relay is not notarized by Apple, so on first launch macOS refuses it
   with *"relay" is damaged and can't be opened* or *Apple could not verify…*. Nothing is
   damaged — open **Terminal** and run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/relay.app
   ```

3. Open Relay from **Applications**, Launchpad or Spotlight — not by running the program inside
   the app bundle from Terminal. macOS gives the screen-recording permission to whatever started
   the program, and a Terminal that started it has none, so Relay would see no screens.

### First launch

**Screen recording** — required. Relay opens on a permission screen:

1. Press **Allow screen recording…**.
2. In **System Settings → Privacy & Security → Screen & System Audio Recording** (called **Screen
   Recording** on macOS 13 and 14), switch **relay** on.
3. Back in Relay, press **Quit and reopen Relay**. macOS applies the permission only when the app
   starts again.

**Microphone and camera** — optional. macOS asks the first time Relay uses each. If you refuse,
recordings still happen, without that track; you can change your mind later under **Privacy &
Security → Microphone** or **Camera**.

## Windows

### Install

1. Download the `.zip`, right-click it and choose **Extract All…**. Do not run Relay from inside
   the zip.
2. Move the extracted **Relay** folder somewhere it can stay — your user folder or **Documents**
   is fine; no administrator rights are needed. Keep the folder together: `relay.exe` needs the
   files next to it and does not work on its own.
3. Open the folder and run **relay.exe**. Windows SmartScreen will say *Windows protected your
   PC*, because the app is not signed with a certificate: press **More info → Run anyway**. It asks
   once.
4. To start Relay from the Start menu or the taskbar, right-click `relay.exe` and choose **Pin to
   Start** or **Pin to taskbar**. On Windows 11 these may be under **Show more options**.

Nothing else is needed: the Visual C++ runtime Relay uses is inside the folder.

**Windows N and KN editions** are the exception — they ship without the Windows media
components Relay records with. Install the **Media Feature Pack** from **Settings → Apps →
Optional features → Add an optional feature** before running Relay; without it, it does not
start.

### First launch

Screen capture needs no permission on Windows.

**Microphone and camera** — optional, and governed by Windows privacy settings. If Relay says it
cannot use either, open **Settings → Privacy & security → Microphone** (or **Camera**; on
Windows 10, **Settings → Privacy**) and make sure both *Microphone access* and *Let desktop apps
access your microphone* are on. Recordings still happen without them, without that track.

Only one Relay runs at a time. Starting it again brings the running one to the front.

## Connect a destination

Relay sends each recording to **Telegram** or to a **WebDAV** server. Neither needs a developer
account or a payment method. Open **Settings → Upload destination → Set up** and follow
[Connecting an upload destination](upload-destinations.md). Relay checks what you enter before
it keeps it, so a typo is reported straight away.

Until a destination is connected, **Send** reports that it is not configured and keeps the
recording on your computer.

## Your first recording

1. **Change** picks what to record: a whole display — the default — or one window.
2. Switch the microphone, system audio and camera on or off.
3. Press **Start recording**. Relay's panel steps aside and a small control strip appears; it is
   never in the recording. On Windows the panel is minimized to the taskbar while you record.
4. Stop from the strip. Then **Send**, **Delete**, or **Keep without sending**.

A recording is only deleted from your computer when you press Delete, or after it has been sent
successfully — and not even then if **Keep a copy on this computer after sending** is on in
Settings.

## Where everything is

| | macOS | Windows |
|---|---|---|
| The app | `/Applications/relay.app` | the **Relay** folder you extracted |
| Recordings | `~/Movies/Relay` | `%USERPROFILE%\Videos\Relay` |
| Settings and the log | `~/Library/Application Support/com.relay.relay/` | `%APPDATA%\com.relay\relay\` |
| Destination passwords | the Keychain | encrypted in the settings folder; the key is in Windows Credential Manager |

Recordings, settings and passwords are not part of the app, so updating or removing Relay leaves
them where they are.

## Updating

**macOS** — quit Relay, drag the new **relay** onto **Applications** and choose **Replace**, then
run the `xattr` command from step 2 again: the new copy carries its own download flag.

Some releases need the screen-recording permission granted again after an update. If Relay
comes back to the permission screen although **relay** is switched on in System Settings, reset
Relay's entry — this touches no other app — and grant it once more:

```bash
tccutil reset ScreenCapture com.relay.relay
```

Then open Relay, press **Allow screen recording…**, and **Quit and reopen Relay**.

**Windows** — quit Relay, delete the old **Relay** folder, and put the new one in its place. If
you pinned the old `relay.exe`, pin the new one.

## Uninstalling

First, open **Settings → Upload destination → Set up** for the connected destination and press
**Disconnect**. That deletes the stored destination password, which removing the app does not.

- **macOS:** drag `/Applications/relay.app` to the Trash. To remove the settings and the log as
  well, delete `~/Library/Application Support/com.relay.relay`.
- **Windows:** delete the **Relay** folder. To remove the settings and the log as well, delete
  `%APPDATA%\com.relay\relay` — paste that into Explorer's address bar to open it.

Your recordings stay in `Movies/Relay` or `Videos\Relay` until you delete them yourself.

## If something goes wrong

| What you see | What to do |
|---|---|
| macOS: *"relay" is damaged and can't be opened* | Step 2 of the macOS install: the `xattr` command. |
| macOS: Relay lists no screens, or keeps asking for screen recording | Quit Relay and open it from Applications. If it still asks after an update, see *Updating*. |
| Windows: *vcruntime140_1.dll was not found* | `relay.exe` has been separated from its folder, or the build did not come from the Releases page. Run it from the complete **Relay** folder; failing that, install the *Microsoft Visual C++ 2015–2022 Redistributable (x64)* from Microsoft. |
| Windows: *MFPlat.DLL was not found*, or another `MF…` file | A Windows N or KN edition: install the Media Feature Pack (see *Windows → Install*). |
| Windows: Relay's window disappears when a recording starts | It is minimized to the taskbar on purpose, so it is not in the recording. Stop from the control strip. |
| Send says the destination is not configured | Connect one: *Connect a destination* above. |

When reporting a problem, attach the log — `relay.log` in the settings folder from the table
above — and say which step behaved differently from this page.
