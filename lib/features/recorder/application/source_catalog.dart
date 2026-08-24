import 'dart:async';

import 'package:recorder_platform_interface/recorder_platform_interface.dart';

import '../../../core/logging/app_logger.dart';

/// What one enumeration produced.
///
/// A result rather than a thrown exception, because two of the three outcomes
/// are ordinary: an enumeration that is already running is skipped, and a
/// refused permission is the case the preflight exists for. Only the caller
/// knows what to do about either, so the catalogue reports and does not decide.
enum SourceLoadResult {
  /// The list was replaced.
  loaded,

  /// Another enumeration was already in flight; this call did nothing.
  skipped,

  /// The platform refused. See [SourceCatalog.lastFailure] for the code.
  failed,
}

/// The capture sources the picker shows, and which one is selected (§4.1).
///
/// Declared next to its consumer. Everything here is about *which* source;
/// nothing here starts, stops or records anything.
abstract interface class SourceCatalog {
  /// Displays first, then windows, exactly as the platform reported them.
  List<CaptureSource> get sources;

  /// The source a recording would use.
  CaptureSource? get selected;

  bool get isLoading;

  /// The code from the most recent failed enumeration, or null.
  RecorderErrorCode? get lastFailure;

  /// The display the main window is on, or the first source (§5).
  CaptureSource? get defaultSource;

  /// The best display to record without asking, or null when there is none.
  CaptureSource? get preferredDisplay;

  /// Re-reads the source list.
  ///
  /// [isLoading] is true before the returned future's first suspension, so a
  /// caller may notify its own listeners immediately after calling this and
  /// again after awaiting it.
  Future<SourceLoadResult> load({required bool refreshThumbnails});

  /// Records an explicit choice.
  void select(CaptureSource source);
}

/// [SourceCatalog] against the platform contract.
///
/// Split out of `RecorderViewModel` because enumeration has failure modes, a
/// latch and a default-selection rule that the capture lifecycle has no reason
/// to know about.
///
/// It reaches the platform through [CaptureSourceProvider] rather than the whole
/// [Recorder] contract. Enumerating is all it does, and the narrower dependency
/// is the one a substitute — a Linux portal that can only offer a single
/// pre-chosen source, say — is easiest to satisfy. That interface existed and
/// was never used as a type; this is what it is for.
class PlatformSourceCatalog implements SourceCatalog {
  PlatformSourceCatalog({
    required this._provider,
    required this._logger,
    required this._timeout,
  });

  final CaptureSourceProvider _provider;
  final Logger _logger;
  final Duration _timeout;

  List<CaptureSource> _sources = const <CaptureSource>[];
  CaptureSource? _selected;
  bool _loading = false;
  RecorderErrorCode? _lastFailure;

  @override
  List<CaptureSource> get sources => _sources;

  @override
  CaptureSource? get selected => _selected;

  @override
  bool get isLoading => _loading;

  @override
  RecorderErrorCode? get lastFailure => _lastFailure;

  /// Re-reads the source list.
  ///
  /// One enumeration at a time and never without a deadline: this is the call
  /// that blocks behind the operating system's permission prompt, which the
  /// user may never answer.
  @override
  Future<SourceLoadResult> load({required bool refreshThumbnails}) async {
    if (_loading) {
      return SourceLoadResult.skipped;
    }
    _loading = true;
    _lastFailure = null;
    try {
      _sources = await _provider
          .getAvailableSources(refreshThumbnails: refreshThumbnails)
          .timeout(_timeout);
      _applyDefaultSelection();
      return SourceLoadResult.loaded;
    } on RecorderException catch (e) {
      _lastFailure = e.code;
      _logger.warn(
        'source_enumeration_failed',
        fields: <String, Object?>{'code': e.code.name},
      );
      return SourceLoadResult.failed;
    } on TimeoutException {
      // The deadline is not a `RecorderException`, so without its own clause it
      // escapes this method and skips the picker's `Navigator.push`, leaving
      // the user on the launch screen with nothing to show for the tap.
      _lastFailure = RecorderErrorCode.sourceUnavailable;
      _logger.warn('source_enumeration_timed_out');
      return SourceLoadResult.failed;
    } finally {
      // Released on every path. Left set, the first enumeration is the only one
      // that ever runs: the picker keeps showing the launch-time snapshot,
      // windows opened since are missing, and their stale ids fail `prepare`
      // with `sourceClosed`.
      _loading = false;
    }
  }

  @override
  void select(CaptureSource source) => _selected = source;

  @override
  CaptureSource? get defaultSource {
    for (final CaptureSource source in _sources) {
      if (source.type == CaptureSourceType.display && source.isCurrentDisplay) {
        return source;
      }
    }
    return _sources.isEmpty ? null : _sources.first;
  }

  /// The best display to record without asking, or null when there is none.
  ///
  /// Backs the launch screen's `Entire screen` choice: picking a display is
  /// one click, picking a window has to ask which one.
  @override
  CaptureSource? get preferredDisplay => _sources
      .where((CaptureSource s) => s.type == CaptureSourceType.display)
      .fold<CaptureSource?>(
        null,
        (CaptureSource? best, CaptureSource s) =>
            best == null || (s.isCurrentDisplay && !best.isCurrentDisplay)
            ? s
            : best,
      );

  /// Keeps the selection valid across a refresh.
  ///
  /// A source that is still there keeps being selected, but the *instance* is
  /// replaced so a newly captured thumbnail is picked up. One that has gone —
  /// a window the user closed — falls back to the default rather than staying
  /// selected and failing `prepare` with `sourceClosed`.
  void _applyDefaultSelection() {
    final CaptureSource? current = _selected;
    if (current != null &&
        _sources.any((CaptureSource s) => s.id == current.id)) {
      _selected = _sources.firstWhere((CaptureSource s) => s.id == current.id);
      return;
    }
    _selected = defaultSource;
  }
}
