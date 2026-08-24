# packages/

Six workspace packages. `../CLAUDE.md` still applies; this adds only what matters here.

| Package | Language | Suite |
|---|---|---|
| `recorder_platform_interface` | Dart | `flutter test` |
| `recorder_macos` | Dart shim + Swift | Swift, below. Its Dart `test/` is empty. |
| `recorder_windows` | Dart shim + C++ | `flutter test` here, plus the C++ suite below |
| `upload_core`, `upload_telegram`, `upload_webdav` | Dart | `dart test` |

## The two native suites are not run by `tool/validate.sh`

```bash
# macOS — no Flutter needed; the pure half was split out precisely so this works
swift test    # in packages/recorder_macos/macos/recorder_macos/core

# Windows — Windows host only
cmake -S packages/recorder_windows/windows/test -B build/win-tests
cmake --build build/win-tests --config Debug
ctest --test-dir build/win-tests -C Debug --output-on-failure
```

Both run in CI as their own jobs. A green `tool/validate.sh` says nothing about either.

## Changing the wire contract

`docs/architecture/platform-channel-contract.md` is the contract. Method names are
hand-written string literals on both sides — Dart in
`recorder_platform_interface/lib/src/method_channel/`, Swift in `RecorderMacosPlugin.swift`,
C++ in `recorder_windows_plugin.cpp`. Nothing checks that the three agree except the two
native suites.

**Change both platforms or neither**, and update the contract doc in the same change.

## Geometry is duplicated in three languages

Camera PiP and canvas arithmetic exist in Dart (`camera_overlay_configuration.dart`),
Swift (`RecorderContract.swift`) and C++ (`recorder_types.h`), each with its own tests.
Current values: `widthRatio: 0.16`, the camera's own aspect ratio, `marginRatio: 0.01`
(`docs/adr/2026-08-23-camera-pip-follows-source-aspect.md`). Change all three and their
tests together.

Known asymmetry: `LetterboxRect` is asserted on Windows only. The macOS counterpart sits
in `VideoCompositor.swift`, outside `RecorderCore`, so `swift test` cannot reach it.

## Windows has never been compiled on this host

Record verification gaps in `docs/development/compatibility-matrix.md` rather than in a
fresh ad-hoc note.
