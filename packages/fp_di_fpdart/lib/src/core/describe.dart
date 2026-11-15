// Internal functions. The library file does not export this file.
import 'ids.dart';
import 'queries.dart';
import 'runtime_state.dart';
import 'snapshots.dart';

/// A text that lists each node of the scope [id] and of its descendants, for
/// diagnostics.
///
/// Each node entry states its label, its state (`active`, `activating`,
/// `deactivating`, `waiting`, `activation failed`, `dispose failed`, or
/// `inactive`), and the required keys that do not resolve. A scope that is not
/// initialized shows `(not initialized)` in its heading, and lists each
/// component once: the entry of its node, or `declared` when it has no live
/// node. A child scope is indented below its parent, with its path.
///
/// The format is for people and can change. Do not parse it.
String describeScope(RuntimeState s, ScopeId id) {
  final lines = <String>[];

  String labeled(String label, Object? key) =>
      key == null || label == '$key' ? label : '$label ($key)';

  void write(ScopeId at, String path, int depth) {
    final record = scopeRecord(s, at);
    final indent = '  ' * depth;
    final title = path.isEmpty ? 'scope' : '${indent}child scope $path';
    lines.add(record.initialized ? title : '$title (not initialized)');

    String entryOf(NodeId n) {
      final state = nodeState(s, n);
      final parts = [stateWord(state.phase)];
      if (state.missing.isNotEmpty) {
        parts.add('missing ${state.missing.join(', ')}');
      }
      final key = state.key.toNullable();
      return '$indent  - ${labeled(state.label, key)}: ${parts.join('; ')}';
    }

    bool live(NodeId n) => !nodeRecord(s, n).removed;
    if (record.initialized) {
      lines.addAll([
        for (final n in record.nodes)
          if (live(n)) entryOf(n),
      ]);
    } else {
      // A running run has created nodes. Each component has one entry: its
      // node, or `declared` when it has no live node.
      for (var i = 0; i < record.components.length; i++) {
        final component = record.components[i];
        final node = i < record.nodes.length && live(record.nodes[i])
            ? record.nodes[i]
            : null;
        final key = component.isEffect ? null : component.key;
        final label = labeled(component.label, key);
        lines.add(node == null ? '$indent  - $label: declared' : entryOf(node));
      }
    }
    var index = 0;
    for (final child in record.children) {
      index++;
      write(child, path.isEmpty ? '$index' : '$path.$index', depth + 1);
    }
  }

  write(id, '', 0);
  return lines.join('\n');
}
