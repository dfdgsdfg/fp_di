// The text of `Scope.describe`. The rule reads the views of `core_graph.dart`
// and returns the text.
import '../model/key.dart';
import 'core_graph.dart';
import 'core_node.dart';

/// A text that lists each node of [root] and its descendants, for
/// diagnostics. [nodes] holds the nodes of the runtime, and [holdLabels] the
/// labels of the open holds of a scope and its descendants.
///
/// A scope that is not initialized lists its declared components with the
/// state `declared`. While `initialize` runs, a component that has a node
/// shows the state of the node instead. A child scope is indented below its
/// parent.
String coreDescribe<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(
  S root,
  Iterable<CoreNode<S, P, N>> nodes,
  List<String> Function(S scope) holdLabels,
) {
  final lines = <String>[];
  void write(S scope, String path, int depth) {
    final indent = '  ' * depth;
    final title = path.isEmpty ? 'scope' : '${indent}child scope $path';
    var heading = scope.initialized ? title : '$title (not initialized)';
    if (scope.waitsForHolds) {
      final labels = holdLabels(scope);
      final count = labels.length == 1 ? '1 hold' : '${labels.length} holds';
      heading = '$heading (disposal waits for $count: ${labels.join(', ')})';
    }
    lines.add(heading);
    String entryOf(CoreNode<S, P, N> node) {
      final parts = <String>[coreStateWord(coreNodePhase(node))];
      final missing = coreMissingOf(node);
      if (missing.isNotEmpty) parts.add('missing ${missing.join(', ')}');
      if (node.contributionSet case final set?) {
        parts.add('contributes to $set');
      }
      return '$indent  - ${coreDescribedLabel(node.label, node.publicKey)}: '
          '${parts.join('; ')}';
    }

    final scopeNodes = [
      for (final node in nodes)
        if (identical(node.scope, scope)) node,
    ];
    if (scope.initialized) {
      lines.addAll(scopeNodes.map(entryOf));
    } else {
      // A running `initialize` has created nodes. Each component has one
      // entry: its node, or `declared` when it has no node.
      final created = <int, CoreNode<S, P, N>>{
        for (final node in scopeNodes) node.declarationIndex: node,
      };
      final components = scope.declared.components;
      for (var i = 0; i < components.length; i++) {
        final node = created[i];
        final label = coreDescribedLabel(
          components[i].label,
          components[i].key,
        );
        lines.add(node == null ? '$indent  - $label: declared' : entryOf(node));
      }
    }
    var index = 0;
    for (final child in scope.children) {
      index++;
      write(child, path.isEmpty ? '$index' : '$path.$index', depth + 1);
    }
  }

  write(root, '', 0);
  return lines.join('\n');
}

/// The label of a member in `describe`, followed by its key when the label
/// is not the key.
String coreDescribedLabel(String label, DiKeyBase? key) =>
    key == null || label == '$key' ? label : '$label ($key)';
