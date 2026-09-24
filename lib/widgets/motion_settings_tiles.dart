import 'package:flutter/material.dart';
import '../services/motion_settings.dart';
import '../theme/brand.dart';

/// The motion & direction toggles, grouped by who sees the result: "Contacts
/// see" (off by default — shared in the encrypted location) and "I see" (on
/// by default — never leaves the device). Used by Settings and by the map's
/// "You" sheet, bound to [MotionSettings.current] so both stay in sync.
class MotionSettingsTiles extends StatelessWidget {
  /// Drop the ListTile side padding (for use inside an already-padded sheet).
  final bool dense;
  const MotionSettingsTiles({super.key, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final pad = dense ? EdgeInsets.zero : null;
    Widget sub(String text) => Padding(
          padding: EdgeInsets.fromLTRB(dense ? 0 : 16, 12, 16, 0),
          child: Text(text,
              style: TextStyle(fontSize: 12, color: context.cairn.muted)),
        );
    Widget sw(IconData icon, String title, String subtitle, bool value,
            ValueChanged<bool>? onChanged) =>
        SwitchListTile(
          contentPadding: pad,
          secondary: Icon(icon),
          title: Text(title),
          subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
          value: value,
          onChanged: onChanged,
        );

    return ValueListenableBuilder<MotionSettings>(
      valueListenable: MotionSettings.current,
      builder: (context, s, _) {
        void set(MotionSettings next) => MotionSettings.save(next);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            sub('CONTACTS SEE'),
            sw(
              Icons.speed,
              'Share my speed',
              s.shareSpeed
                  ? 'On — contacts with precise sharing see how fast you move.'
                  : 'Off — contacts see only where you are.',
              s.shareSpeed,
              (v) => set(s.copyWith(shareSpeed: v)),
            ),
            sw(
              Icons.explore_outlined,
              'Share my direction',
              s.shareHeading
                  ? 'On — contacts see which way you\'re travelling, '
                      'while you\'re moving.'
                  : 'Off — contacts don\'t see which way you\'re heading.',
              s.shareHeading,
              (v) => set(s.copyWith(shareHeading: v)),
            ),
            if (s.shareSpeed || s.shareHeading)
              Padding(
                padding: EdgeInsets.fromLTRB(dense ? 0 : 16, 0, 16, 4),
                child: Text(
                  'Never sent to contacts on ~1 km or paused sharing. '
                  'End-to-end encrypted, like your location.',
                  style: TextStyle(fontSize: 11, color: context.cairn.muted),
                ),
              ),
            sub('I SEE'),
            sw(
              Icons.navigation_outlined,
              'My direction on the map',
              'A cone on your dot pointing the way you\'re going.',
              s.showMyHeading,
              (v) => set(s.copyWith(showMyHeading: v)),
            ),
            sw(
              Icons.screen_rotation_alt,
              'Use the compass when still',
              s.showMyHeading
                  ? 'Points the cone where your phone faces, using its motion '
                      'sensors while the map is open.'
                  : 'Turn on "My direction" first.',
              s.showMyHeading && s.useCompass,
              s.showMyHeading ? (v) => set(s.copyWith(useCompass: v)) : null,
            ),
            sw(
              Icons.people_outline,
              'Contacts\' speed & direction',
              'Show them when a contact chooses to share them.',
              s.showContactsMotion,
              (v) => set(s.copyWith(showContactsMotion: v)),
            ),
          ],
        );
      },
    );
  }
}
