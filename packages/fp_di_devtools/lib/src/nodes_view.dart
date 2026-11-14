import 'package:flutter/material.dart';

import 'controller.dart';
import 'model.dart';
import 'phase.dart';

/// The nodes of the selected scope, with a filter by phase and a search by
/// key.
class NodesView extends StatelessWidget {
  const NodesView({required this.controller, super.key});

  final InspectorController controller;

  @override
  Widget build(BuildContext context) {
    final scope = controller.scope;
    if (scope == null) {
      return const Center(child: Text('Select a scope.'));
    }
    final nodes = controller.filteredNodes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 220,
                child: TextField(
                  key: const Key('key-search'),
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 18),
                    hintText: 'Search by key',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: controller.setSearch,
                ),
              ),
              ChoiceChip(
                key: const Key('phase-all'),
                label: const Text('all'),
                selected: controller.phaseFilter == null,
                onSelected: (_) => controller.setPhaseFilter(null),
              ),
              for (final phase in controller.phasesInScope)
                ChoiceChip(
                  key: Key('phase-$phase'),
                  label: Text(phase),
                  selected: controller.phaseFilter == phase,
                  onSelected: (_) => controller.setPhaseFilter(phase),
                ),
            ],
          ),
        ),
        _Row(
          header: true,
          values: controller.showValues,
          cells: const [
            'label',
            'key',
            'phase',
            'missing',
            'commits',
            'origin',
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: nodes.isEmpty
              ? const Center(
                  key: Key('no-nodes'),
                  child: Text('No node matches.'),
                )
              : ListView.builder(
                  itemCount: nodes.length,
                  itemBuilder: (context, index) {
                    final node = nodes[index];
                    return _NodeRow(
                      node: node,
                      selected: node.id == controller.selectedNode,
                      values: controller.showValues,
                      onTap: () => controller.selectNode(node.id),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _NodeRow extends StatelessWidget {
  const _NodeRow({
    required this.node,
    required this.selected,
    required this.values,
    required this.onTap,
  });

  final NodeInfo node;
  final bool selected;
  final bool values;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: Key('node-${node.id}'),
      onTap: onTap,
      child: ColoredBox(
        color: selected
            ? Colors.blue.withValues(alpha: 0.12)
            : Colors.transparent,
        child: _Row(
          header: false,
          values: values,
          cells: [
            node.label,
            node.key ?? '(contribution)',
            node.phase,
            node.missing.join(', '),
            '${node.commits}',
            node.origin ?? '',
          ],
          value: node.value == null
              ? ''
              : node.truncated
              ? '${node.value} (cut)'
              : node.value!,
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.header,
    required this.values,
    required this.cells,
    this.value = 'value',
  });

  final bool header;
  final bool values;
  final List<String> cells;
  final String value;

  @override
  Widget build(BuildContext context) {
    const flex = [2, 4, 2, 3, 1, 2];
    final style = header
        ? const TextStyle(fontWeight: FontWeight.bold)
        : const TextStyle();
    Widget cell(int i) {
      final text = cells[i];
      final child = !header && i == 2
          ? Align(alignment: Alignment.centerLeft, child: PhaseChip(text))
          : Text(text, style: style, overflow: TextOverflow.ellipsis);
      return Expanded(flex: flex[i], child: child);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          for (var i = 0; i < cells.length; i++) ...[
            cell(i),
            const SizedBox(width: 8),
          ],
          if (values)
            Expanded(
              flex: 3,
              child: Text(value, style: style, overflow: TextOverflow.ellipsis),
            ),
        ],
      ),
    );
  }
}
