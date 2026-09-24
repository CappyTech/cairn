import 'package:flutter/foundation.dart';
import 'prefs.dart';

/// The motion & direction toggles, as one immutable snapshot.
///
/// Sharing (what contacts get) defaults OFF; display (what I see) defaults ON.
/// Stored in [Prefs] so the background isolate reads the same answers; this
/// class adds a live [current] notifier so an open map reacts the moment a
/// toggle flips in Settings.
@immutable
class MotionSettings {
  /// Contacts get my speed (precise shares only).
  final bool shareSpeed;

  /// Contacts get my direction of travel (precise shares only).
  final bool shareHeading;

  /// My own dot shows a direction cone.
  final bool showMyHeading;

  /// My cone follows the compass while I'm still.
  final bool useCompass;

  /// Contacts' shared speed / direction are drawn on my map.
  final bool showContactsMotion;

  const MotionSettings({
    this.shareSpeed = false,
    this.shareHeading = false,
    this.showMyHeading = true,
    this.useCompass = true,
    this.showContactsMotion = true,
  });

  MotionSettings copyWith({
    bool? shareSpeed,
    bool? shareHeading,
    bool? showMyHeading,
    bool? useCompass,
    bool? showContactsMotion,
  }) =>
      MotionSettings(
        shareSpeed: shareSpeed ?? this.shareSpeed,
        shareHeading: shareHeading ?? this.shareHeading,
        showMyHeading: showMyHeading ?? this.showMyHeading,
        useCompass: useCompass ?? this.useCompass,
        showContactsMotion: showContactsMotion ?? this.showContactsMotion,
      );

  /// Whether the compass sensor is needed at all.
  bool get wantsCompass => showMyHeading && useCompass;

  /// The live settings (defaults until [load] completes).
  static final current = ValueNotifier<MotionSettings>(const MotionSettings());

  /// Read the stored toggles into [current].
  static Future<MotionSettings> load() async {
    final s = MotionSettings(
      shareSpeed: await Prefs.shareSpeed(),
      shareHeading: await Prefs.shareHeading(),
      showMyHeading: await Prefs.showMyHeading(),
      useCompass: await Prefs.useCompass(),
      showContactsMotion: await Prefs.showContactsMotion(),
    );
    current.value = s;
    return s;
  }

  /// Persist [next] (only the fields that changed) and publish it.
  static Future<void> save(MotionSettings next) async {
    final prev = current.value;
    current.value = next;
    if (next.shareSpeed != prev.shareSpeed) {
      await Prefs.setShareSpeed(next.shareSpeed);
    }
    if (next.shareHeading != prev.shareHeading) {
      await Prefs.setShareHeading(next.shareHeading);
    }
    if (next.showMyHeading != prev.showMyHeading) {
      await Prefs.setShowMyHeading(next.showMyHeading);
    }
    if (next.useCompass != prev.useCompass) {
      await Prefs.setUseCompass(next.useCompass);
    }
    if (next.showContactsMotion != prev.showContactsMotion) {
      await Prefs.setShowContactsMotion(next.showContactsMotion);
    }
  }
}
