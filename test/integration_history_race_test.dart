@Tags(['integration'])
library;

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:my_app/services/history_service.dart';

/// Integration test against the LIVE PocketBase at 127.0.0.1:8090 (with this
/// repo's pb_migrations + pb_hooks). Tagged `integration` and excluded from CI;
/// run locally with a dev backend up: `flutter test --tags integration`.
///
/// Several writers (think: the app, its background service, a second phone)
/// append to the same day's history row at once. Every point must survive —
/// the server's rev check (pb_hooks/history_rev.pb.js) makes losers re-read
/// and retry instead of overwriting each other.
void main() {
  const base = 'http://127.0.0.1:8090';
  final stamp = DateTime.now().microsecondsSinceEpoch;

  test('concurrent appends to one day keep every point', () async {
    const pw = 'password12345';
    final email = 'itH_$stamp@device.local';
    final setup = PocketBase(base);
    final user = await setup.collection('users').create(body: {
      'email': email, 'password': pw, 'passwordConfirm': pw,
    });

    // Each writer is its own client, like separate isolates/devices.
    Future<PocketBase> writer() async {
      final c = PocketBase(base);
      await c.collection('users').authWithPassword(email, pw);
      return c;
    }

    // Each writer needs at most `writers` attempts (every round has a
    // winner), so keep this within HistoryService's retry budget.
    const writers = 4;
    const perWriter = 5;
    final t0 = DateTime.utc(2026, 9, 20, 8);
    final clients = [for (var i = 0; i < writers; i++) await writer()];
    Future<String> plain(String s) async => s; // no device key in a test

    await Future.wait([
      for (var w = 0; w < writers; w++)
        HistoryService.appendToDay(
          clients[w],
          user.id,
          'subject',
          '2026-09-20',
          [
            for (var k = 0; k < perWriter; k++)
              HistoryPoint(51.5, -0.1,
                  t0.add(Duration(seconds: w * perWriter + k)))
          ],
          seal: plain,
          open: plain,
        ),
    ]);

    final row = await clients.first.collection('location_history')
        .getFirstListItem('owner = "${user.id}" && day = "2026-09-20"');
    final points =
        (jsonDecode(row.getStringValue('ciphertext'))['points'] as List);
    expect(points, hasLength(writers * perWriter),
        reason: 'a concurrent write dropped points');
    expect(row.getIntValue('rev'), writers); // one create + the updates
  });
}
