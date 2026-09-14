import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/pairing_service.dart';

/// Shows this device's pairing QR code for someone else to scan.
class QrScreen extends StatelessWidget {
  const QrScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My code')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Have the other person scan this',
                style: TextStyle(fontSize: 16)),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: FutureBuilder<String>(
                future: PairingService.myQrPayload(),
                builder: (context, snap) {
                  if (!snap.hasData) {
                    return const SizedBox(
                        width: 240,
                        height: 240,
                        child: Center(child: CircularProgressIndicator()));
                  }
                  return QrImageView(
                    data: snap.data!,
                    size: 240,
                    backgroundColor: Colors.white,
                  );
                },
              ),
            ),
            const SizedBox(height: 24),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                'They point their camera here to connect with you. Only people '
                'you show this to can pair.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
