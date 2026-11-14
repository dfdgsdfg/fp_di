import 'package:devtools_extensions/devtools_extensions.dart';
import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/service_client.dart';

void main() {
  runApp(const FpDiDevToolsExtension());
}

/// The root of the extension: the `DevToolsExtension` wrapper gives the
/// `serviceManager` that the client reads.
class FpDiDevToolsExtension extends StatelessWidget {
  const FpDiDevToolsExtension({super.key});

  @override
  Widget build(BuildContext context) {
    return const DevToolsExtension(child: _Connected());
  }
}

class _Connected extends StatefulWidget {
  const _Connected();

  @override
  State<_Connected> createState() => _ConnectedState();
}

class _ConnectedState extends State<_Connected> {
  late final ServiceManagerClient _client = ServiceManagerClient();

  @override
  void dispose() {
    _client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FpDiInspector(client: _client);
}
