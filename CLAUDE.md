# CLAUDE.md

The always-on project map. Not the engineering handbook — it routes to one.

Relay is a Flutter desktop screen recorder for macOS and Windows. The Flutter app is
`lib/`; six workspace packages under `packages/` hold the platform interface, the two
native recorders (Swift, C++) and the three upload packages.

**This repository is not under git.** `git diff`, `git status` and `git log` all fail.
Verify the scope of a change by listing the files you touched and re-reading them.

## Sources of truth

Authority depends on the decision, not on a global ranking.

| Decision | Authority | When something disagrees with it |
|---|---|---|
| Product behavior | `TECHNICAL_SPEC.md`, as amended by accepted ADRs | An **Accepted** ADR dated later than the spec wins on the point it decides. See the spec's *How this file is superseded*. |
| Expensive-to-reverse architecture | the accepted ADR in `docs/adr/` | Supersede it with a new ADR; never contradict one in passing. |
| Visual/UI detail | the connected design, `design/Screen Recorder - Desktop MVP.dc.html` | Loses to the spec on behavior; wins on appearance. Offline render: `design/preview.html`. |
| Layering and platform isolation | `test/architecture_test.dart` | It is executable. A doc that disagrees with the gate is the stale one. |
| Everything else | the docs routed below, then existing conventions | — |

Two standing rules: a `TBD` or `§30` open item in `TECHNICAL_SPEC.md` is unresolved on
purpose — surface it, do not invent an answer; and a spec **summary table** (§2, §31) that
disagrees with the numbered section body is the stale side, because digests drift first.

## Read before coding

Consult `TECHNICAL_SPEC.md` for the behavior your task touches — relevant sections only.
Then the relevant detailed doc:

| Task | Doc |
|---|---|
| UI / design work | `docs/development/design-system.md` |
| recording / session lifecycle | `docs/architecture/recording.md` |
| capture, audio, video, encoding | `docs/architecture/media-pipeline.md` |
| Flutter ↔ native boundary, plugins | `docs/architecture/platform-abstraction.md` |
| method-channel payloads | `docs/architecture/platform-channel-contract.md` — change both platforms or neither |
| Telegram / WebDAV / upload | `docs/architecture/uploads.md` |
| tests, CI, release validation | `docs/development/testing.md` |
| what is actually built and verified per platform | `docs/development/compatibility-matrix.md` |
| macOS permissions, TCC, LaunchServices | `docs/development/macos-tcc-and-launchservices.md` |
| architecture, scalability, security, review | `docs/development/code-quality.md` |
| running locally, permissions, packaging | `docs/development/running-locally.md`; `docs/development/how-to-install.md` (Russian) |
| connecting a destination as a user | `docs/upload-destinations.md` |

Full index: `docs/README.md`. Decision index: `docs/adr/README.md`.

For UI work, inspect the relevant connected design screen/component before implementing.

## Core product invariants

A digest of `TECHNICAL_SPEC.md`, kept here because it is needed on nearly every task. If
it disagrees with the spec-as-amended, the spec wins and this list needs fixing.

- MVP platforms: macOS and Windows.
- Linux is deferred, but platform abstractions must allow adding it later.
- MVP capture source: one entire screen (default) or one selected application window.
- Source selection is a custom in-app list: displays first, then windows.
- Cursor is recorded.
- Recording control overlay must never appear in the output.
- Microphone default: ON.
- Camera default: OFF.
- System audio default: ON.
- Camera is composited into the final video; it is not captured indirectly from a UI window.
- Camera PiP: lower-right, 0.16 x canvas width, the camera's own aspect ratio, 0.01 margin; preview mirrored, output not.
- The camera frame is never cropped and never distorted, in the file or in the preview.
- The control strip docks to the display's usable area, never over the menu bar or the notch.
- The control strip presents one size in every session state, and control hit targets fill the gaps between them.
- Destination selection and connection both live in Settings; Change opens Settings.
- Microphone + system audio are mixed into one output track.
- Quality: 720p / 1080p.
- FPS: 30 / 60, default 30. Architecture must allow 120 later.
- Output: MP4 / H.264 / AAC.
- Post-recording actions: Send / Delete / New recording (the last keeps the file and returns to the recorder).
- Upload destinations: Telegram and WebDAV, behind a replaceable common interface.
- Neither destination may require a developer account, an API console or a payment method.
- Telegram's hosted 50 MB cap is lifted by a user-run Local Bot API Server, not by another provider.
- Every destination is connectable from inside the app; `.env` only pre-seeds a build.
- Destination credentials live in OS-backed secure storage and are verified before they are stored.
- Failed/cancelled upload preserves the local recording.
- Local recording is deleted only after explicit Delete or confirmed upload success.
- Delete is confirmed by dialog only when the recording was never uploaded.

## Mandatory design rules

- The design system and reusable components are mandatory. Reuse an existing component
  before creating an equivalent.
