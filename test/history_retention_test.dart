import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/history_service.dart';
import 'package:my_app/services/prefs.dart';

/// Pure logic behind the server-advertised retention policy: the effective
/// window (server ∧ local override), whether (re)consent is needed, and which
/// days fall outside the window and get pruned.
void main() {
  group('effectiveRetentionDays', () {
    test('both unlimited → keep all (0)', () {
      expect(HistoryService.effectiveRetentionDays(0, null), 0);
      expect(HistoryService.effectiveRetentionDays(0, 0), 0);
    });
    test('only the server limits', () {
      expect(HistoryService.effectiveRetentionDays(30, null), 30);
      expect(HistoryService.effectiveRetentionDays(30, 0), 30); // local 0 = keep all → ignored
    });
    test('only the local override limits', () {
      expect(HistoryService.effectiveRetentionDays(0, 7), 7);
    });
    test('the smaller (more private) window wins', () {
      expect(HistoryService.effectiveRetentionDays(30, 90), 30);
      expect(HistoryService.effectiveRetentionDays(90, 30), 30);
    });
  });

  group('consentNeeded', () {
    test('never asked → needed', () {
      expect(HistoryService.consentNeeded(serverDays: 30, stored: null), isTrue);
    });
    test('agreed to the same policy → not needed', () {
      expect(
        HistoryService.consentNeeded(
            serverDays: 30,
            stored: const HistoryConsent(days: 30, declined: false)),
        isFalse,
      );
    });
    test('declined the same policy → not re-prompted', () {
      expect(
        HistoryService.consentNeeded(
            serverDays: 30,
            stored: const HistoryConsent(days: 30, declined: true)),
        isFalse,
      );
    });
    test('policy changed since answering → re-prompt (agreed or declined)', () {
      expect(
        HistoryService.consentNeeded(
            serverDays: 7,
            stored: const HistoryConsent(days: 30, declined: false)),
        isTrue,
      );
      expect(
        HistoryService.consentNeeded(
            serverDays: 7,
            stored: const HistoryConsent(days: 30, declined: true)),
        isTrue,
      );
    });
  });

  group('daysToPrune', () {
    final today = DateTime.utc(2026, 9, 20);
    final days = ['2026-09-10', '2026-09-13', '2026-09-14', '2026-09-20'];

    test('keep-all (0) prunes nothing', () {
      expect(HistoryService.daysToPrune(days, 0, today), isEmpty);
      expect(HistoryService.daysToPrune(days, -5, today), isEmpty);
    });

    test('a 7-day window keeps today back to the cutoff (inclusive)', () {
      // 7 days ending 09-20 → cutoff 09-14; older than that is pruned.
      expect(
        HistoryService.daysToPrune(days, 7, today),
        ['2026-09-10', '2026-09-13'],
      );
    });

    test('a 1-day window keeps only today', () {
      expect(
        HistoryService.daysToPrune(days, 1, today),
        ['2026-09-10', '2026-09-13', '2026-09-14'],
      );
    });

    test('a window wider than the data prunes nothing', () {
      expect(HistoryService.daysToPrune(days, 3650, today), isEmpty);
    });
  });
}
