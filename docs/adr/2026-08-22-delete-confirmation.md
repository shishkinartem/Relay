# Delete confirmation only for never-uploaded recordings

**Status:** Accepted
**Date:** 2026-08-22

## Context

`TECHNICAL_SPEC.md` §13 left it open (§30.5) whether the post-recording Delete
action requires confirmation. §18 already establishes that a local file may be
deleted only on explicit user Delete or on confirmed upload success, so the
question is purely about the user-facing gate on the explicit path.

Design `1l` proposes a confirmation dialog carrying duration and size, with Keep
and Delete actions.

## Decision

Delete shows a confirmation dialog **only when the recording has never been
uploaded**.

- The dialog states duration and size, and that the action cannot be undone.
- Actions: Keep (secondary), Delete (primary).
- Automatic post-upload cleanup (§18) stays silent and shows no dialog.

## Alternatives considered

- **Always confirm, including post-upload cleanup.** Rejected: the file is already
  safe at the destination, so the prompt guards nothing and interrupts every
  successful send.
- **Never confirm.** Rejected: Delete destroys the only copy of unrecoverable
  content, and the design deliberately places Delete adjacent to Send.
- **Undo window instead of a dialog.** Rejected for MVP: retaining the file for an
  undo period contradicts the "deleted means deleted" lifecycle in §18 and adds a
  second deletion trigger to reason about.

## Consequences

The dialog appears at most once per recording, on the irreversible path only.

Design `1i` already treats Delete as an icon button rather than a peer of Send, so
the confirmation is the second of two deliberate guards, not the only one.

Deletion remains idempotent and race-safe per `docs/architecture/recording.md`:
the dialog is a UI gate, not the guard against double-invocation.
