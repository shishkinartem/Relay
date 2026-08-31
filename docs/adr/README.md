# Architecture Decision Records

Use ADRs for decisions that are expensive to reverse.

An **Accepted** ADR dated later than `TECHNICAL_SPEC.md` supersedes the spec on the point
it decides. Where the two disagree, the ADR is current and the spec is stale.

## Accepted decisions

| Decision | Status |
|---|---|
| [Entire-screen capture in MVP, and a custom in-app source picker](2026-08-22-capture-source-scope-and-selection-ux.md) | Accepted |
| [Camera PiP geometry and mirroring](2026-08-22-camera-pip-composition.md) | Superseded in part |
| [Delete confirmation only for never-uploaded recordings](2026-08-22-delete-confirmation.md) | Accepted |
| [The camera PiP takes the camera's own shape, and is smaller](2026-08-23-camera-pip-follows-source-aspect.md) | Accepted — supersedes the geometry table above |
| [Destinations are connected in the application, not in `.env`](2026-08-23-destination-credentials-in-app.md) | Accepted; the Google Drive parts superseded |
| [Both platforms write fragmented MP4](2026-08-23-fragmented-mp4-on-both-platforms.md) | Accepted |
| [A denied microphone or camera degrades the session instead of blocking it](2026-08-23-optional-inputs-degrade-instead-of-blocking.md) | Accepted |
| [Overlay windows are native panels hosting secondary Flutter engines](2026-08-23-overlay-windows-as-secondary-flutter-engines.md) | Accepted |
| [Telegram is the only upload destination](2026-08-23-telegram-only-destination.md) | Accepted — removed Google Drive |
| [WebDAV is the second destination](2026-08-23-webdav-second-destination.md) | Accepted — amends the above |
| [Overlay panels are sized once per show](2026-08-24-overlay-panels-are-sized-once-per-show.md) | Accepted — **headline rule superseded** by `2026-08-31-overlay-panels-never-shrink.md`; the rest still stands |
| [A screen-recording answer is pending until the app reopens, and Relay reopens itself](2026-08-24-screen-recording-permission-applies-on-relaunch.md) | Accepted |
| [Overlay panels never shrink](2026-08-31-overlay-panels-never-shrink.md) | Accepted — amends the 2026-08-24 sizing rule |

## Accepted 2026-08-30, shipped and folded

Accepted together after the design review. All four shipped, and all four were
folded into the numbered `TECHNICAL_SPEC.md` sections on 2026-08-31 — §2, §6,
§7, §8, §20, §29 and §31 are what to build against. §33 remains for the reasons
its §33.11 gives; it is no longer the live specification for this scope.

| Decision | Status |
|---|---|
| [Inputs are chosen from a device list, before and during a recording](2026-08-30-input-device-selection.md) | Accepted — shipped and folded into §8, §20 |
| [The control strip moves, and each input discloses its devices](2026-08-30-movable-control-strip-and-input-menus.md) | Accepted — shipped and folded into §6. `Reset position` and the nudge commands exist on the wire and have **no affordance at all** — no menu, no key binding, no button |
| [The camera picture-in-picture is dragged by hand and sized by preset](2026-08-30-user-adjustable-camera-pip.md) | Accepted — shipped and folded into §7, §2; amends a core product invariant |
| [The panel has a width range, and the layout answers to it](2026-08-30-responsive-panel.md) | Accepted — shipped and folded into §29 |

## Filename

```text
YYYY-MM-DD-short-decision-title.md
```

## Template

```md
# Decision title

**Status:** Proposed | Accepted | Superseded
**Date:** YYYY-MM-DD

## Context

Why a decision is needed.

## Decision

What is being chosen.

## Alternatives considered

What else was evaluated.

## Consequences

Benefits, costs, risks and constraints.
```

When an ADR supersedes or amends another, say so in both files: `**Supersedes:**` /
`**Superseded by:**`, naming the path.

## ADR-required examples

- Flutter/native bridge strategy;
- adding FFmpeg/Rust/C++ shared media core;
- changing file/container/codec strategy;
- changing local-file finalization/recovery semantics;
- introducing a backend;
- changing the destination credential trust model;
- introducing resumable upload (today no destination resumes);
- adding or removing an upload destination;
- Linux capture backend;
- 120 FPS implementation strategy.
