import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/widgets/contact_tile.dart';

/// Widget tests for the contacts-list row. ContactTile is presentational
/// (plain data + callbacks), so it renders without any services or a backend.
void main() {
  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  ContactTile tile({
    String name = 'Alice',
    String precision = 'precise',
    bool approxOnly = false,
    bool keyChanged = false,
    void Function(String)? onSetPrecision,
    VoidCallback? onRemove,
    VoidCallback? onRescan,
  }) =>
      ContactTile(
        name: name,
        precision: precision,
        approxOnly: approxOnly,
        keyChanged: keyChanged,
        onSetPrecision: onSetPrecision ?? (_) {},
        onRemove: onRemove ?? () {},
        onRescan: onRescan ?? () {},
      );

  group('ContactTile.precLabel', () {
    test('maps precision to a label', () {
      expect(ContactTile.precLabel('precise'), 'Sharing precise');
      expect(ContactTile.precLabel(''), 'Sharing precise');
      expect(
          ContactTile.precLabel('approximate'), 'Sharing approximate (~1 km)');
      expect(ContactTile.precLabel('off'), 'Sharing paused');
    });
  });

  testWidgets('normal tile shows the name and precise subtitle',
      (tester) async {
    await tester.pumpWidget(host(tile(name: 'Alice', precision: 'precise')));
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Sharing precise'), findsOneWidget);
  });

  testWidgets('empty name renders without crashing (crafted invite)',
      (tester) async {
    // A blank name must not throw at name[0] — it would take down the whole
    // contacts list. The avatar falls back to a placeholder initial.
    await tester.pumpWidget(host(tile(name: '')));
    expect(tester.takeException(), isNull);
    expect(find.text('?'), findsOneWidget);
  });

  test('ContactTile.initial guards empty and whitespace names', () {
    expect(ContactTile.initial(''), '?');
    expect(ContactTile.initial('   '), '?');
    expect(ContactTile.initial('alice'), 'A');
  });

  testWidgets('paused shows the paused subtitle', (tester) async {
    await tester.pumpWidget(host(tile(precision: 'off')));
    expect(find.text('Sharing paused'), findsOneWidget);
  });

  testWidgets('global approxOnly overrides the subtitle', (tester) async {
    await tester.pumpWidget(host(tile(precision: 'precise', approxOnly: true)));
    expect(find.text('Sharing approximate (global setting)'), findsOneWidget);
  });

  testWidgets('approxOnly does not override a paused contact', (tester) async {
    await tester.pumpWidget(host(tile(precision: 'off', approxOnly: true)));
    expect(find.text('Sharing paused'), findsOneWidget);
  });

  testWidgets('key-changed variant warns and wires its buttons',
      (tester) async {
    var rescanned = false;
    var removed = false;
    await tester.pumpWidget(host(tile(
      name: 'Bob',
      keyChanged: true,
      onRescan: () => rescanned = true,
      onRemove: () => removed = true,
    )));

    expect(find.textContaining('security key changed'), findsOneWidget);
    expect(find.text('Re-scan to verify'), findsOneWidget);

    await tester.tap(find.text('Re-scan to verify'));
    expect(rescanned, isTrue);
    await tester.tap(find.text('Remove'));
    expect(removed, isTrue);
  });

  testWidgets('precision menu reports the chosen value', (tester) async {
    String? picked;
    await tester.pumpWidget(host(tile(onSetPrecision: (p) => picked = p)));

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pause sharing'));
    await tester.pumpAndSettle();

    expect(picked, 'off');
  });
}
