import 'package:flutter/material.dart';
import '../services/history_service.dart';
import '../theme/brand.dart';

/// How a [TravelMode] looks wherever trips are shown (History, Home's recent
/// trips), so they match.
extension TravelModeUi on TravelMode {
  Color get color => switch (this) {
        TravelMode.walk => Brand.lichen,
        TravelMode.cycle => const Color(0xFFD9A441),
        TravelMode.vehicle => const Color(0xFF4A86C5),
        TravelMode.train => const Color(0xFFB5654A),
        TravelMode.plane => const Color(0xFF8A6FC7),
      };

  IconData get icon => switch (this) {
        TravelMode.walk => Icons.directions_walk,
        TravelMode.cycle => Icons.directions_bike,
        TravelMode.vehicle => Icons.directions_car,
        TravelMode.train => Icons.train,
        TravelMode.plane => Icons.flight,
      };

  String get label => switch (this) {
        TravelMode.walk => 'Walk',
        TravelMode.cycle => 'Cycle',
        TravelMode.vehicle => 'Vehicle',
        TravelMode.train => 'Train',
        TravelMode.plane => 'Flight',
      };
}
