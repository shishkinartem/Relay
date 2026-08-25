# Compatibility matrix

"Supported" means built **and** the basic flow exercised, not merely compilable
(`code-quality.md`). Anything not verified says so.

| Platform | Minimum version | Display capture | Window capture | System audio | Microphone | Camera | Cursor | 30 FPS | 60 FPS |
|---|---|---|---|---|---|---|---|---|---|
| macOS | 13.5 *(provisional, §30.8)* | built + run | built + run | built | built | built | built | built | built |
| Windows | 10 build 19041 *(provisional, §30.9)* | not built | not built | not built | not built | not built | not built | not built | not built |
| Linux | — | deferred (§2) | deferred | deferred | deferred | deferred | deferred | deferred | deferred |

## What "built + run" covers on macOS

Verified on macOS 26.5.2 (arm64) with Flutter 3.47.1:

- the application builds, launches and registers `RecorderMacos`;
- source enumeration returns displays before windows, with still thumbnails;
- both overlay windows are created and reach the capture exclusion list —
  asserted by `integration_test/macos_recording_test.dart`;
- the permission preflight reports and requests correctly.

`integration_test/macos_recording_test.dart` additionally records a real
display source, pauses, resumes, stops and asserts the produced MP4.

**Two gates skip it, in this order.** First the `platform` tag, which
`dart_test.yaml` configures to skip — so a run without `--run-skipped` executes
nothing and still exits 0:

```bash
flutter test integration_test -d macos --run-skipped
```

Only then does the second gate apply: the recording test skips when
`canRecordScreen` is false, and it reports that skip rather than passing silently.
If you have granted screen recording and still see zero tests, it is the first gate,
not a permission problem.

## Provisional minimum versions

Both minimums are **open questions in the specification** (§30.8, §30.9) and are
recorded here as build settings, not as resolved decisions.

macOS 13.5 is the floor. 13.0 is what this application's own APIs need, but
Flutter 3.47's `flutter_additional_macos_build_settings` builds every plugin
pod at a 13.5 deployment target, so a Runner declaring 13.0 fails to link
against them — the error surfaces the moment `GeneratedPluginRegistrant.swift`
is recompiled, which is also why an Xcode build failed while an incremental
`flutter build` appeared to succeed. The application's own requirement is:

| API | Needed for | Available from |
|---|---|---|
| `SCStream`, `SCContentFilter` | display and window capture | 12.3 |
| `SCStreamConfiguration.capturesAudio` | system audio (§8) | 13.0 |
| `SCScreenshotManager` | source thumbnails | 14.0 — falls back to `CGDisplayCreateImage` / `CGWindowListCreateImage` on 13 |
| `SCStreamConfiguration.captureMicrophone` | not used — microphone comes from AVFoundation, which works on 13 | 15.0 |

Windows 10 build 19041 is what `Windows.Graphics.Capture` with
`IsCursorCaptureEnabled` requires. Nothing on Windows has been compiled.

## Native unit tests

The pure half of each platform — the wire contract, the picture-in-picture
geometry, the canvas arithmetic and the session clock — is now separated from
the Flutter- and OS-bound half so it can be executed on its own.

| Platform | Where | How to run | State |
|---|---|---|---|
| macOS | `packages/recorder_macos/macos/recorder_macos/core` | `swift test` | **47 tests passing** |
| Windows | `packages/recorder_windows/windows/test` | `cmake -S … -B build/win-tests && ctest --test-dir build/win-tests` | written, **never compiled** |

Both suites assert the same properties on purpose. The two platforms hand-write
the same wire spellings and re-implement the same geometry, and nothing in the
Dart layer can observe them disagreeing — mirroring the assertions is the only
thing that catches drift. It already has: `ResolvePipRect` and
`CameraOverlayConfiguration.effectiveAspectRatio` handled a malformed aspect
ratio differently (a square tile against a 0.0001-ratio sliver) and were aligned
on the default 16:9.

## Not verified

```text
NOT RUN: Windows native build (packages/recorder_windows/windows/CMakeLists.txt)
Reason: no MSVC toolchain, no Windows SDK and no cmake on the development host (macOS).

NOT RUN: Windows native unit tests (packages/recorder_windows/windows/test)
Reason: same. The suite is written and its assertions were checked line by line
against recorder_types.cpp, but a test that was not run is not a test that
passed.

NOT RUN: fragmented MP4 output on Windows
Reason: same. docs/adr/2026-08-23-fragmented-mp4-on-both-platforms.md changes
the sink writer's container type so an aborted `.part` is recoverable; it must
be compiled and a mid-session abort confirmed recoverable before release.

NOT RUN: Windows integration tests
Reason: same.

NOT RUN: integration_test/ in CI
Reason: `flutter test integration_test -d macos --run-skipped` does not terminate. Measured
2026-08-25: 1h35m on a macos-15 runner with no output, killed only by the next push, and
the same hang locally on a host that does hold the screen-recording grant. Without
--run-skipped the `platform` tag skips everything and the job passes having run nothing.
The suite is therefore run by hand and watched. The hang itself is undiagnosed.

NOT RUN: §24 soak tests (60 min 1080p30, 60 min 1080p60, disk-full, network loss)
Reason: each run exceeds an interactive session; they are release gates, not per-change gates.

NOT RUN: tool/package-dmg.sh notarization path
Reason: no Developer ID certificate on this host.
```

## Known gaps

- **Windows is written but not built.** No MSVC toolchain on the development
  host — see *Not verified* above.
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

## macOS packaging notes

**The App Sandbox is off.** Recordings are written to `~/Movies/Relay`, which the
design and §18 treat as the user's own folder; a sandboxed build would write
into its container instead. Re-enabling the sandbox for Mac App Store
distribution means adding `com.apple.security.files.user-selected.read-write`
and holding a security-scoped bookmark for the folder chosen in Settings. The
camera and audio-input entitlements are already declared either way.

**Screen-recording permission does survive a rebuild**, with an Apple Development
signature. Measured on this host 2026-08-25: the Debug and Release bundles have
different `CDHash` values and the same designated requirement
(`identifier "com.relay.relay" … certificate leaf[subject.CN] = "Apple Development: …"`),
and TCC stores the requirement rather than the hash.

An earlier note here said the opposite. It was wrong for identity-signed builds; it
is correct only for ad-hoc ones (`CODE_SIGN_IDENTITY = -`), whose requirement is a
`cdhash`. `./tool/reset-permissions.sh` is for that case alone — on an
identity-signed build it deletes a working grant. Full write-up:
`macos-tcc-and-launchservices.md`.

Developer ID plus notarization is what a distributed DMG needs: a build signed with
a **Developer ID Application** certificate and notarized keeps its permission
across updates, which is what a distributed DMG needs. No Developer ID
certificate was available on this host, so that path is untested here.

Signing is configured in `macos/Runner/Configs/Signing.xcconfig`, overridable
per machine through a git-ignored `Signing.local.xcconfig`. Set
`CODE_SIGN_IDENTITY = -` there to build with no Apple account at all, at the
cost of re-granting screen recording after every rebuild (§23).