- Repeated colors, typography, spacing, radii, shadows, iconography and motion values
  belong in typed shared tokens/theme — never as literals in feature widgets.
- Shared visual components must not own feature business logic.
- Check UI against the connected design. Where the design has no state for something,
  surface the gap; do not invent polished UX for it.

## Mandatory architecture rules

Rules marked **[gate]** are enforced by `test/architecture_test.dart` on every
`flutter test`. Breaking one is a failing test, not a review comment.

- Flutter owns UI, application state/orchestration and domain-facing abstractions.
- High-throughput raw audio/video stays native; do not stream raw media through Flutter platform channels.
- **[gate]** No `Platform.isMacOS` / `Platform.isWindows` / `Platform.operatingSystem` anywhere in `lib/` — including the composition root. Platform selection is plugin registration (`RecorderPlatform.instance`), which needs no OS check.
- Use capability-driven APIs instead of OS-name conditionals.
- **[gate]** No plugin package is imported outside `lib/app/composition_root.dart`.
- **[gate]** `dart:io` is reachable only from the six files named in the test's allowlist.
- **[gate]** `lib/design_system/` never references `features/`.
- **[gate]** No Flutter widget imports in any `/domain/` file.
- **[gate]** Every collaborator an `/application/` class holds is an interface, not a concrete type.
- Capture, finalization and upload are separate failure domains.
- Media queues must be bounded; no unbounded frame/audio accumulation.
- Use monotonic timestamps for A/V synchronization.
- Lifecycle/destructive operations must be race-safe and idempotent or explicitly guarded.
- Secrets never go into source control or logs.

Extending a gate's allowlist is fine; it must be by name, with a stated reason.

## Tests are mandatory

A behavioral change is not complete until relevant automated tests are added/updated and
all applicable validation passes.

```bash
./tool/validate.sh
```

That is `dart format` + `flutter analyze` + every workspace package's Dart/Flutter suite.
Root `flutter test` alone covers the application package only. Five of the six packages
have their own suite, run separately here and as separate CI steps (`recorder_macos` has
no Dart tests — its real suite is Swift).

It does **not** cover four things:

| Not run by `validate.sh` | Run it with |
|---|---|
| macOS native suite (~70 Swift tests) | `swift test` in `packages/recorder_macos/macos/recorder_macos/core` |
| Windows native suite | `cmake -S packages/recorder_windows/windows/test -B build/win-tests && cmake --build build/win-tests && ctest --test-dir build/win-tests` |
| real capture against this host | `flutter test integration_test -d macos --run-skipped` |
| design-review renders | `flutter test test/tools/render_screens_test.dart --run-skipped` |

**The last two are tagged skip-by-default in `dart_test.yaml`.** Without `--run-skipped`
they report green having executed nothing. A green run is not evidence they passed.

CI additionally enforces a line-coverage floor from `coverage/lcov.info` (`ci.yml`). It is
a ratchet: raise it when it rises, never lower it to make a branch green. The root
`--coverage` run reads 0% for files covered only by their own package suite — check the
package's own suite before concluding something is untested.

Critical-path changes need regression/integration coverage where practical: recording
state; file finalization/deletion/recovery; overlay exclusion; Pause/Resume; A/V sync;
upload success/retry/resume; credential handling; resource cleanup.

Never disable or weaken a test to make CI green. If a validation cannot run, report:

```text
NOT RUN: <test/build>
Reason: <concrete environment limitation>
```

A test that was not run is not considered passed. Standing gaps belong in
`docs/development/compatibility-matrix.md` rather than in a fresh ad-hoc note.

## Destructive commands

`tool/reset-permissions.sh` runs `tccutil reset`, irreversibly deleting this machine's
screen-recording, microphone and camera grants. It is right **only for an ad-hoc signed
build**: an identity-signed one keeps its grant across rebuilds, so running it there
destroys a working grant for nothing. Diagnose the launch method first —
`docs/development/macos-tcc-and-launchservices.md`.

## Definition of Done

Do not say `done`, `fixed`, `ready`, or `complete` unless all applicable items are true:

- implementation matches the specification as amended by accepted ADRs;
- UI work was checked against the connected design;
- design system/reusable components were used correctly;
- new behavior has tests;
- formatting/static analysis pass;
- relevant unit/widget/plugin/integration tests pass, including the native and
  `--run-skipped` suites when the change touches them;
- affected platform target builds where the environment supports it;
- no secrets were introduced;
- file deletion/recovery semantics remain safe;
- the files you changed are listed by path and contain no unrelated changes;
- docs/ADR are updated when behavior or architecture changed.

## Change discipline

Keep changes focused. Prefer the simplest architecture that preserves known extension
points; avoid speculative abstractions.

Do not introduce FFmpeg/shared media cores, a backend, a new auth trust model, a new
container/codec, or another expensive-to-reverse decision without an ADR.

Before finalizing, re-read what you changed and report exactly what was tested.
