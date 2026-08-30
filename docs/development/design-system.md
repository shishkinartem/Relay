# Design System and Reusable Components

## Source of truth

Connected design:

`Screen Recorder - Desktop MVP.dc.html`

The connected design is the visual source of truth.

`TECHNICAL_SPEC.md` remains the product/technical source of truth.

If they conflict, do not silently choose; follow the source-of-truth hierarchy in `CLAUDE.md`.

### Where the design lives

A synchronized copy is vendored at `design/`:

| Path | What it is |
|---|---|
| `design/Screen Recorder - Desktop MVP.dc.html` | The canvas document — the source of truth |
| `design/preview.html` | Generated static render; the offline-viewable version |
| `design/scripts/render_design_preview.py` | Regenerates `preview.html` from the canvas |
| `design/_ds/industry-<id>/styles.css` | Industry design system — tokens and component classes |
| `design/_ds/industry-<id>/readme.md` | How the system is meant to be used |
| `design/_ds/industry-<id>/_ds_manifest.json` | Machine-readable token registry |

The canvas document cannot be opened directly in a browser: its runtime
(`support.js`) loads React from a CDN. Open `design/preview.html` instead, or view
the canvas in Claude Design. Do not hand-edit the vendored copy — re-pull it and
re-run the generator.

### Screens covered by the design

`1a` source picker · `1c` launch/config · `1d` permission preflight ·
`1e` in-situ window mode · `1p` in-situ display mode · `1f` control strip
recording · `1g` control strip paused · `1h` camera PiP spec ·
`1i` ready · `1o` change destination · `1j` uploading · `1k` upload failed ·
`1l` delete confirmation · `1m` settings · `1n` startup recovery.

### The vendored faces do not cover every glyph

Barlow, Barlow Condensed and IBM Plex Mono are vendored so both platforms render
identically (`pubspec.yaml`). They do not include `→` (U+2192): it renders as a
tofu box on screen while looking correct in the source and in this repository's
markdown. Use `>` for a menu path and `·` for a separator in any string that
reaches the UI. Arrows are fine in doc comments and in `.md` files, which are
not rendered with these fonts.

### Tokens are the input to the Flutter theme

`AppColors` / `AppTypography` / `AppSpacing` / `AppRadius` / `AppShadows` must be
derived from `styles.css`, not re-picked by eye. The system is a wireframe: square
corners (`border-radius: 0` on cards, buttons, inputs, tags, dialogs), transparent
hairline-bordered surfaces, corner registration marks on framed objects, one steel
accent `#5980a6`, Barlow Condensed over Barlow, Lucide icons at stroke-width 1.5.
The solid accent primary button is the single deliberate filled object.

Note the override at the end of `styles.css`: it resets radii to `0` and strips
card/dialog fills, so the `--radius-*` tokens apply only where the system still
uses them. Port the file's *effective* result, not the `:root` block alone.

## Mandatory design system

A project-level design system is required.

Centralize repeated visual values into typed shared tokens/theme, including as applicable:

```text
AppColors
AppTypography
AppSpacing
AppRadius
AppShadows
AppIconography
AppDurations / motion tokens
```

Use Flutter `ThemeData` / `ThemeExtension` or equivalent typed shared structures where appropriate.

Do not scatter repeated raw colors, spacings, radii or text styles through feature widgets.

## Reusable components are mandatory

Before creating a new component, search for an existing equivalent.

Common reusable candidates:

- buttons;
- icon buttons;
- toggles;
- segmented controls;
- dropdown/select controls;
- settings rows;
- cards/surfaces;
- status indicators;
- progress indicators;
- dialogs;
- tooltips;
- error/empty states;
- recording controls;
- upload destination controls;
- camera preview containers.

Do not copy a visually equivalent component into another feature because it is locally faster.

## Layering

```text
Design tokens
    ↓
Primitive shared components
    ↓
Composite shared components
    ↓
Feature-specific widgets
    ↓
Screens/windows
```

Shared visual components must not own recorder/upload business orchestration.

