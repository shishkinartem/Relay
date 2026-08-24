/// Permission categories the recorder can require (§23).
enum PermissionKind {
  screenRecording,
  microphone,
  camera;

  static PermissionKind fromName(String name) => values.firstWhere(
    (PermissionKind k) => k.name == name,
    orElse: () => PermissionKind.screenRecording,
  );
}

/// Permission denial is a typed state, not a generic exception (§23).
enum PermissionStatus {
  granted,
  denied,
  notDetermined,
  restricted,

  /// Asked and answered, but the platform applies the answer only to a fresh
  /// process.
  ///
  /// macOS grants screen recording to the launched binary, so
  /// `CGRequestScreenCaptureAccess()` cannot return true in the process that
  /// asked: `false` there means *pending*, not *refused*. Without this member
  /// the only remaining word for that state is `denied`, which is what made the
  /// preflight call the user a refuser the instant they pressed Allow.
  pendingRelaunch,

  /// The platform has no such permission concept — treated as granted.
  notApplicable;

  bool get isUsable =>
      this == PermissionStatus.granted ||
      this == PermissionStatus.notApplicable;

  /// True when the answer exists but this process cannot see it yet.
  bool get needsRelaunch => this == PermissionStatus.pendingRelaunch;

  static PermissionStatus fromName(String? name) => values.firstWhere(
    (PermissionStatus s) => s.name == name,
    orElse: () => PermissionStatus.notDetermined,
  );
}

/// Result of the pre-recording permission sweep.
class PermissionReport {
  const PermissionReport(this.statuses);

  final Map<PermissionKind, PermissionStatus> statuses;

  PermissionStatus operator [](PermissionKind kind) =>
      statuses[kind] ?? PermissionStatus.notDetermined;

  bool isUsable(PermissionKind kind) => this[kind].isUsable;

  /// Screen recording is never optional: without it there is no video track.
  bool get canRecordScreen => isUsable(PermissionKind.screenRecording);

  /// What actually prevents a recording from starting.
  ///
  /// Only screen recording qualifies: without it there is no video track, so
  /// there is nothing to record. A denied microphone or camera degrades the
  /// session instead of blocking it — the recording the user asked for is still
  /// possible, just without that input.
  Set<PermissionKind> blockingDenials({
    bool microphoneRequested = false,
    bool cameraRequested = false,
  }) => <PermissionKind>{if (!canRecordScreen) PermissionKind.screenRecording};

  /// Optional inputs the user switched on that the OS will not deliver.
  ///
  /// These are reported, then silently switched off for the session (§23:
  /// "do not start a partially configured recording silently" — so it is
  /// stated, not silent, but it does not stop the recording).
  Set<PermissionKind> degradedInputs({
    required bool microphoneRequested,
    required bool cameraRequested,
  }) => <PermissionKind>{
    if (microphoneRequested && !isUsable(PermissionKind.microphone))
      PermissionKind.microphone,
    if (cameraRequested && !isUsable(PermissionKind.camera))
      PermissionKind.camera,
  };

  static PermissionReport fromMap(Map<String, Object?> map) =>
      PermissionReport(<PermissionKind, PermissionStatus>{
        for (final MapEntry<String, Object?> e in map.entries)
          PermissionKind.fromName(e.key): PermissionStatus.fromName(
            e.value as String?,
          ),
      });
}
