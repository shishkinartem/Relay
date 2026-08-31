/// What the host is still holding, counted (§19.1).
///
/// §19.1 specifies what a session must have released by the time it is over,
/// and observes that "state is cleaned up" is not a requirement because nothing
/// can fail it. This is what makes it falsifiable: every row is an integer a
/// test can compare, and the two tests §19.1 names — census equality across ten
/// start → stop cycles, and every row zero after one stop — are both ordinary
/// equality assertions on this object.
///
/// **Debug-only, and diagnostic only.** Nothing in the application may branch
/// on a census: it is an assertion surface, not a source of truth about the
/// session. A host that cannot count a row reports zero for it rather than
/// failing the call, because a census that throws on the teardown path would
/// turn a leak into a crash.
///
/// Every field is a count, including [writers] and [compositors], which are 0
/// or 1. One type for the whole map is what lets equality be a single
/// comparison rather than twelve — and a writer that somehow existed twice
/// should read as 2, not as `true`.
class ResourceCensus {
  const ResourceCensus({
    this.captureStreams = 0,
    this.cameraSessions = 0,
    this.microphoneSessions = 0,
    this.meteringTaps = 0,
    this.meterSubscriptions = 0,
    this.registeredTextures = 0,
    this.overlayEngines = 0,
    this.eventMonitors = 0,
    this.sessionTimers = 0,
    this.powerAssertions = 0,
    this.writers = 0,
    this.compositors = 0,
  });

  /// Live screen-capture streams and their content filters.
  final int captureStreams;

  /// Camera capture sessions that still have a device input attached.
  ///
  /// A *stopped* session still counts while its input is attached: §19.1
  /// releases "the camera capture **and its device input**", and a stopped
  /// capture session that keeps its input is exactly the idle recorder owning a
  /// configured camera graph that `releaseSession` exists to end.
  final int cameraSessions;

  /// The microphone's equivalent, on the same terms.
  final int microphoneSessions;

  /// Metering taps the *meter* has open.
  ///
  /// Never a level read off a capture the session already holds, which opens
  /// nothing and so counts nothing: §33.7 forbids opening a device a recording
  /// is using a second time, and a census that counted that as a tap would
  /// report a leak for behaving correctly.
  final int meteringTaps;

  /// How many callers are still asking to be metered.
  ///
  /// Counted separately from [meteringTaps] because they answer different
  /// questions: a leaked subscription with no tap is a meter that will re-open
  /// a device on the next start, and a tap with no subscribers is a device held
  /// for a bar nobody is looking at.
  final int meterSubscriptions;

  /// Textures registered against any engine — the camera preview's, today.
  final int registeredTextures;

  /// Secondary Flutter engines hosting overlay windows.
  ///
  /// Expected to be non-zero on a host that keeps its engines for the life of
  /// the process, which §19.1 allows explicitly and
  /// `docs/development/compatibility-matrix.md` records per platform. What must
  /// not change is the number, which is what the equality test asserts.
  final int overlayEngines;

  /// Event monitors, hooks and observers a *session* installed — menu
  /// dismissal, drag end, low-level input hooks.
  ///
  /// Not the ones the plugin installs once for the life of the process: those
  /// are part of the launch census, and the equality test is what holds them to
  /// it.
  final int eventMonitors;

  /// Session timers: the tick, and anything else scheduled per session.
  final int sessionTimers;

  /// Power/sleep assertions held.
  final int powerAssertions;

  /// 1 while an asset writer, its inputs and its pixel-buffer pool exist.
  final int writers;

  /// 1 while a compositor and its caches exist.
  final int compositors;

  /// True when every row of §19.1's *first* table is zero — what its
  /// post-session test asserts.
  ///
  /// [overlayEngines] is deliberately excluded, and this is the whole reason
  /// the getter exists rather than an `isEmpty`. §19.1 puts the engines in its
  /// second table, "survives, because it is a setting and not state": a host
  /// that keeps its overlay engines for the life of the process is lawful, and
  /// asserting zero here would fail a platform for a choice the specification
  /// grants it. What that host owes instead is stability, which the census
  /// **equality** test is what checks.
  ///
  /// Every other row is required to be zero, [eventMonitors] included: it
  /// counts only what a *session* installed, so §19.1's "the census reports the
  /// launch counts" and zero are the same number.
  bool get sessionResourcesReleased =>
      captureStreams == 0 &&
      cameraSessions == 0 &&
      microphoneSessions == 0 &&
      meteringTaps == 0 &&
      meterSubscriptions == 0 &&
      registeredTextures == 0 &&
      eventMonitors == 0 &&
      sessionTimers == 0 &&
      powerAssertions == 0 &&
      writers == 0 &&
      compositors == 0;

  Map<String, Object?> toMap() => <String, Object?>{
    'captureStreams': captureStreams,
    'cameraSessions': cameraSessions,
    'microphoneSessions': microphoneSessions,
    'meteringTaps': meteringTaps,
    'meterSubscriptions': meterSubscriptions,
    'registeredTextures': registeredTextures,
    'overlayEngines': overlayEngines,
    'eventMonitors': eventMonitors,
    'sessionTimers': sessionTimers,
    'powerAssertions': powerAssertions,
    'writers': writers,
    'compositors': compositors,
  };

  /// A missing row decodes as zero rather than failing.
  ///
  /// The census is an assertion surface: a host that has not learned to count
  /// something yet should make the test that reads it fail on the row it cannot
  /// answer, not on the decode — and a decode that threw would take the
  /// teardown path down with it.
  static ResourceCensus fromMap(Map<String, Object?> map) {
    int at(String key) => (map[key] as num? ?? 0).toInt();
    return ResourceCensus(
      captureStreams: at('captureStreams'),
      cameraSessions: at('cameraSessions'),
      microphoneSessions: at('microphoneSessions'),
      meteringTaps: at('meteringTaps'),
      meterSubscriptions: at('meterSubscriptions'),
      registeredTextures: at('registeredTextures'),
      overlayEngines: at('overlayEngines'),
      eventMonitors: at('eventMonitors'),
      sessionTimers: at('sessionTimers'),
      powerAssertions: at('powerAssertions'),
      writers: at('writers'),
      compositors: at('compositors'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ResourceCensus &&
      other.captureStreams == captureStreams &&
      other.cameraSessions == cameraSessions &&
      other.microphoneSessions == microphoneSessions &&
      other.meteringTaps == meteringTaps &&
      other.meterSubscriptions == meterSubscriptions &&
      other.registeredTextures == registeredTextures &&
      other.overlayEngines == overlayEngines &&
      other.eventMonitors == eventMonitors &&
      other.sessionTimers == sessionTimers &&
      other.powerAssertions == powerAssertions &&
      other.writers == writers &&
      other.compositors == compositors;

  @override
  int get hashCode => Object.hash(
    captureStreams,
    cameraSessions,
    microphoneSessions,
    meteringTaps,
    meterSubscriptions,
    registeredTextures,
    overlayEngines,
    eventMonitors,
    sessionTimers,
    powerAssertions,
    writers,
    compositors,
  );

  /// Every row, named. A census that fails an equality assertion has to say
  /// *which* row moved, or the test reports "these two objects differ".
  @override
  String toString() =>
      'ResourceCensus('
      '${toMap().entries.map((MapEntry<String, Object?> e) => '${e.key}: ${e.value}').join(', ')})';
}
