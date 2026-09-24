import 'dart:math' as math;

/// Pure helpers for turning raw GPS / compass readings into speed and
/// direction values worth showing (or sharing). No platform calls, so every
/// gate here is unit-tested without a device.
///
/// Two different "directions" are in play:
///  - **course**: the direction of travel, from the GNSS receiver. Accurate
///    while moving, pure noise when still.
///  - **compass**: the direction the phone is *facing*, from the rotation-vector
///    sensor. Works standing still, but is thrown off by metal / magnets and
///    is referenced to magnetic north (~1° from true north in the UK — well
///    inside the 70° cone).
class Motion {
  /// Below this the GNSS course isn't trusted, whatever its reported accuracy
  /// (~a brisk walk; slower than this the course wanders).
  static const courseMinSpeed = 1.5; // m/s

  /// A course with a reported error wider than this is ignored. Walking
  /// typically reports ±20–40°, driving under ±10°; the cone is 70° wide, so
  /// anything inside ±45° still points the right way.
  static const maxCourseError = 45.0; // degrees

  /// Speeds are clamped here so the value (and its encoded width) stays
  /// bounded — nothing Cairn tracks goes faster than an airliner.
  static const maxSpeed = 350.0; // m/s

  /// The device's speed if it's trustworthy, else null. GNSS Doppler speed is
  /// good, but when [speedAccuracy] is reported (Android 8+, iOS) a reading
  /// smaller than twice its own error is indistinguishable from zero, so it's
  /// reported as 0 rather than a jittery walk.
  static double? trustedSpeed(double speed, double speedAccuracy) {
    if (speed.isNaN || speed < 0) return null;
    final s = math.min(speed, maxSpeed);
    if (speedAccuracy.isNaN || speedAccuracy <= 0) return s; // not reported
    return s < 2 * speedAccuracy ? 0 : s;
  }

  /// The GNSS course (degrees clockwise from north) when it means something:
  /// moving at [courseMinSpeed]+ with a valid heading and, where reported, an
  /// error under [maxCourseError]. Null otherwise.
  static double? course({
    required double speed,
    required double heading,
    double headingAccuracy = 0,
  }) {
    if (speed.isNaN || speed < courseMinSpeed) return null;
    if (heading.isNaN || heading < 0 || heading > 360) return null;
    if (!headingAccuracy.isNaN && headingAccuracy > maxCourseError) return null;
    return heading % 360;
  }

  /// The direction to draw for this device: the GNSS [course] while moving
  /// (it's the more reliable of the two then), else the [compass] if
  /// [useCompass]. Null = no direction to show.
  static double? blend({
    required double? course,
    required double? compass,
    required bool useCompass,
  }) {
    if (course != null) return course;
    if (useCompass && compass != null && !compass.isNaN) {
      return normalize(compass);
    }
    return null;
  }

  /// How old a fix can be and still speak for current speed / course. The
  /// position stream only fires on movement, so once someone stops, their
  /// last fix (still "moving") just ages — this is what retires it.
  static const motionMaxAge = Duration(seconds: 20);

  /// Whether a fix taken at [fixTime] is recent enough for its speed/course.
  static bool isFresh(DateTime fixTime, DateTime now) =>
      now.difference(fixTime) <= motionMaxAge;

  /// How long a contact's shared speed / direction stays on my map. Covers
  /// the 2-minute background share cadence (plus slack) so it doesn't flicker
  /// between shares, but retires a heading from someone who's gone quiet.
  static const contactMotionMaxAge = Duration(minutes: 3);

  /// Whether a contact's share from [updated] is recent enough to draw its
  /// speed / direction.
  static bool contactMotionFresh(DateTime updated, DateTime now) =>
      now.difference(updated) <= contactMotionMaxAge;

  /// [deg] wrapped into [0, 360).
  static double normalize(double deg) => ((deg % 360) + 360) % 360;

  /// Exponential smoothing on the circle: moves [prev] a fraction [alpha] of
  /// the SHORTEST way toward [next], so 359° → 1° steps through 0°, not 180°.
  static double smoothAngle(double? prev, double next, {double alpha = 0.25}) {
    if (prev == null) return normalize(next);
    final diff = ((next - prev + 540) % 360) - 180; // shortest signed delta
    return normalize(prev + alpha * diff);
  }

  /// The 8-point compass name for [deg] ("N", "NE", …).
  static String compassPoint(double deg) {
    const points = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    return points[((normalize(deg) + 22.5) ~/ 45) % 8];
  }

  /// Countries that sign road speeds in miles per hour.
  static const _mphCountries = {'GB', 'US', 'LR', 'MM'};

  /// Whether to show speeds in mph for a locale's [countryCode].
  static bool usesMph(String? countryCode) =>
      _mphCountries.contains(countryCode?.toUpperCase());

  /// A short human speed ("12 mph", "20 km/h"); "still" under ~1 km/h.
  static String formatSpeed(double metresPerSecond, {required bool mph}) {
    if (metresPerSecond < 0.3) return 'still';
    final v = metresPerSecond * (mph ? 2.23694 : 3.6);
    return '${v.round()} ${mph ? 'mph' : 'km/h'}';
  }
}
