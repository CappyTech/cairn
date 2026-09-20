/// A device's coarse motion state, derived on-device from GPS speed.
///
/// This is computed by the *sender* and travels inside the already-encrypted
/// location payload, so — like the location itself — the server can't read it;
/// only paired contacts can. We deliberately send the coarse *bucket* (e.g.
/// "driving") rather than a raw speed, so no finer-grained movement data than
/// the state itself ever leaves the device.
enum MotionActivity {
  idle,
  walking,
  driving,
  train,
  plane,

  /// No usable speed reading (e.g. a fresh fix, or an older sender that didn't
  /// send a state). Rendered as "no state", not guessed.
  unknown;

  // Thresholds in metres/second. These are heuristics — the car/train and
  // train/plane boundaries are inherently fuzzy (a fast car ≈ a slow train) —
  // chosen at round road/rail/air speeds and kept in one place.
  static const double _walking = 0.6; //  ~2.2 km/h — moving, on foot
  static const double _driving = 3.5; // ~12.6 km/h — above a jog
  static const double _train = 36.0; //  ~130 km/h — above road speeds
  static const double _plane = 97.0; //  ~350 km/h — above rail speeds

  /// Classify a speed (metres/second) into a motion state. A null, negative or
  /// NaN speed — what a device reports when it has no velocity fix — is
  /// [unknown] rather than a guessed [idle]. Pure; unit-tested.
  static MotionActivity fromSpeed(double? metersPerSecond) {
    final s = metersPerSecond;
    if (s == null || s.isNaN || s < 0) return MotionActivity.unknown;
    if (s < _walking) return MotionActivity.idle;
    if (s < _driving) return MotionActivity.walking;
    if (s < _train) return MotionActivity.driving;
    if (s < _plane) return MotionActivity.train;
    return MotionActivity.plane;
  }

  /// Stable wire token stored in the encrypted payload. Uses the enum name so
  /// the protocol string never depends on the display label.
  String get wire => name;

  /// Parse a wire token back to a state; anything unrecognised or missing (an
  /// older sender) is [unknown]. Pure.
  static MotionActivity fromWire(Object? token) {
    for (final a in MotionActivity.values) {
      if (a.name == token) return a;
    }
    return MotionActivity.unknown;
  }

  /// Human label for the UI. [unknown] has no label (callers fall back to a
  /// freshness/presence string instead).
  String get label {
    switch (this) {
      case MotionActivity.idle:
        return 'idle';
      case MotionActivity.walking:
        return 'walking';
      case MotionActivity.driving:
        return 'driving';
      case MotionActivity.train:
        return 'on a train';
      case MotionActivity.plane:
        return 'on a plane';
      case MotionActivity.unknown:
        return '';
    }
  }

  bool get isKnown => this != MotionActivity.unknown;

  /// Moving under their own steam or a vehicle (i.e. not idle and not unknown) —
  /// used to decide when a state is worth surfacing prominently.
  bool get isMoving => isKnown && this != MotionActivity.idle;
}
