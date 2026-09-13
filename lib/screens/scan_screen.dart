import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../services/pairing_service.dart';

/// Scans another device's pairing QR (camera), with a manual paste fallback
/// for platforms without a camera (e.g. the web dev preview).
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _handled = false;
  String? _error;

  Future<void> _handle(String raw) async {
    if (_handled) return;
    _handled = true;
    try {
      final name = await PairingService.pairFromPayload(raw);
      if (mounted) Navigator.pop(context, name);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _handled = false; // allow retry
      });
    }
  }

  Future<void> _pasteManually() async {
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Paste invite code'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'Paste the code text from the other device',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Connect')),
        ],
      ),
    );
    if (raw != null && raw.isNotEmpty) await _handle(raw);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan a code'),
        actions: [
          IconButton(
            tooltip: 'Paste instead',
            icon: const Icon(Icons.content_paste),
            onPressed: _pasteManually,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(
              onDetect: (capture) {
                for (final barcode in capture.barcodes) {
                  final raw = barcode.rawValue;
                  if (raw != null && raw.isNotEmpty) {
                    _handle(raw);
                    break;
                  }
                }
              },
              errorBuilder: (context, error) => _CameraFallback(
                onPaste: _pasteManually,
                message: error.errorDetails?.message,
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Point the camera at their QR code',
                style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
  }
}

class _CameraFallback extends StatelessWidget {
  final VoidCallback onPaste;
  final String? message;
  const _CameraFallback({required this.onPaste, this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography, size: 48),
            const SizedBox(height: 12),
            const Text('Camera unavailable here',
                textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: 4),
              Text(message!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onPaste,
              icon: const Icon(Icons.content_paste),
              label: const Text('Paste code instead'),
            ),
          ],
        ),
      ),
    );
  }
}
