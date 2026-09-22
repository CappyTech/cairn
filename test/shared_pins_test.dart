import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/shared_places_service.dart';

/// Pure model logic for shared pins: the sealed payload round-trip and its
/// tolerance of partial data.
void main() {
  test('toPayload → fromPayload round-trips the fields', () {
    const pin = SharedPin(
      group: 'g1',
      ownerId: 'me',
      name: 'Grand Hotel',
      lat: 51.5,
      lng: -0.12,
      note: 'Room 402 until Fri',
    );
    final back = SharedPin.fromPayload(pin.toPayload(),
        group: 'g1', ownerId: 'alice', sharerName: 'Alice');
    expect(back.name, 'Grand Hotel');
    expect(back.lat, closeTo(51.5, 1e-9));
    expect(back.lng, closeTo(-0.12, 1e-9));
    expect(back.note, 'Room 402 until Fri');
    expect(back.ownerId, 'alice');
    expect(back.sharerName, 'Alice');
    expect(back.group, 'g1');
  });

  test('omits an empty note from the payload', () {
    const pin = SharedPin(
        group: 'g', ownerId: 'me', name: 'X', lat: 1, lng: 2, note: '');
    expect(pin.toPayload().containsKey('note'), isFalse);
  });

  test('fromPayload fills safe defaults for missing/blank fields', () {
    final p = SharedPin.fromPayload({}, group: 'g', ownerId: 'o');
    expect(p.name, 'Shared pin');
    expect(p.lat, 0);
    expect(p.lng, 0);
    expect(p.note, isNull);
    expect(p.recipientIds, isEmpty);
  });
}
