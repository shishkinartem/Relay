# A denied microphone or camera degrades the session instead of blocking it

**Status:** Accepted
**Date:** 2026-08-23

## Context

`TECHNICAL_SPEC.md` §23 says permission denial is a typed state, that an
optional input which is switched off never blocks Start, and that "if a user
explicitly enables a source and required permission is unavailable, surface a
clear error". Design `1d`'s annotation reads that last clause as a hard gate:
"a source the user explicitly enabled turns this into a blocking
`permissionDenied` screen with the primary button disabled".

Implemented literally, that produced the following: a user who has microphone
ON — the default — and has never granted microphone access cannot record their
screen at all. The Start button is disabled and the only way forward is a trip
to System Settings for an input they may not care about. The product owner hit
this on first run and rejected it: "Microphone and Camera shouldn't block the
recording flow."

## Decision

**Screen recording is the only blocking permission.**

- Screen recording refused → recording is impossible, because there is no video
  track to produce. The preflight becomes a single-purpose screen whose primary
  action is *Open System Settings*, with *Check again* beside it. There is no
  disabled Start button pretending the session could begin, and no Back button
  to a screen the user cannot use.
- Microphone or camera refused **while the user had it switched on** → the
  input is dropped for this session, the preflight names it ("Microphone will
  stay off"), and Start proceeds. The stored preference is left untouched, so
  the input returns by itself once the permission is granted.
- Microphone or camera refused **while switched off** → nothing to report, and
  the preflight is skipped entirely.

The dropped input is reported through the same typed path a mid-session loss
uses — `RecorderErrorCode.microphoneUnavailable` /
`cameraUnavailable` as a non-fatal event — so the control strip shows it as
unavailable rather than merely off, and one code path covers both "denied at
start" and "unplugged while recording".

## Alternatives considered

- **Block, as design `1d` annotates.** Rejected by the product owner. It makes
  the default configuration (microphone ON) unable to record on a fresh
  install, which is the first thing every new user meets.
- **Silently turn the input off.** Rejected: §23 forbids starting a partially
  configured recording silently. The preflight states what will be missing;
  it just does not refuse.
- **Prompt for the permission at Start and wait.** Rejected: macOS cannot
  re-prompt once a permission is denied, so this would deadlock exactly the
  users who need the escape hatch.

## Consequences

`PermissionReport.blockingDenials()` no longer takes the requested inputs into
account — it reports screen recording and nothing else — and a sibling
`degradedInputs({microphoneRequested, cameraRequested})` carries the rest.
`SessionPreflight` gained `degradedInputs`, and the preflight screen has two
shapes rather than one.

This is a deliberate departure from the annotation on design `1d`. The design
remains the visual source of truth for that screen's layout; only the gating
rule changed, on the product owner's explicit instruction, which
`CLAUDE.md` ranks above both the specification and the design.

§23's "surface a clear error" is still honoured: the missing input is named on
the preflight and marked unavailable on the control strip for the whole
session. What changed is that it is no longer fatal to the session.
