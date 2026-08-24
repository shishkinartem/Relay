# A screen-recording answer is pending until the app reopens, and Relay reopens itself

**Status:** Accepted
**Date:** 2026-08-24

## Context

macOS has no `notDetermined` for screen recording.
`CGPreflightScreenCaptureAccess()` answers one bool, and
`CGRequestScreenCaptureAccess()` cannot return true in the process that asked:
the grant is recorded against the launched binary and only a fresh process sees
it. Three different situations therefore collapse into one `false`:

- nobody has ever asked — the system prompt is the remedy, and the privacy pane
  is not, because macOS does not list an application under a privacy category
  until it has asked;
- this process just asked — nothing is wrong, the application has to reopen;
- an earlier process asked and the user refused — only the privacy pane can
  change it.

Relay carried a `UserDefaults` flag, `relay.permissions.askedScreenRecording`,
to separate the first from the other two, and mapped everything else onto
`denied`. The flag was written *before* `CGRequestScreenCaptureAccess()` ran, so
pressing **Allow screen recording…** relabelled the permission **Not granted**
while the system's own window was still on screen — the application telling the
user they had refused something they were in the middle of allowing. The only
instruction that could unblock the screen was an 11px monospace footnote saying
to relaunch, and nothing in the application could relaunch.

Two further states had no name at all. A permission check that timed out
emptied the report, every kind read back `notDetermined`, and a first-run screen
was shown for a platform that could not be reached. And a process started
outside Launch Services — `run-relay.sh`, `flutter run` — is attributed by TCC
to whatever started it, so the permission reads as missing however many times
the user grants it.

## Decision

**`pendingRelaunch` is a permission status, and the application can reopen
itself.**

- `PermissionStatus.pendingRelaunch` joins the enum. It is not `isUsable`, so
  it blocks exactly like a refusal — but it is a different word to the user:
  *Restart to apply*, not *Not granted*.
- macOS resolves the status through one pure function,
  `ScreenRecordingPermissionState.resolve(preflightGranted:askedThisRun:askedEver:)`,
  in the Flutter-free `RecorderCore` package where `swift test` can reach it.
  Asking in this process wins over the remembered flag.
- The remembered flag is written **after** the request actually runs, and also
  when `SCShareableContent` reports `SCStreamError.userDeclined` — the
  enumeration raises the same system prompt, and until now nothing recorded
  that it had.
- `RecorderPermissions` gains `relaunchApplication()` and `quitApplication()`.
  macOS reopens through `NSWorkspace.openApplication` with
  `createsNewApplicationInstance`, and terminates **only** once the replacement
  is on its way; a failed reopen leaves the user with a running application.
- Two capabilities carry the platform's shape to the UI without naming an
  operating system: `screenRecordingNeedsRelaunch` and
  `screenRecordingLaunchedByThisApp` (macOS: `getppid() == 1`, since a GUI
  application started through Launch Services is reparented to launchd).
  Windows reports `false` / `true`, and its screen-recording status is
  `notApplicable`, so none of this is reachable there.
- `SessionPermissions.lastCheckFailed` distinguishes "the platform could not be
  asked" from "the user has not been asked", and permission reads are
  serialized so an answer read before a prompt cannot overwrite one read after
  it.
- The blocking preflight resolves one of seven states and offers only actions
  that can change that state — including, for a refusal, a way back to the
  system prompt, because the remembered flag can be wrong in both directions
  (resetting the privacy database clears the system's answer, not Relay's
  memory of asking).

## Consequences

- The screen no longer accuses the user of refusing something they allowed, and
  the one action that unblocks it is a button rather than a footnote.
- A fifth status widens `PermissionStatus`. Nothing switches exhaustively over
  it, and `fromName` already falls back, so unknown values from an older
  platform build stay safe.
- Relay can terminate itself. It does so only from the preflight, where no
  session exists — overlay engines are created at `showControlStrip`, so there
  is nothing to tear down — and it goes through `NSApp.terminate`, which runs
  the application's own `AppLifecycleListener(onExitRequested:)`.
- `SCShareableContent` failures are no longer all reported as
  `permissionDenied`. Only `SCStreamError.userDeclined` (-3801) is; everything
  else becomes `sourceUnavailable`, so a transient ScreenCaptureKit fault stops
  producing a screen that blames the user.
- Design `1d` draws only the degraded variant, so the blocking states are a
  surfaced design gap (`docs/development/design-system.md` → *Missing states*),
  built from existing components so a designed replacement is a swap.
- `run-relay.sh` remains a valid way to run the app, but it will now say so:
  a shell-launched build reports *Given to another app* and offers to reopen
  itself properly instead of sending the user to a privacy pane where Relay may
  already be switched on.

## Alternatives considered

**Keep mapping everything onto `denied`.** Cheapest, and the source of the
report that started this work: the screen contradicts what the user just did.

**Drop the `UserDefaults` flag and always offer the prompt.** macOS silently
does nothing for a second request, so a refused user would press a button that
never responds.

**A first-run wizard with one permission per screen.** Rejected as
disproportionate: on macOS this is one blocking permission and on Windows it is
none, and it would add a second screen family and navigation model to an
application that is one panel plus one state machine (§19).
