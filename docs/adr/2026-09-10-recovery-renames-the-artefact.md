# A recovered artefact is renamed, not copied

**Status:** Accepted
**Date:** 2026-09-10
**Decides:** `TECHNICAL_SPEC.md` §18's *"Do not silently delete potentially
recoverable data"* for the recovery path, and makes §19.1's `.part` row true on
Windows.
**Downstream of:** `docs/adr/2026-08-23-fragmented-mp4-on-both-platforms.md`,
which is what makes an aborted Windows `.part` readable at all. Not reopened.

## Context

§18 gives the artefact one lifecycle — written incrementally as
`recording-<id>.part`, renamed by a successful finalize — and §19.1 restates it
as a release requirement: the `.part` is *"renamed by a successful finalize;
**kept** by every other exit"*. Startup recovery is that finalize, arriving a
process late.

Windows did not do it. `RecordingSession::RecoverArtifact` copied:

```cpp
// Copy, never move: recovery must not consume the artefact it read (spec 18).
if (::CopyFileW(artifact_path.c_str(), recovered.c_str(), FALSE) == FALSE &&
    ::GetLastError() != ERROR_FILE_EXISTS) {
```

That comment is the decision being overturned here, and it is not obviously
wrong. §18 forbids silently deleting potentially recoverable data, and a rename
destroys the name the recovery screen found the file under; read that way,
copying is the careful answer and moving is the reckless one. Read the other way
— the way §19.1 writes it out — a successful recovery is exactly the event that
is *supposed* to consume the `.part`, because nothing was lost: the data is
under its final name, in the folder, offered to the user. Both readings are
defensible from the text and they produce opposite file semantics, which is what
makes this a decision rather than a patch. `docs/adr/README.md` lists *changing
local-file finalization/recovery semantics* among the things that require one.

Copying costs three things.

**The recovery offer never goes away.** `PlatformArtifactRecovery.finalize`
rescans the moment the platform answers, and its own comment says why it may:
*"a successful finalize removes the `.part`"*. It did not, so the scan finds the
same artefact again, the recovery card returns for a recording that was just
recovered, and the only ways out are Discard file — deleting an artefact whose
contents are now duplicated, which reads as data loss to the person pressing it
— or Keep as is, once per launch, forever (design `1n`).

**Every recovered recording costs twice its bytes**, on a platform with no
in-app library to notice the surplus in; §2 defers that library by name.

**And the guard against overwriting a finished recording did not exist.**
`CopyFileW`'s third argument is `bFailIfExists`, and it was `FALSE`: the copy
overwrites. `ERROR_FILE_EXISTS`, which that call can only return when the flag
is `TRUE`, is unreachable — so the code written to obey §18 held the recorder's
only path that could destroy a completed `.mp4` without asking, replacing it
with a partial one. It needs a colliding recording id, so it is unlikely; it is
total when it happens.

macOS never had the question. `recover(path:)` in `RecorderMacosPlugin.swift`
refuses an occupied target, moves the artefact onto its final name, probes it
there, and moves it back untouched when nothing readable is in it. Both hosts
answer the same `recoverArtifact` call with a recording-file map or `null`, so
**Dart could not see that the two platforms disagreed about what recovery does
to the file** — the same blindness the fragmented-MP4 ADR was written about, on
the same method.

## Decision

**1. A successful recovery renames the artefact, exactly as an ordinary
finalize does.** `MoveFileExW`, which is the call `MediaWriter::Finalize`
already makes on the normal path. §18 asks for *"an atomic or crash-safe
finalization strategy where platform/filesystem semantics allow it"*, and a
rename within one directory is that; a copy is a second full-size window in
which a crash leaves two files where §18 describes one.

**2. Renaming is not deleting**, and that is the sentence this ADR exists to
fix in place. §18's prohibition is on losing data that could have been
recovered; a recovery that succeeded has recovered it. Nothing on this path
deletes anything, and `discardArtifact` — the recovery screen's Discard file, an
explicit press — stays the only code in the recorder that removes a `.part`.

**3. Flags `0`: no `MOVEFILE_REPLACE_EXISTING`.** An `.mp4` already at the final
name is a finished recording this artefact has no business standing on. The move
refuses, atomically, rather than asking `PathFileExistsW` first and racing
whatever answers between the question and the move. macOS reaches the same
refusal by checking `fileExists` before it touches anything, and
`FileManager.moveItem` would throw regardless.

This is deliberately not what the live path does — `MediaWriter::Finalize`
passes `MOVEFILE_REPLACE_EXISTING` — because recovery is the one finalize that
lands on a name minted by a process that is gone, which is precisely when the
name can already have been taken. Whether the live path wants the same treatment
is a different question about a different id, and it is not reopened here.

