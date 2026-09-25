import 'package:flutter/material.dart';
import '../services/activity_sensor.dart';
import '../services/prefs.dart';

/// History's switches: detect how I travel (activity sensor), precise trip
/// recording, and road snapping without the prompt. Shown in History's
/// settings sheet.
class HistorySettingsTiles extends StatefulWidget {
  const HistorySettingsTiles({super.key});

  @override
  State<HistorySettingsTiles> createState() => _HistorySettingsTilesState();
}

class _HistorySettingsTilesState extends State<HistorySettingsTiles> {
  bool _loaded = false;
  bool _sensorAvailable = false; // Android 8+ / iOS
  bool _sensing = false;
  bool _roadSnap = false;
  bool _precise = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final available = await ActivitySensor.available();
    // On, but the permission was since revoked in system settings → off.
    var sensing = await Prefs.activitySensing();
    if (sensing && !await ActivitySensor.permitted()) {
      sensing = false;
      await Prefs.setActivitySensing(false);
    }
    final roadSnap = await Prefs.roadSnapAllowed();
    final precise = await Prefs.preciseRecording();
    if (!mounted) return;
    setState(() {
      _sensorAvailable = available;
      _sensing = sensing;
      _roadSnap = roadSnap;
      _precise = precise;
      _loaded = true;
    });
  }

  Future<void> _setSensing(bool on) async {
    if (on && !await ActivitySensor.requestPermission()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Allow "Physical activity" for Cairn in system '
                'settings to use this.')));
      }
      return;
    }
    await Prefs.setActivitySensing(on);
    await ActivitySensor.ensureListening(); // starts, or stops when off
    if (mounted) setState(() => _sensing = on);
  }

  Future<void> _setPrecise(bool on) async {
    await Prefs.setPreciseRecording(on);
    if (mounted) setState(() => _precise = on);
  }

  Future<void> _setRoadSnap(bool on) async {
    await Prefs.setRoadSnapAllowed(on);
    if (mounted) setState(() => _roadSnap = on);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_sensorAvailable)
          SwitchListTile(
            secondary: const Icon(Icons.commute),
            title: const Text('Detect how you travel'),
            subtitle: const Text('Tells walking, cycling and driving apart.'),
            value: _sensing,
            onChanged: _setSensing,
          ),
        // Precise recording runs in the background service (phones only).
        if (ActivitySensor.supported)
          SwitchListTile(
            secondary: const Icon(Icons.gps_fixed),
            title: const Text('Precise trip recording'),
            subtitle: Text(_sensing
                ? 'Follows the roads while you move. Uses more battery.'
                : 'Follows the roads. Uses more battery; less with '
                    '"Detect how you travel" on.'),
            value: _precise,
            onChanged: _setPrecise,
          ),
        SwitchListTile(
          secondary: const Icon(Icons.route),
          title: const Text('Always allow road snapping'),
          subtitle: const Text("Don't ask each time you snap a trip."),
          value: _roadSnap,
          onChanged: _setRoadSnap,
        ),
      ],
    );
  }
}
