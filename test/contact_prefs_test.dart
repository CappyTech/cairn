import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/contact_prefs_service.dart';

/// Pure logic behind per-contact toggles: safe defaults (both on) and the
/// resolve lookup used every geofence tick.
void main() {
  group('ContactControls.fromJson', () {
    test('absent fields default ON', () {
      final c = ContactControls.fromJson({});
      expect(c.history, isTrue);
      expect(c.alerts, isTrue);
    });
    test('explicit false is honoured', () {
      final c = ContactControls.fromJson({'h': false, 'a': false});
      expect(c.history, isFalse);
      expect(c.alerts, isFalse);
    });
    test('round-trips through toJson', () {
      const c = ContactControls(history: false, alerts: true);
      final back = ContactControls.fromJson(c.toJson());
      expect(back.history, isFalse);
      expect(back.alerts, isTrue);
    });
  });

  group('copyWith', () {
    test('changes only the given field', () {
      const c = ContactControls(history: true, alerts: true);
      expect(c.copyWith(history: false).history, isFalse);
      expect(c.copyWith(history: false).alerts, isTrue);
    });
  });

  group('resolve', () {
    test('missing contact defaults to both-on', () {
      final r = ContactPrefsService.resolve({}, 'nobody');
      expect(r.history, isTrue);
      expect(r.alerts, isTrue);
    });
    test('returns the stored controls when present', () {
      final map = {'alice': const ContactControls(history: false, alerts: true)};
      final r = ContactPrefsService.resolve(map, 'alice');
      expect(r.history, isFalse);
      expect(r.alerts, isTrue);
    });
  });
}
