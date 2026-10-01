import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/directions.dart';

void main() {
  test('Android gets a geo: link naming the spot', () {
    final u = Directions.uri(51.5, -0.12,
        label: 'Sam (work)', platform: TargetPlatform.android, web: false);
    expect(u.scheme, 'geo');
    // Brackets in the name would end the label early, so they're dropped.
    expect(Uri.decodeComponent(u.query), 'q=51.500000,-0.120000(Sam work)');
  });

  test('Android without a name just gives the coordinates', () {
    final u = Directions.uri(51.5, -0.12,
        platform: TargetPlatform.android, web: false);
    expect(Uri.decodeComponent(u.query), 'q=51.500000,-0.120000');
  });

  test('iOS goes to Apple Maps', () {
    final u =
        Directions.uri(51.5, -0.12, platform: TargetPlatform.iOS, web: false);
    expect(u.host, 'maps.apple.com');
    expect(u.queryParameters['daddr'], '51.500000,-0.120000');
  });

  test('the web and desktop get OpenStreetMap directions', () {
    for (final u in [
      Directions.uri(51.5, -0.12, platform: TargetPlatform.android, web: true),
      Directions.uri(51.5, -0.12, platform: TargetPlatform.windows, web: false),
    ]) {
      expect(u.host, 'www.openstreetmap.org');
      expect(u.queryParameters['route'], ';51.500000,-0.120000');
    }
  });
}