## Component API expectations

Reusable components should:

- consume shared tokens;
- expose explicit states/inputs;
- support enabled/disabled/loading/focus/hover states where relevant;
- support keyboard interaction/focus where applicable;
- render correctly on high-DPI/Retina displays;
- use semantic labels/tooltips where needed.

## Desktop requirements

UI must remain usable across supported desktop scaling/window conditions.

Check:

- resizing;
- clipping/overflow;
- hover/focus;
- text truncation/wrapping;
- usable hit areas;
- high-DPI scaling;
- overlay bounds;
- display scale-factor changes.

Minimum/default main-window dimensions remain product values and must be defined/tested before release.

## Recording overlay

Overlay must:

- be a separate top-level window;
- stay always-on-top while recording;
- remain within usable display bounds;
- follow the connected design;
- use the shared design system/components;
- never appear in captured output.

"Usable display bounds" is literal: `NSScreen.visibleFrame` on macOS,
`MONITORINFO.rcWork` on Windows. The menu-bar band is not usable — design `1f`
calls for a strip "small enough to dock without covering a menu bar", and on a
notched Mac that band contains the notch, where a control is neither drawn nor
clickable.

### Documented deviation: the paused strip does not grow

Design `1g` draws the paused strip wider than `1f`: it adds a `Paused` tag and
swaps the pause icon for a labelled `Resume` button. The implementation keeps
`1f`'s geometry in both states and renders paused in place — the frame takes the
accent (as `1g` draws it), the status dot goes hollow (as `1g` draws it), and
the pause square becomes an accent-filled play square.

The reason is mechanical, not aesthetic: the strip's host window is sized to
what the strip measures, so a strip that changed width on pause would resize
that always-on-top window during the very click that paused it, and slide every
control to the right of the cursor somewhere else.

Each control's hit target also claims half the 12 px gap on each side, so the
row of controls has no dead space in it and every control spans the strip's full
height. The drawn squares are unchanged.

### Components added for §33.2

| Component | What it is | Why it is shared |
|---|---|---|
| `AppDisclosure` | A row whose detail settings are put away until asked for. Its primary control — the input's On / Off — sits in `headerTrailing`, **outside** the tap target | The separation is the point: reaching for Off must never open a panel, and reaching for the details must never mute an input. A screen that rebuilt this would eventually get that wrong |
| `AppLevelMeter` | A ticked bar with a fill and a peak marker, plus a dashed *dead* state | Two values rather than one: the fill is the sustained level a user reads as "am I coming through", the hairline marker is the loudest instant, which is what says "too hot" before anything clips. Drawn dead rather than hidden, so "off" and "broken" do not look the same |
| `AppSelectField` | The closed state of a choice — what is chosen, and a chevron. A dashed border and no chevron when there is nothing to pick | "There is one of these" and "you may pick one" must not be the same picture |
| `AppOptionTile` | One row of an open choice, with a disabled state for a device the platform lists but cannot open | The control strip's action sheet reuses this shape when it arrives (§33.4) |

### Documented deviation: capture thumbnails are not duotoned

The Industry system washes photography in the accent — "every content
photograph goes through `.duotone`". Capture thumbnails do not, in the source
picker (`SourceCard`) or in the launch screen's selected-source row.

They are not content photographs. They exist so a user can tell one of fifteen
windows from another, and the accent wash removes exactly the information that
distinguishes them: a blue-washed screenshot of an editor and a blue-washed
screenshot of a browser read as the same object. `TECHNICAL_SPEC.md` §4.1 states
this as behaviour.

`DuotoneFilter` is unchanged and still correct everywhere else it is used — the
camera-preview placeholder and the ready screen's figure, both of which are
decorative rather than identifying.

## Missing states

The technical model may contain states not yet designed.

Examples:

