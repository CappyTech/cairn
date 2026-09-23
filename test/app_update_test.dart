import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/app_update_service.dart';

void main() {
  group('compareVersions', () {
    int cmp(String a, String b) => AppUpdateService.compareVersions(a, b).sign;

    test('orders numerically, not as text', () {
      expect(cmp('0.0.9', '0.0.10'), -1);
      expect(cmp('0.1.0', '0.0.99'), 1);
      expect(cmp('1.2.3', '1.2.3'), 0);
    });

    test('missing parts count as zero', () {
      expect(cmp('1.2', '1.2.0'), 0);
      expect(cmp('1', '1.0.1'), -1);
    });

    test('ignores build and pre-release suffixes', () {
      expect(cmp('0.0.15+17', '0.0.15'), 0);
      expect(cmp('0.0.16-beta', '0.0.16'), 0);
      expect(cmp('0.0.15+17', '0.0.16'), -1);
    });
  });

  group('evaluate', () {
    UpdateNeed eval(String current,
            {String min = '',
            String latest = '',
            bool play = false,
            int priority = 0}) =>
        AppUpdateService.evaluate(
          current: current,
          policy: AppVersionPolicy(minVersion: min, latestVersion: latest),
          playUpdateAvailable: play,
          playPriority: priority,
        );

    test('no policy and nothing on Play → none', () {
      expect(eval('0.0.15'), UpdateNeed.none);
    });

    test('below the server minimum → required', () {
      expect(eval('0.0.15', min: '0.0.16'), UpdateNeed.required);
    });

    test('at the minimum but below latest → recommended', () {
      expect(eval('0.0.16', min: '0.0.16', latest: '0.0.18'),
          UpdateNeed.recommended);
    });

    test('at or above latest → none', () {
      expect(eval('0.0.18', min: '0.0.16', latest: '0.0.18'), UpdateNeed.none);
      expect(eval('0.0.19', latest: '0.0.18'), UpdateNeed.none);
    });

    test('a newer Play build is recommended; an urgent one is required', () {
      expect(eval('0.0.15', play: true), UpdateNeed.recommended);
      expect(eval('0.0.15', play: true, priority: 3), UpdateNeed.recommended);
      expect(eval('0.0.15', play: true, priority: 4), UpdateNeed.required);
    });

    test('Play priority alone (no update available) changes nothing', () {
      expect(eval('0.0.15', priority: 5), UpdateNeed.none);
    });

    test('junk policy values are ignored, never lock the app', () {
      expect(eval('0.0.15', min: 'latest', latest: 'soon'), UpdateNeed.none);
      expect(eval('0.0.15', min: '  '), UpdateNeed.none);
    });
  });
}
