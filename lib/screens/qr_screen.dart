import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import '../services/pairing_service.dart';
import '../services/invite_service.dart';

/// Shows this device's pairing QR (for in-person scanning) and, for people who
/// aren't nearby, lets you send a one-time invite code by copy/paste or share.
class QrScreen extends StatefulWidget {
  const QrScreen({super.key});

  @override
  State<QrScreen> createState() => _QrScreenState();
}

class _QrScreenState extends State<QrScreen> {
  bool _busy = false;

  /// Create a fresh single-use invite, then hand it off via [deliver].
  Future<void> _invite(Future<void> Function(String code) deliver) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final code = await InviteService.createInvite();
      await deliver(code);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Couldn't create an invite: $e")));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy() => _invite((code) async {
        await Clipboard.setData(ClipboardData(text: code));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Invite copied — it works once and expires in 24h.')));
      });

  Future<void> _share() => _invite((code) async {
        await SharePlus.instance
            .share(ShareParams(text: code, subject: 'Cairn invite'));
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My code')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
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
              const SizedBox(height: 20),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  'They point their camera here to connect with you. Only people '
                  'you show this to can pair.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ),
              const SizedBox(height: 28),
              const Divider(indent: 40, endIndent: 40),
              const SizedBox(height: 12),
              const Text('Not together?',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _copy,
                      icon: const Icon(Icons.copy),
                      label: const Text('Copy code'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.tonalIcon(
                      onPressed: _busy ? null : _share,
                      icon: const Icon(Icons.ios_share),
                      label: const Text('Share'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  'Sends a single-use invite that expires in 24 hours. Send it '
                  'over a channel you trust — whoever receives it can pair with '
                  'you. They open Scan → "Paste instead".',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
