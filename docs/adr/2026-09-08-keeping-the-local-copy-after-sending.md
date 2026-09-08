# Keeping the local copy after a confirmed send

**Status:** Accepted
**Date:** 2026-09-08
**Amends:** `TECHNICAL_SPEC.md` §2, §13, §24, §29, §31.
**Does not reopen:** `docs/adr/2026-08-22-delete-confirmation.md`, whose rule is
unchanged — and reached for the first time.

## Context

The post-recording screen offered Send, a delete icon, and a ghost link in the
title bar labelled `New recording`. Two problems, reported together.

**Keeping the file without sending had no affordance.** It happened, but only as
the side effect of a control named after something else. A user who wanted to
keep the recording and get on with the next one had to guess that `New
recording` did not discard this one. The only reassurance was a centred caption
— *"New recording keeps this one in /Users/…/Movies/Relay"* — which explains a
button by describing what it does not do.

**Keeping the file *while* sending was impossible.** A confirmed upload deleted
the local copy unconditionally, and the only place the running application ever
said so in advance was one row of a fact table on the uploading screen reading
`On success — delete local file`. There was no control anywhere, in the Ready
screen or in Settings, that could change it.

Where the file lived was also never stated on the screen holding the file. The
folder appeared only inside the caption above, and the full path appeared
nowhere.

## Decision

**1. `Keep without sending` is a full-width peer of Send, in the panel footer.**
The ghost `New recording` link is gone. Its behaviour is unchanged — commit the
name, release the session, return to the recorder — but it is now named for the
user's intent rather than for its side effect, and it sits where a committing
action belongs. `AppPanel.footer` exists for exactly this: *"a screen whose list
can outgrow the panel keeps its committing action here, so that action is never
something the user has to scroll to find."*

**2. An `On this computer` row names the folder, with `Open folder`.** The full
path is on the tooltip; the folder is the mono value and the editable file name
is directly above it, so the two together are the whole location with nothing
elided in the middle. Opening goes through a new `FolderOpener` interface
(`lib/core/platform/folder_opener.dart`), implemented over `url_launcher`.

It opens the containing folder; it cannot select the file. Revealing with a
selection needs `NSWorkspace.activateFileViewerSelecting` and
`SHOpenFolderAndSelectItems` — a new `relay/recorder` method on both platforms
and a contract row. Not built, which is why the button says `Open folder` and
does not promise a reveal it cannot perform.

**3. `Keep a copy on this computer` — a persisted On/Off, default Off.** On the
Ready screen because that is where the question is live, and mirrored in
Settings under the recordings folder because that is where things outliving a
session belong. Both surfaces use the same label and the same control, so they
cannot drift. The Ready screen's caption says *"Remembered for every
recording."*: a control on a per-file screen that silently rewrites a global
default is a trap.

**4. The answer is captured when Send is pressed, never re-read.** It travels on
`UploadRequested` and lives on `SessionUploading`, so a switch flipped while
bytes are in flight cannot retroactively decide the fate of a file already on
its way. The uploading screen's fact row reads that captured value, so it
describes the decision that was actually made.

**5. Default Off.** The user asked for keeping to be *possible* and *obvious*,
not automatic. Off keeps §24's release criterion true on a default install, and
— with the local recording library deferred by name in §2 — avoids committing
every user to unbounded disk growth with no in-app way to see or prune it.

## What §18 says, and what this does not change

**§18's deletion rules are not weakened.** A local file is still deleted only
when (1) the user explicitly chooses Delete, or (2) the destination confirms
success. This adds **no third trigger**; it *narrows* case 2 by a user choice.
`DeletionReason` stays a two-value enum, `RecordingStore` keeps its refusal of
an unqualified delete, and `_performDeletion` stays the single funnel. **§18
permits the post-upload deletion; it has never required it.**

Spec text that did require it, now amended:

