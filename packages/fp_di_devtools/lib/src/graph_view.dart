import 'package:flutter/material.dart';

import 'controller.dart';
import 'model.dart';
import 'phase.dart';

/// The shape graph of the selected scope: the members in depth order, each
/// colored by the phase of its node, with the cycles, the longest chain, and
/// the undeclared and duplicate keys.
class GraphView extends StatelessWidget {
  const GraphView({required this.controller, super.key});

  final InspectorController controller;

  @override
  Widget build(BuildContext context) {
    final scope = controller.scope;
    final shape = controller.shape;
    if (scope == null) {
      return const Center(child: Text('Select a scope.'));
    }
    if (shape == null) {
      return const Center(
        key: Key('no-shape'),
        child: Text('The shape of the scope is not loaded.'),
      );
    }
    final phases = memberPhases(shape, scope);
    final heading = Theme.of(context).textTheme.titleSmall;
    final depths = <int, List<ShapeMember>>{};
    for (final member in shape.byDepth) {
      depths.putIfAbsent(member.depth, () => []).add(member);
    }
    return ListView(
      key: const Key('graph'),
      padding: const EdgeInsets.all(12),
      children: [
        Text(
          'Shape of ${shape.label ?? scope.title}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (shape.ancestorLabels.isNotEmpty)
          Text('Ancestor modules: ${shape.ancestorLabels.join(', ')}'),
        const SizedBox(height: 8),
        for (final MapEntry(key: depth, value: members) in depths.entries) ...[
          Text('Depth $depth', style: heading),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final member in members)
                _MemberCard(member: member, phase: phases[member.index]),
            ],
          ),
          const SizedBox(height: 12),
        ],
        Text('Longest chain', style: heading),
        Text(
          shape.longestChain.isEmpty
              ? 'none'
              : shape.longestChain.map(shape.labelOf).join(' → '),
          key: const Key('longest-chain'),
        ),
        const SizedBox(height: 8),
        Text('Cycles', style: heading),
        if (shape.cycles.isEmpty)
          const Text('none', key: Key('no-cycles'))
        else
          for (final cycle in shape.cycles)
            Text(
              [...cycle, cycle.first].map(shape.labelOf).join(' → '),
              key: const Key('cycle'),
            ),
        const SizedBox(height: 8),
        Text('Undeclared keys', style: heading),
        _KeyList(shape.undeclared, const Key('undeclared')),
        const SizedBox(height: 8),
        Text('Duplicate keys', style: heading),
        _KeyList(shape.duplicates, const Key('duplicates')),
      ],
    );
  }
}

/// The phase of the node of each member of [shape], by member index.
///
/// The `index` of a member is its position in the module of the scope, and
/// the `state` answer lists the nodes of the scope in the same order. A scope
/// has no nodes before `initialize`, so a member without a node is absent
/// from the result.
Map<int, String> memberPhases(ShapeInfo shape, ScopeInfo scope) => {
  for (final member in shape.members)
    if (member.index >= 0 && member.index < scope.nodes.length)
      member.index: scope.nodes[member.index].phase,
};

class _KeyList extends StatelessWidget {
  const _KeyList(this.keys, this.widgetKey);

  final List<String> keys;
  final Key widgetKey;

  @override
  Widget build(BuildContext context) {
    if (keys.isEmpty) return Text('none', key: widgetKey);
    return Column(
      key: widgetKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final key in keys) Text(key, style: monospace)],
    );
  }
}

class _MemberCard extends StatelessWidget {
  const _MemberCard({required this.member, required this.phase});

  final ShapeMember member;
  final String? phase;

  @override
  Widget build(BuildContext context) {
    final color = phase == null ? Colors.grey : phaseColor(phase!);
    final waits = [
      ...member.requires,
      for (final key in member.optional) '$key (optional)',
      for (final key in member.collections) '$key (collection)',
      for (final key in member.optionalCollections)
        '$key (optional collection)',
    ];
    return Container(
      key: Key('member-${member.index}'),
      width: 240,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color, width: 2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  member.label,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 6),
              if (phase != null)
                PhaseChip(phase!)
              else
                const Text('no node', style: TextStyle(color: Colors.grey)),
            ],
          ),
          if (member.publishes != null)
            Text('publishes ${member.publishes}', style: monospace),
          if (member.contributesTo != null)
            Text('contributes to ${member.contributesTo}', style: monospace),
          for (final key in waits) Text('waits for $key', style: monospace),
        ],
      ),
    );
  }
}
