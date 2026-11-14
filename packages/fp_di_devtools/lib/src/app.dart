import 'package:flutter/material.dart';

import 'client.dart';
import 'controller.dart';
import 'details_view.dart';
import 'graph_view.dart';
import 'model.dart';
import 'nodes_view.dart';
import 'scope_tree_view.dart';
import 'timeline_view.dart';

/// The message when no debugged app is connected.
const String noConnectionMessage =
    'The fp_di extension needs a connected app. Run the app in debug mode '
    'and connect DevTools to it.';

/// The message when the app serves another protocol version.
String versionMessage(int? found) =>
    'The protocol version differs. This extension reads version '
    '$protocolVersion. The connected app serves version ${found ?? 'unknown'}.';

/// The views of the extension, on top of an [InspectorClient].
class FpDiInspector extends StatefulWidget {
  const FpDiInspector({required this.client, super.key});

  final InspectorClient client;

  @override
  State<FpDiInspector> createState() => _FpDiInspectorState();
}

class _FpDiInspectorState extends State<FpDiInspector> {
  late final InspectorController _controller = InspectorController(
    widget.client,
  )..start();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => switch (_controller.status) {
        ViewStatus.noConnection => const _Message(
          key: Key('no-connection'),
          text: noConnectionMessage,
        ),
        ViewStatus.versionMismatch => _Message(
          key: const Key('version-mismatch'),
          text: versionMessage(_controller.foundVersion),
        ),
        ViewStatus.connecting ||
        ViewStatus.ready => _Views(controller: _controller),
      },
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(text, textAlign: TextAlign.center),
      ),
    );
  }
}

class _Views extends StatelessWidget {
  const _Views({required this.controller});

  final InspectorController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Toolbar(controller: controller),
        if (controller.error case final error?)
          Material(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(error, key: const Key('error-banner')),
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: controller.status == ViewStatus.connecting
              ? const Center(
                  child: Text(
                    'Waiting for the fp_di inspector of the app.',
                    key: Key('connecting'),
                  ),
                )
              : Row(
                  children: [
                    SizedBox(
                      width: 300,
                      child: ScopeTreeView(controller: controller),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: _Tabs(controller: controller)),
                  ],
                ),
        ),
      ],
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.controller});

  final InspectorController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Text('fp_di', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          const Text('Show values'),
          Switch(
            key: const Key('values-toggle'),
            value: controller.showValues,
            onChanged: (value) => controller.setShowValues(value),
          ),
          IconButton(
            key: const Key('refresh'),
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh),
            onPressed: controller.refreshRoots,
          ),
        ],
      ),
    );
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs({required this.controller});

  final InspectorController controller;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const TabBar(
            tabs: [
              Tab(key: Key('tab-nodes'), text: 'Nodes'),
              Tab(key: Key('tab-graph'), text: 'Graph'),
              Tab(key: Key('tab-timeline'), text: 'Timeline'),
            ],
          ),
          Expanded(
            child: TabBarView(
              physics: const NeverScrollableScrollPhysics(),
              children: [
                Row(
                  children: [
                    Expanded(flex: 3, child: NodesView(controller: controller)),
                    const VerticalDivider(width: 1),
                    Expanded(
                      flex: 2,
                      child: DetailsView(controller: controller),
                    ),
                  ],
                ),
                GraphView(controller: controller),
                TimelineView(controller: controller),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
