import 'package:flutter/widgets.dart';

/// The binding the always-on-top overlay engines run on.
///
/// Flutter stops producing frames whenever the *application* reports `hidden`,
/// `paused` or `detached` ([SchedulerBinding.framesEnabled]), and a secondary
/// engine is told about the application's state, not about its own window's.
/// Recording puts the application in exactly that state on purpose: §6 takes
/// the main window off the screen, and from then on the only surfaces this
/// process has are these panels.
///
/// Without this binding the control strip stops drawing as soon as the
/// application is no longer the front one — which is the entire point of a
/// screen recorder. It goes on receiving state pushes and its buttons go on
/// sending commands, but nothing it draws ever changes again: the clock stops,
/// the recording and paused glyphs never swap, the input toggles never move,
/// and hover and press feedback never appear. Every control reads as laggy or
/// dead, and Pause and Resume read as broken even though the session below
/// them is doing exactly what was asked.
///
/// So the lifecycle state stays accurate for observers, and only the frame
/// gate is dropped: an overlay window is on screen precisely when the
/// application is not.
///
/// Frames are still produced on demand, never on a clock. The strip asks for
/// one when a pushed snapshot changes it and when a pointer enters or presses
/// a control, which is a handful per second while recording and none at all
/// when the overlay is hidden.
class OverlayBinding extends WidgetsFlutterBinding {
  OverlayBinding._();

  static OverlayBinding? _instance;

  /// Installs the binding for this engine. Idempotent, like every other
  /// `ensureInitialized`, so an entrypoint may call it unconditionally.
  static WidgetsBinding ensureInitialized() {
    if (_instance == null) {
      OverlayBinding._();
    }
    return WidgetsBinding.instance;
  }

  @override
  void initInstances() {
    super.initInstances();
    _instance = this;
  }

  /// Gated on the root widget only.
  ///
  /// [WidgetsBinding] ands the lifecycle gate together with "a root widget has
  /// been attached". The second half is kept — a frame before [runApp] has
  /// nothing to draw — and the first is deliberately not consulted.
  @override
  bool get framesEnabled => isRootWidgetAttached;
}
