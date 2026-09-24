import 'package:recorder_platform_interface/recorder_platform_interface.dart';

import '../design_system/tokens/app_spacing.dart';

/// How much room the panel header leaves on its leading edge for the window's
/// own buttons.
///
/// A mapping, not a branch: the registered platform reports how its runner
/// framed the window and this turns that fact into the design system's own
/// token. No operating system is named here, and none can be — the answer
/// comes from whichever plugin registered itself (§28).
///
/// Read where the shell lays out its very first frame rather than routed
/// through `main.dart`, so a shell cannot be mounted with the wrong number.
/// Before this existed the header hardcoded macOS's reservation, and on
/// Windows — whose runner leaves its caption alone — that room drew as a dead
/// gap down the leading edge of every screen.
///
/// Its own file, and deliberately a small one. It used to be a static on
/// `CompositionRoot`, which made every widget test that mounts the shell import
/// the whole object graph — the upload destinations, both plugin shims — and
/// those are covered by their own package suites, not by the root run. They
/// arrived in `coverage/lcov.info` at zero and took the line-coverage ratchet
/// with them. Nothing here needs the graph: one enum and one token.
double get titleBarLeadingInset =>
    switch (RecorderPlatform.instance.windowChrome) {
      WindowChrome.separateTitleBar => AppSpacing.titleBarPadding,
      WindowChrome.overlaidWindowButtons =>
        AppSpacing.titleBarWindowButtonsInset,
    };