| Site | Was | Is |
|---|---|---|
| §2 Included | `local file deletion after successful upload` | `…, unless the user chose to keep a copy` |
| §13 Send diagram | `Remote success confirmed → Delete local file` | `→ Delete local file, unless the user chose to keep a copy` |
| §13 actions | `New recording` | `Keep without sending`; behaviour identical |
| §24 Must verify | `local file deleted after confirmed successful upload` | same, **with the preference off (the default)**, plus a new criterion for it on |
| §29 flow | `success → delete local file` | `success → delete local file, unless kept` |
| §31 | `Send / Delete / New recording`; `only after confirmed success` | `Send / Delete / Keep without sending`; `…, and only when the user has not chosen to keep a local copy` |

## Consequences

**`SessionReady.everUploaded` becomes reachable for the first time.** It has
existed since the delete-confirmation ADR, but no path ever set it: a confirmed
success went straight to `deleting`. The keep path returns to `ready` with it
true, which stands the confirmation dialog down — correctly, because the local
file is no longer the only copy, so removing it is not the irreversible act the
dialog guards against. The 2026-08-22 rule is implemented here, not amended.

**Two latent propagation bugs surfaced and were fixed.** Once `everUploaded` can
be true on an uploading session, the cancelled leg's hard-coded
`everUploaded: false` and the failed leg's omission both become wrong: cancelling
or failing a *second* send would claim the first never happened and re-arm a
confirmation that calls the deletion irreversible. Both now carry the value
through.

**`UploadBegan` rebuilds `SessionUploading` from scratch** rather than copying
it, so anything the transfer must remember has to be restated in that leg.
Forwarding `keepLocalCopy` only on the request would have reset it the instant
the transfer started and deleted a file the user asked to keep. There is a test
that drives the whole path — request, begin, succeed — precisely because a test
that skipped `UploadBegan` would pass while the feature was broken.

**Two screen states.** With `everUploaded`, the tag reads `Sent`, Send becomes a
secondary `Send again`, `Keep without sending` becomes a primary `Done`, and the
delete icon deletes without a dialog.

**Disk growth is now possible without limit**, and there is no in-app library to
prune it — §2 defers that by name. The default being Off is what keeps this
opt-in.

**No method-channel change.** Nothing crosses `relay/recorder`, so both plugins
and the contract document are untouched and the change-both-or-neither rule does
not engage.

**Settings schema 4 → 5**, with a no-op `_V4ToV5` step. The key is new and reads
as `false`, which is what every existing document already meant — but the
migrator treats a gap in the walk as a typed failure, so the step must exist or
a v4 document would lose *every* setting.

## Alternatives considered

**Keep by default.** Rejected. It reverses §24 rather than qualifying it, and
commits every user to unbounded growth with no library UI. The user asked for
keeping to be possible and obvious; the obviousness is bought by the control
being on the Ready screen above Send, not by its default.

**A per-send override rather than a preference.** Rejected: the choice would be
re-made on every recording, and the answer is almost always a standing habit.

**Three peer buttons in one row.** Rejected — design `1i` argues Delete is
deliberately not a peer of Send, and that reasoning survives. The new peer is
the keep action; Delete stays a 44-point icon.

**A new `SessionSent` state.** Rejected: `SessionReady(everUploaded: true)`
already means exactly that, and a fourth post-recording state would duplicate
every transition out of `ready`.

**An undo window after deletion.** Already rejected in
`docs/adr/2026-08-22-delete-confirmation.md`; not reopened.

## Verification

- `./tool/validate.sh` — format, analyze, and every Dart/Flutter suite.
- Machine coverage for both successors of a confirmed success, the flag
  surviving `UploadBegan`, and both `everUploaded` propagation fixes.
- Widget coverage driving a real session to `ready` with a real file, then
  asserting the file survives a confirmed send with the switch on and is deleted
  with it off.
- **NOT RUN:** `flutter test test/tools/render_screens_test.dart --run-skipped`
  against the amended Ready screen — the design-review renders were not
  regenerated, and `1i` has no drawn state for the footer, the location row or
  the keep switch. Recorded in `design/README.md`.
