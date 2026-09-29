import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/notification_service.dart';
import 'package:my_app/services/sound_service.dart';

/// Every sound the code names must actually ship: a channel sound missing from
/// res/raw silently falls back to the default (or fails to create the
/// channel), and a missing asset just plays nothing.
void main() {
  test('each alert kind has its own channel and a bundled raw sound', () {
    final channels = AlertKind.values.map((k) => k.channel).toList();
    expect(channels.toSet().length, channels.length, reason: 'unique ids');
    for (final c in channels) {
      expect(File('android/app/src/main/res/raw/$c.wav').existsSync(), isTrue,
          reason: '$c.wav in res/raw');
      // A copy for the Settings preview.
      expect(File('assets/sounds/$c.wav').existsSync(), isTrue,
          reason: '$c.wav in assets/sounds');
      // Android resource names: lowercase, digits, underscores only.
      expect(RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(c), isTrue);
    }
  });

  test('the release shrinker keeps the channel sounds', () {
    final keep =
        File('android/app/src/main/res/raw/keep.xml').readAsStringSync();
    expect(keep, contains('@raw/cairn_*'));
    for (final k in AlertKind.values) {
      expect(k.channel, startsWith('cairn_'));
    }
  });

  test('every UI sound is a bundled asset', () {
    for (final s in UiSound.values) {
      expect(File('assets/sounds/${s.file}').existsSync(), isTrue,
          reason: s.file);
    }
  });
}
