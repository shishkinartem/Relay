# Connected design

This directory is a synchronized copy of the Claude Design project
**"Desktop app design questions"**
(`b4f298e7-4a61-40bf-aa1f-b3fc43c0a5df`), pulled 2026-08-22.

The canvas document is the visual source of truth for the application, per
`../CLAUDE.md`. `../TECHNICAL_SPEC.md` remains the product/technical source of
truth.

## Contents

```text
Screen Recorder - Desktop MVP.dc.html   # the canvas document — source of truth
preview.html                            # GENERATED static render, viewable offline
support.js                              # canvas runtime (loads React from a CDN)
scripts/render_design_preview.py        # regenerates preview.html
_ds/industry-fc0cac85-.../
├── styles.css                          # Industry design system: tokens + components
├── readme.md                           # how the system is meant to be used
├── _ds_manifest.json                   # machine-readable token registry (48 tokens)
├── _ds_bundle.js                        # component bundle (empty — CSS-only system)
└── _adherence.oxlintrc.json            # lint rules enforcing token use
```

## Viewing it

The `.dc.html` will not render if you open it directly: `support.js` boots it with
React fetched from `unpkg.com`, so it is blank without network access and outside
the design host.

Open `preview.html` instead — it contains the same markup rendered against the
local design system:

```bash
open design/preview.html
```

Or view the canvas in Claude Design, where the `uploadPercent` control on screen
`1j` is interactive. `preview.html` renders it at its default of 62%.

## Refreshing after a design change

Re-pull the files through the `claude_design` MCP connection (or `DesignSync`),
overwrite this directory, then regenerate the static render:

```bash
python3 design/scripts/render_design_preview.py
```

Do not hand-edit anything here except `README.md` and `scripts/`. Everything else
is a copy of the remote project, and `preview.html` is generated.

## Sync is one-way: design → repository

The design project carries design only. Do not push engineering documents into it.

In particular `TECHNICAL_SPEC.md` is **not** mirrored to the design project. The
copy in the repository root is the only one; a second copy living beside the
canvas would silently go stale and create a competing source of truth, which is
exactly what the hierarchy in `../CLAUDE.md` exists to prevent.

An uploaded `uploads/TECHNICAL_SPEC.md` (a v0.3 copy) was removed from the design
project on 2026-08-22 for this reason. Do not re-upload it.

Design decisions travel the other way: when a design screen resolves an open
product decision, record it in `../TECHNICAL_SPEC.md` and an ADR under
`../docs/adr/`, as was done on 2026-08-22 for `1a`, `1h` and `1l`.

## Screen index

| ID | Screen | Spec section |
|---|---|---|
| `1a` | Source picker — displays first, then windows | §4.1 |
| `1c` | Launch screen — per-session configuration | §10, §29 |
| `1d` | Permission preflight | §23 |
| `1e` | In situ — window source, strip docked | §6 |
| `1p` | In situ — display source (default), both overlays excluded | §6 |
| `1f` | Control strip — recording | §6 |
| `1g` | Control strip — paused | §9 |
| `1h` | Camera PiP composition spec | §7 |
| `1i` | Ready — Send or Delete | §13 |
| `1o` | Change destination | §14, §15 |
| `1j` | Uploading | §14 |
| `1k` | Upload failed | §14 |
| `1l` | Delete confirmation | §13 |
| `1m` | Settings — destination and storage | §15 |
| `1n` | Startup recovery | §18 |

## Design decisions adopted into the spec

Three screens proposed resolutions to open spec decisions. All three were accepted
on 2026-08-22 and are recorded in `../docs/adr/`:

- `1a` → source-selection UX (was §30.1), together with the entire-screen scope change
- `1h` → camera PiP geometry and mirroring (was §30.2)
- `1l` → Delete confirmation (was §30.5)

## Known design gaps

The design does not cover these states, which the spec requires. Do not invent
polished UX for them — see the "Missing states" rule in
`../docs/development/design-system.md`:

- `preparing`, `stopping`, `finalizing`
- `sourceUnavailable`, `sourceClosed` (§4.5)
- `diskFull`, `encodingFailed`, `finalizationFailed`
- blocking `permissionDenied` (the variant where a user-enabled source is denied;
  `1d` shows only the non-blocking case)
- WebDAV connection setup — address, user, app password, optional folder (§17)
- Telegram credential configuration (§16)
- a muted state for the system-audio glyph — `1f` and `1g` only ever draw it on.
  The implementation reuses the system's own slash treatment from mic-off and
  camera-off (`AppIcons.systemAudioOff`, marked `design gap:` in the source).

`1d`'s annotation also no longer matches the implemented behaviour. It describes
a blocking screen for any explicitly enabled source whose permission is refused;
only screen recording blocks now, on the product owner's instruction. See
`../docs/adr/2026-08-23-optional-inputs-degrade-instead-of-blocking.md`. The
screen's layout still follows `1d`.

The design draws macOS traffic lights in each screen's title bar because the
canvas has no real window chrome. The application has: its system title bar is
transparent and the header sits underneath it, so the buttons on screen are the
real ones rather than a second, painted set.
