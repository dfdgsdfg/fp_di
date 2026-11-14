import 'package:flutter/material.dart';

import 'controller.dart';
import 'model.dart';
import 'phase.dart';

/// The roots, and the scope tree of the selected root, with the phase of each
/// scope.
class ScopeTreeView extends StatelessWidget {
  const ScopeTreeView({required this.controller, super.key});

  final InspectorController controller;

  @override
  Widget build(BuildContext context) {
    final roots = controller.roots;
    if (roots.isEmpty) {
      return const Center(
        key: Key('no-roots'),
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Text('The app has no fp_di root yet.'),
        ),
      );
    }
    return ListView(
      children: [
        for (final root in roots) ...[
          _RootRow(
            root: root,
            selected: root.id == controller.selectedRoot,
            onTap: () => controller.selectRoot(root.id),
          ),
          if (root.id == controller.selectedRoot && controller.tree != null)
            ..._scopeRows(controller.tree!, 1),
        ],
      ],
    );
  }

  List<Widget> _scopeRows(ScopeInfo scope, int depth) => [
    InkWell(
      key: Key('scope-${scope.id}'),
      onTap: () => controller.selectScope(scope.id),
      child: ColoredBox(
        color: scope.id == controller.selectedScope
            ? Colors.blue.withValues(alpha: 0.12)
            : Colors.transparent,
        child: Padding(
          padding: EdgeInsets.fromLTRB(12.0 + 16 * depth, 6, 8, 6),
          child: Row(
            children: [
              Flexible(
                child: Text(scope.title, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              PhaseChip(scope.phase),
            ],
          ),
        ),
      ),
    ),
    for (final child in scope.children) ..._scopeRows(child, depth + 1),
  ];
}

class _RootRow extends StatelessWidget {
  const _RootRow({
    required this.root,
    required this.selected,
    required this.onTap,
  });

  final RootInfo root;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: Key('root-${root.id}'),
      onTap: onTap,
      child: ColoredBox(
        color: selected
            ? Colors.blue.withValues(alpha: 0.12)
            : Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Icon(Icons.account_tree, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  root.label,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text('rev ${root.revision}'),
            ],
          ),
        ),
      ),
    );
  }
}