- preparing;
- finalizing;
- upload failed;
- **the blocking permission screen**. Design `1d` draws one preflight — camera
  denied, camera off, Start still available — and its annotation is the only
  statement about the blocking case: "a blocking `permissionDenied` screen with
  the primary button disabled". A disabled primary on a screen with no other
  exit is a dead end, so what is implemented instead is one screen resolving
  seven states, each offering only actions that can change it: never asked,
  answered and awaiting a relaunch, refused, blocked by policy, the check
  itself failing, a launch the OS attributes to another application, and no
  platform implementation at all (ADR
  `docs/adr/2026-08-24-screen-recording-permission-applies-on-relaunch.md`). None of the
  seven is drawn on the canvas. All are built from `AppPanel` (with its pinned
  `footer`), `AppKicker`, `AppButton`, `AppIconButton`, `AppTag`, `AppIcon`,
  `StatusDot` and `AppMonoText`, so a designed replacement is a swap;
- source unavailable;
- auth required;
- disk full;
- **leaving a finalized recording alone**. Design `1i` draws Send and Delete
  and no third way out, so the recording could only be uploaded or destroyed.
  `New recording` is added to the title bar in the existing ghost-link
  vocabulary, and says in mono where the file was left;
- **connecting an upload destination**. The canvas has no screen for it —
  design `1m` even offers "add a Telegram configuration section to `1m`" as a
  next step — but §15–§17 require credentials the user has to supply, and there
  was nowhere to supply them. `ConnectDestinationScreen` is the minimal
  structurally consistent state: the panel, kicker, hairline field, mono hint
  and ghost-link vocabulary of `1m`, and the accent-framed warning of `1k`,
  with nothing invented beyond them. It renders whatever a destination
  declares, so replacing it with a designed screen later is one screen, not one
  per destination.

**Not implemented — sharing diagnostics.** §26 requires debug logs to be
redactable *for user sharing*, and `AppLogger.exportRedactedDiagnostics()` and
`LogRedactor` are built and tested for exactly that. There is still no path to
them from the UI, because the canvas has no screen or affordance for it and the
obvious placement — a ghost link in `1m` beside the local-recordings row — is a
guess rather than a design.

What exists instead is a real file. `FileLogSink` writes redacted, rotated
diagnostics to `relay.log` in the application support directory, so a shipped
build is diagnosable and a user can be told where the file is. **The design gap
is the in-app affordance**, not the diagnostics themselves; it should be a
`Copy diagnostics` ghost link in `1m` once the canvas has one.

If a required state is absent from design:

- do not silently invent polished final UX;
- implement only a minimal structurally consistent state if needed to proceed;
- mark the design gap;
- keep it replaceable;
- do not introduce a new visual language outside the design system.

### Documented deviation: `1o` is not implemented

Design `1o` is a destination picker reached from `1i`, `1k` and `1m`. It is not
built: Change opens **Settings** instead, which is where the destination is
selected *and* connected. `1o` could only select — a destination with no
credentials could be chosen there and would then fail at Send — so keeping both
meant two screens answering the same question, only one of which could finish
the job.

What `1o` had and Settings does not is the per-file capability check: it dimmed
a destination that could not accept *this* recording. Settings shows the same
capability tag (`50 MB max`) without the file's size to compare it against; the
pre-flight in §14 still refuses the upload before any bytes are sent.

## Comparing the implementation against the design

Every screen renders offscreen at the shipping panel size:

```bash
flutter test test/tools/render_screens_test.dart --run-skipped
open build/design_review
```

Compare those against `design/preview.html`. The renders load the vendored
faces, so text measures as it does in the application; they are a review tool,
not an assertion suite, which is why they are tagged opt-in.

## UI Definition of Done

For UI work:

- inspect the relevant connected design first;
- run the renders above and compare them screen by screen;
- reuse/extend existing tokens;
- reuse existing components where applicable;
- add/update widget tests;
- visually compare implementation against design;
- check relevant resize states;
- check hover/focus/disabled/loading states where applicable;
- ensure high-DPI behavior is not broken.

Where stable and useful, add golden/screenshot tests for shared visual components. They supplement, not replace, behavior/widget/integration tests.
