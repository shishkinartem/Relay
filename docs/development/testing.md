# Testing, CI and Release Gates

## Mandatory rule

Testing is part of implementation.

A behavioral change is not complete until relevant automated tests are added/updated and all applicable validation passes.

## How to run it

```bash
./tool/validate.sh
```

That is `dart format --set-exit-if-changed`, `flutter analyze`, and **every workspace
package's** Dart/Flutter suite. Run `dart format .` first if you meant to reformat.

Root `flutter test` on its own covers the application package only. The six packages
under `packages/` have their own suites and CI runs each separately, so a change to
`upload_telegram` verified by a root run has been verified by nothing.

Four things `validate.sh` does **not** run:

| | Command |
|---|---|
| macOS native (Swift) | `swift test` in `packages/recorder_macos/macos/recorder_macos/core` |
| Windows native (C++) | see *Native unit tests* below — Windows host only |
| real capture on this host | `flutter test integration_test -d macos --run-skipped` |
| design-review renders | `flutter test test/tools/render_screens_test.dart --run-skipped` |

**The last two are tagged skip-by-default in `dart_test.yaml`** (`platform` and
`design-review`). Without `--run-skipped` they report green having run nothing. A green
result is not evidence they passed.

## Required layer by change type

- domain/business logic → unit tests;
- ViewModel/application state → unit tests;
- widget/UI behavior → widget tests;
- service/repository behavior → unit/component tests;
- Flutter/native contract → Dart + native/plugin tests;
- real recording behavior → platform integration tests;
- bug fix → regression test reproducing the failure where practical.

## Platform changes

If macOS native code changes, run affected macOS build/native/plugin/integration tests when the environment supports them.

If Windows native code changes, run affected Windows build/native/plugin/integration tests when the environment supports them.

A shared platform-interface change is not complete until all supported implementations are compatible and tested.

### Native unit tests

The pure half of each platform is separated so it can be executed without a
Flutter build:

```bash
swift test
```

from `packages/recorder_macos/macos/recorder_macos/core`, and

```bash
cmake -S packages/recorder_windows/windows/test -B build/win-tests
cmake --build build/win-tests --config Debug
ctest --test-dir build/win-tests -C Debug --output-on-failure
```

on a Windows host. Both run in CI as their own jobs, neither needs Flutter, and
both assert the mirrored areas — the wire contract, the picture-in-picture geometry,
the canvas arithmetic and the session clock — which is what catches contract drift
between the two platforms, and which nothing in Dart can observe.

The mirroring is not total. `LetterboxRect` is asserted on Windows only; the macOS
counterpart lives in `VideoCompositor.swift` outside `RecorderCore`, so `swift test`
cannot reach it. Treat an assertion present on one side only as an untested area on
the other, not as parity.

A change to the wire contract, the picture-in-picture geometry, the canvas
arithmetic or the session clock must be made and asserted on **both** sides.

## Critical path

Changes affecting these areas require regression/integration coverage where technically practical:

- recording state transitions;
- MP4 finalization/recovery;
- local deletion;
- overlay exclusion;
- A/V synchronization;
- Pause/Resume;
- credentials/tokens;
- upload success/retry/resume;
- source selection (display and window);
- native resource cleanup.

Manual verification alone is insufficient for critical-path behavior.

## Do not hide failures

Never:

- disable a failing test merely to make CI green;
- remove a valid failing test without product reason;
- weaken assertions just because implementation changed unexpectedly;
- add arbitrary sleeps to mask race conditions;
- claim a test passed when it was not run.

If validation cannot run:

```text
NOT RUN: <test/build>
Reason: <concrete environment limitation>
```

Not run ≠ passed.

## CI merge gate

`.github/workflows/ci.yml` has seven jobs, run in parallel on a pinned toolchain:

| Job | Covers |
|---|---|
| `analyze` | `dart format --set-exit-if-changed`, `flutter analyze` |
| `test` | application suite with `--coverage`, then each package suite, then the coverage floor |
| `native-macos` | `swift test` — no Flutter needed |
| `native-windows` | cmake + ctest |
| `build-macos` | unsigned debug build + artefact smoke check |
| `build-windows` | debug build + artefact smoke check |
| `secret-scan` | no tracked `.env`/`credentials.json`/`client_secret*`; no bot-token-shaped literal (`[0-9]{8,}:[A-Za-z0-9_-]{30,}`) under `lib packages macos windows` |

**CI does not run `integration_test/`, and cannot.** It was tried and reverted: with
`--run-skipped` the suite hangs indefinitely instead of finishing — 1h35m on a hosted
runner before a later push cancelled it, and the same hang locally on a machine that does
hold the grant. Without the flag the `platform` tag skips every test and the job is a
false green, which is worse than no job.

So real capture, overlay exclusion, Pause/Resume, `.part` finalization and A/V duration
are verified **only** by running the suite by hand and watching it. There is no Windows
integration test at all. Every job now carries `timeout-minutes: 25` so a hang can never
again run to GitHub's six-hour ceiling.

`secret-scan` does not scan root `test/`, which is why the token-shaped fixtures in
`test/core/logging/` are allowed. Copying one into any `packages/*/test/` file turns CI
red.

Use pinned Flutter/Dart toolchain versions.

Do not expose production credentials to normal PR jobs.

## Coverage

Coverage is diagnostic, not a vanity target.

Prioritize meaningful coverage of:

- state machines;
- destructive file lifecycle;
- upload validation;
- destination connection — verify-before-store, secrets never read back,
  a disconnect that survives a restart;
- retry/resume;
- settings migrations;
- platform contracts.

Do not add meaningless tests merely to raise a percentage.

### The floor is a ratchet

`ci.yml` fails the build below a line-coverage floor computed from
`coverage/lcov.info`. Raise it when the number rises; never lower it to make a
branch green. It exists because coverage was collected and uploaded for months
with nothing ever reading it.

The root `flutter test --coverage` run measures the application *and* the
workspace packages it imports, so a file covered only by its own package suite
reads as zero there. That deflates the headline number rather than inflating
it; check a package's own suite before concluding something is untested.

## Flaky tests

Flaky tests are defects.

Fix deterministic synchronization and root causes. Avoid arbitrary sleeps and broad retry loops.

## Soak/performance tests before release

Baseline MVP scenarios:

- 60 min @ 1080p30;
- 60 min @ 1080p60;
- microphone + system audio;
- camera ON;
- repeated media toggles;
- repeated Pause/Resume;
- source move/resize;
- source closure;
- low/disk-full condition;
- network loss;
- interrupted upload and restart. Neither destination resumes
  (`supportsResume: false`) and that is accepted (`TECHNICAL_SPEC.md` §30.10):
  assert the local file survives the interruption and that a restart succeeds.

Measure at least:

- memory trend/peak;
- CPU;
- dropped frames;
- encoder failures;
- A/V drift;
- output duration;
- output validity;
- upload retry/resume results.

## Release readiness

A release candidate is not ready until all applicable items pass:

- formatter;
- static analysis;
- unit tests;
- widget tests;
- plugin/native tests;
- macOS integration;
- Windows integration;
- required soak/performance tests;
- overlay exclusion verification;
- MP4 playback/finalization verification;
- A/V sync verification;
- failed upload preserves local file;
- successful upload deletion semantics are verified;
- secret/security review;
- compatibility matrix/docs/ADR updated.

Do not describe a release as ready while required validation is failing or unverified.
