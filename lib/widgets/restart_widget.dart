import 'package:flutter/material.dart';
import '../services/pb_client.dart';

/// Lets us rebuild the whole app from scratch (e.g. after the server URL
/// changes) by swapping the subtree key.
class RestartWidget extends StatefulWidget {
  final Widget child;
  const RestartWidget({super.key, required this.child});

  /// Re-initialise the PocketBase client and rebuild the app.
  static Future<void> restart(BuildContext context) async {
    final state = context.findAncestorStateOfType<_RestartWidgetState>();
    await initPocketBase();
    state?.restart();
  }

  @override
  State<RestartWidget> createState() => _RestartWidgetState();
}

class _RestartWidgetState extends State<RestartWidget> {
  Key _key = UniqueKey();
  void restart() => setState(() => _key = UniqueKey());

  @override
  Widget build(BuildContext context) =>
      KeyedSubtree(key: _key, child: widget.child);
}
