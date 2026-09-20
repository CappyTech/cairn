/// Formats a speed for display and picks a sensible default unit. Pure —
/// unit-tested. Speeds are handled internally in metres/second (what the
/// device's GPS reports) and rendered as whole mph or km/h.
class SpeedUnit {
  static const double _mphPerMps = 2.2369362920544; // 1 m/s in mph
  static const double _kmhPerMps = 3.6; //             1 m/s in km/h

  /// "45 mph" or "72 km/h", rounded to a whole number. A null, negative or NaN
  /// speed reads as 0.
  static String format(double? metersPerSecond, {required bool miles}) {
    var mps = metersPerSecond ?? 0;
    if (mps.isNaN || mps < 0) mps = 0;
    final v = miles ? mps * _mphPerMps : mps * _kmhPerMps;
    return '${v.round()} ${label(miles: miles)}';
  }

  /// The bare unit label, e.g. for a toggle button.
  static String label({required bool miles}) => miles ? 'mph' : 'km/h';

  /// Whether to default to miles per hour for a given ISO country code. Road
  /// speeds are in mph in the US, UK, Liberia and Myanmar; everywhere else uses
  /// km/h. Users can still switch. Pure.
  static bool defaultMilesForCountry(String? countryCode) {
    const milesCountries = {'US', 'GB', 'UK', 'LR', 'MM'};
    return milesCountries.contains(countryCode?.toUpperCase());
  }
}