**4. The probe runs under the final name, and a failed probe moves the artefact
back.** Media Foundation resolves a byte-stream handler from the file's
extension, so `MFCreateSourceReaderFromURL` against something called `.part` is
not being asked the question we mean to ask — the old order probed first and
therefore probed the wrong name. macOS orders it the same way for the same
reason, *"AVFoundation identifies the container by extension"*, and moves back
on both the unreadable result and the throw.

**5. Every failing exit leaves the artefact where it was, under its own name.**
An occupied target, an unreadable file, a probe that throws: all three return
`false` with `recording-<id>.part` still on disk, still found by the next scan,
still offered. That is §18's *kept by every other exit*, and it is what lets a
failed repair be retried instead of mourned.

## Alternatives considered

**Copy, then delete the `.part`.** Rejected. It reaches the same end state
through a recorder that deletes a recording for a reason that is not one of
§18's two — the user chose Delete, or the destination confirmed success — and it
writes every recovered file twice to get there. A crash between the copy and the
delete leaves both files anyway.

**Copy, and remember which artefacts have already been recovered.** Rejected: a
sidecar file or a recovered-ids list is state about a file that is not in the
file, in a folder the user can rearrange from Explorer, and it duplicates what
the extension already says. The doubled disk cost survives it.

**`MOVEFILE_REPLACE_EXISTING`, so that recovery always succeeds.** Rejected. It
converts an unlikely id collision into a certain and total loss of a recording
that was already safe. Refusing costs the user a repair they can retry after
moving whatever is in the way; replacing costs them the finished recording,
silently.

**Probe the `.part` in place and rename afterwards, as the old code did.**
Rejected: it asks Media Foundation about a name it does not associate with an
MP4 byte-stream handler, so a perfectly readable artefact can answer as
unreadable — and it diverges from macOS to save exactly the one rename that
point 4 puts back on failure.

**Fixing it as a bug, with no ADR.** Rejected. The index requires one for
recovery semantics, and the comment being deleted cited §18 for the opposite
conclusion. A correction that leaves no reasoning behind is one the next reader
is entitled to revert.

## Consequences

**The recovery card stops returning.** The rescan behind
`PlatformArtifactRecovery.finalize` now finds nothing, because the artefact it
would have found became the recording, which is the assumption that function was
written on.

**§19.1's `.part` row becomes true on both platforms**, and the recovery
divergence between the two hosts closes: same order of operations, same refusal
on a taken name, same restoration on failure.

**A colliding final name now fails the recovery instead of destroying a
recording — and says the wrong thing about why.** `recoverArtifact` answers
`null` for every failure, so `finalize` logs `artifact_unrecoverable` and the
screen tells the user nothing readable was in the artefact, when in fact the
artefact is intact and its name is occupied. Recorded rather than fixed: a
reason code is a `relay/recorder` contract change on both platforms, for a case
that needs a duplicate recording id to arise at all, and macOS has always
reported it this way — so it is a shared imprecision, not a new divergence.

**A failed probe now performs a second move, and its result is not checked** —
as macOS's `try?` does not check its own. If the move back fails, the artefact
is left named `.mp4` and unreadable, and `findIncompleteArtifacts` selects
`.part` files, so the next scan would stop offering it. The exposure is a rename
being undone in the directory it has just succeeded in.

**Cross-volume moves cannot arise, which is what makes flags `0` safe.** Without
`MOVEFILE_COPY_ALLOWED`, `MoveFileExW` refuses to move between volumes — but the
target here is the source path with its extension replaced, so the two are in
the same directory by construction.

**No method-channel change.** `recoverArtifact` keeps its argument and both of
its answers, so `docs/architecture/platform-channel-contract.md` is untouched and
`packages/CLAUDE.md`'s change-both-or-neither rule does not engage. What changed
is what one host does behind a call whose shape the two already agreed on.

**Nothing here can be unit-tested in the suite that runs.**
`packages/recorder_windows/windows/test` compiles `recorder_types.cpp` and
`audio_mixer.cpp` because those are the translation units with no Media
Foundation in them. `RecoverArtifact` calls `MediaWriter::Probe`, which is Media
Foundation, so it cannot join them without dragging the Windows SDK into the
pure half. It is covered by no executing test, before or after this change.

**And it has never run.**

```text
NOT RUN: Windows artefact recovery, in either form
Reason: no MSVC toolchain, no Windows SDK and no cmake on this machine (macOS),
and neither Windows run reached the path. `recoverArtifact` appears in no log:
the 2026-09-08 run left a `.part` behind and the 2026-09-09 run discarded it
(`artifact_discarded recordingId=ff0a3497`) rather than repairing it. So the
copy this replaces was never observed either — the doubled file, the returning
card and the overwrite are all read off the source, not measured.
```

Take it on the next run, as two checks rather than one: kill Relay
mid-recording, relaunch, press `Try to repair`, and confirm the `.part` is gone,
the `.mp4` plays and the recovery screen does not come back; then put an `.mp4`
of that name in the folder first and confirm the repair fails with the artefact
still on disk. `docs/development/compatibility-matrix.md` carries the same gap.
