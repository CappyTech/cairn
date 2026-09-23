import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../services/pairing_service.dart';
import '../theme/brand.dart';

/// Scans another device's pairing QR (camera), with a paste fallback for
/// remote invites and for platforms without a camera (e.g. the web preview).
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _busy = false; // pairing with the server after a scan / paste
  String? _error;
  // The camera reports a code on every frame it's in view; don't retry one
  // that just failed until something else is scanned (pasting still retries).
  String? _lastFailed;

  Future<void> _handle(String raw, {bool fromCamera = false}) async {
    if (_busy || (fromCamera && raw == _lastFailed)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final name = await PairingService.pairFromPayload(raw);
      if (mounted) Navigator.pop(context, name);
    } catch (e) {
      if (!mounted) return;
      _lastFailed = raw;
      setState(() {
        // Our own messages are plain strings; anything else is a network or
        // server failure, which isn't worth showing raw.
        _error = e is String
            ? e
            : "Couldn't connect. Check your connection and try again.";
        _busy = false; // allow retry
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
      appBar: AppBar(title: const Text('Scan a code')),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(
                  onDetect: (capture) {
                    for (final barcode in capture.barcodes) {
                      final raw = barcode.rawValue;
                      if (raw != null && raw.isNotEmpty) {
                        _handle(raw, fromCamera: true);
                        break;
                      }
                    }
                  },
                  // Until the first frame arrives: say so, instead of a blank
                  // screen that looks broken.
                  placeholderBuilder: (context) => const _CameraStarting(),
                  // Where to aim. Scanning still reads the whole frame.
                  overlayBuilder: (context, constraints) =>
                      const _ScanFrame(),
                  errorBuilder: (context, error) => _CameraFallback(
                    message: error.errorDetails?.message,
                  ),
                ),
                if (_busy) const _Connecting(),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_error != null) ...[
                    Text(_error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                    const SizedBox(height: 8),
                  ],
                  Text('Point your camera at their Cairn code',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.cairn.ink)),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _pasteManually,
                      icon: const Icon(Icons.content_paste),
                      label: const Text('Paste code instead'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown while the camera starts up.
class _CameraStarting extends StatelessWidget {
  const _CameraStarting();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Brand.slate,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Brand.mist),
            SizedBox(height: 12),
            Text('Starting camera…', style: TextStyle(color: Brand.mist)),
          ],
        ),
      ),
    );
  }
}

/// A rounded square to aim the QR code into, with the rest of the preview
/// dimmed.
class _ScanFrame extends StatelessWidget {
  const _ScanFrame();

  @override
  Widget build(BuildContext context) {
    // The scanner passes loose constraints to the overlay; fill the preview.
    return IgnorePointer(
      child: SizedBox.expand(child: CustomPaint(painter: _ScanFramePainter())),
    );
  }
}

class _ScanFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide * 0.7;
    final frame = RRect.fromRectAndRadius(
      Rect.fromCenter(center: size.center(Offset.zero), width: side, height: side),
      const Radius.circular(20),
    );
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRRect(frame),
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.45),
    );
    canvas.drawRRect(
      frame,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Covers the preview while the pairing request goes to the server.
class _Connecting extends StatelessWidget {
  const _Connecting();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.55),
      child: const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5)),
                SizedBox(width: 16),
                Text('Connecting…'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CameraFallback extends StatelessWidget {
  final String? message;
  const _CameraFallback({this.message});

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
                  style: TextStyle(color: context.cairn.muted, fontSize: 12)),
            ],
            const SizedBox(height: 8),
            Text('You can paste their invite code below instead.',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.cairn.muted)),
          ],
        ),
      ),
    );
  }
}
