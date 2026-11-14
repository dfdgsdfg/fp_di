import 'dart:convert';

import 'key.dart';
import 'module.dart';

/// The kind of a read that makes one member wait for another in
/// `initialize`.
///
/// {@category Observation}
enum ShapeEdgeKind {
  /// `Dependency.require` of a key that the target publishes.
  require,

  /// `Dependency.maybe` of a key that the target publishes.
  optional,

  /// A strict collection read of a set key that the target contributes to,
  /// or of a map key whose entry the target publishes.
  collection,

  /// An optional collection read of such a key.
  optionalCollection,
}

/// One member that waits for another member of the same module.
///
/// {@category Observation}
final class ShapeEdge {
  /// Creates the edge from the member [from] to the member [to].
  const ShapeEdge({
    required this.from,
    required this.to,
    required this.key,
    required this.kind,
  });

  /// The index of the waiting member.
  final int from;

  /// The index of the member that it waits for.
  final int to;

  /// The key of the read: the published key, or the collection key.
  final DiKeyBase key;

  /// The kind of the read that creates the edge.
  final ShapeEdgeKind kind;
}

/// The shape of a module as data, for review and analysis tools.
///
/// Build it with [ShapeGraph.of]; nothing is created and no `create` runs. It
/// states the structure of `initialize`: which member waits for which, how
/// deep each member sits, and one longest chain of members that must activate
/// one after another. It states no durations.
///
/// A tool script imports the application modules and this library and writes
/// [toJson] for each variant:
///
/// ```dart
/// import 'dart:io';
/// import 'package:fp_di/tooling.dart';
///
/// void main() => stdout.writeln(ShapeGraph.of(appModule()).toJson());
/// ```
///
/// {@category Observation}
final class ShapeGraph {
  ShapeGraph._({
    required this.module,
    required this.ancestorModules,
    required this.edges,
    required this.depths,
    required this.cycles,
    required this.longestChain,
    required this.undeclared,
    required this.duplicates,
  });

  /// The shape of [module] in a scope whose ancestors declare
  /// [ancestorModules], root first.
  ///
  /// The ancestors only decide which required keys are [undeclared]; the
  /// export lists no edge to an ancestor member, because `initialize` of the
  /// module does not wait for it.
  factory ShapeGraph.of(
    Module module, {
    List<Module> ancestorModules = const [],
  }) {
    final members = module.components;
    final count = members.length;

    final publishers = <DiKeyBase, List<int>>{};
    final contributors = <DiSetKey<Object?>, List<int>>{};
    final entries = <DiMapKey<Object?>, List<int>>{};
    for (var i = 0; i < count; i++) {
      final key = members[i].key;
      if (key != null) {
        publishers.putIfAbsent(key, () => <int>[]).add(i);
        if (key case DiMapEntryKey<Object?>(:final mapKey)) {
          entries.putIfAbsent(mapKey, () => <int>[]).add(i);
        }
      }
      final set = members[i].contributesTo;
      if (set != null) contributors.putIfAbsent(set, () => <int>[]).add(i);
    }

    final edges = <ShapeEdge>[];
    void connect(int from, DiKeyBase key, ShapeEdgeKind kind) {
      final targets = switch (key) {
        final DiSetKey<Object?> set => contributors[set],
        final DiMapKey<Object?> map => entries[map],
        _ => publishers[key],
      };
      for (final to in targets ?? const <int>[]) {
        if (to != from) {
          edges.add(ShapeEdge(from: from, to: to, key: key, kind: kind));
        }
      }
    }

    for (var i = 0; i < count; i++) {
      final member = members[i];
      for (final key in member.requires) {
        connect(i, key, ShapeEdgeKind.require);
      }
      for (final key in member.optional) {
        connect(i, key, ShapeEdgeKind.optional);
      }
      for (final key in member.collectionKeys) {
        connect(i, key, ShapeEdgeKind.collection);
      }
      for (final key in member.optionalCollectionKeys) {
        connect(i, key, ShapeEdgeKind.optionalCollection);
      }
    }

    final waitsFor = List<Set<int>>.generate(count, (_) => <int>{});
    for (final edge in edges) {
      waitsFor[edge.from].add(edge.to);
    }
    final components = _stronglyConnected(waitsFor);
    final componentOf = List<int>.filled(count, 0);
    for (var c = 0; c < components.length; c++) {
      for (final member in components[c]) {
        componentOf[member] = c;
      }
    }

    // Tarjan yields the components in reverse topological order: every
    // component that one waits for comes earlier.
    final componentDepth = List<int>.filled(components.length, 1);
    final next = List<int?>.filled(components.length, null);
    for (var c = 0; c < components.length; c++) {
      for (final member in components[c]) {
        for (final target in waitsFor[member]) {
          final d = componentOf[target];
          if (d == c) continue;
          if (componentDepth[d] + 1 > componentDepth[c]) {
            componentDepth[c] = componentDepth[d] + 1;
            next[c] = d;
          }
        }
      }
    }
    var deepest = 0;
    for (var c = 1; c < components.length; c++) {
      if (componentDepth[c] > componentDepth[deepest]) deepest = c;
    }
    final chain = <int>[];
    for (int? c = components.isEmpty ? null : deepest; c != null; c = next[c]) {
      chain.add(components[c].reduce((a, b) => a < b ? a : b));
    }

    final declared = <DiKeyBase>{
      for (final ancestor in ancestorModules) ...ancestor.publishes,
    };
    return ShapeGraph._(
      module: module,
      ancestorModules: List<Module>.unmodifiable(ancestorModules),
      edges: List<ShapeEdge>.unmodifiable(edges),
      depths: List<int>.unmodifiable([
        for (var i = 0; i < count; i++) componentDepth[componentOf[i]],
      ]),
      cycles: List<List<int>>.unmodifiable([
        for (final component in components)
          if (component.length > 1)
            List<int>.unmodifiable(component.toList()..sort()),
      ]),
      longestChain: List<int>.unmodifiable(chain.reversed),
      undeclared: List<DiKeyBase>.unmodifiable([
        for (final key in module.requires)
          if (!declared.contains(key)) key,
      ]),
      duplicates: List<DiKeyBase>.unmodifiable([
        for (final MapEntry(:key, :value) in publishers.entries)
          if (value.length > 1) key,
      ]),
    );
  }

  /// The module whose shape this is.
  final Module module;

  /// The modules of the ancestor scopes, root first.
  final List<Module> ancestorModules;

  /// Each wait of a member for another member, in declaration order of the
  /// waiting member.
  final List<ShapeEdge> edges;

  /// The depth of each member, by index: 1 for a member that waits for no
  /// member of the module, otherwise one more than the deepest member it
  /// waits for. Members of one cycle share a depth.
  final List<int> depths;

  /// The members that wait for each other in a cycle, each sorted.
  final List<List<int>> cycles;

  /// One longest chain of members that wait for each other, first to
  /// activate first. A cycle on the chain appears as its first member.
  final List<int> longestChain;

  /// The required keys that neither the module nor an ancestor publishes:
  /// `initialize` would throw `UndeclaredKeyError` for them.
  final List<DiKeyBase> undeclared;

  /// The keys that more than one member publishes: `initialize` would throw
  /// `DuplicateKeyError` for them.
  final List<DiKeyBase> duplicates;

  /// The format name of [toJsonObject].
  static const format = 'fp_di.shape';

  /// The version of [toJsonObject]. A new field keeps it; a changed or
  /// removed field changes it.
  static const version = 1;

  /// The shape as a JSON value. Keys appear as their text.
  Map<String, Object?> toJsonObject() {
    List<String> keys(Iterable<DiKeyBase> keys) => [
      for (final key in keys) '$key',
    ];
    final members = module.components;
    return <String, Object?>{
      'format': format,
      'version': version,
      'label': module.debugLabel,
      'members': [
        for (var i = 0; i < members.length; i++)
          <String, Object?>{
            'index': i,
            'label': members[i].label,
            'origin': module.origins[i],
            'publishes': members[i].key?.toString(),
            'contributesTo': members[i].contributesTo?.toString(),
            'requires': keys(members[i].requires),
            'optional': keys(members[i].optional),
            'collections': keys(members[i].collectionKeys),
            'optionalCollections': keys(members[i].optionalCollectionKeys),
            'depth': depths[i],
          },
      ],
      'edges': [
        for (final edge in edges)
          <String, Object?>{
            'from': edge.from,
            'to': edge.to,
            'key': '${edge.key}',
            'kind': edge.kind.name,
          },
      ],
      'publishes': keys(module.publishes),
      'requires': keys(module.requires),
      'reads': keys(module.reads),
      'contributes': <String, int>{
        for (final MapEntry(:key, :value) in module.contributes.entries)
          '$key': value,
      },
      'ancestors': <String, Object?>{
        'labels': [for (final ancestor in ancestorModules) ancestor.debugLabel],
        'publishes': keys({for (final a in ancestorModules) ...a.publishes}),
      },
      'undeclared': keys(undeclared),
      'duplicates': keys(duplicates),
      'cycles': cycles,
      'longestChain': longestChain,
    };
  }

  /// The shape as indented JSON text.
  String toJson() => const JsonEncoder.withIndent('  ').convert(toJsonObject());

  /// The members and the [edges] as the text of a Mermaid `flowchart`, for a
  /// reader.
  ///
  /// Each member is one node with its label. Node `m3` is the member with
  /// index 3. An arrow points from a member to a member
  /// that it waits for, and the chart grows upward, so a member that waits for
  /// nothing is at the top. The line states the kind of the read:
  ///
  /// | Kind | Line |
  /// |---|---|
  /// | `require` | `-->` |
  /// | `optional` | `-.->` |
  /// | `collection` | `==>`, with the collection key |
  /// | `optionalCollection` | `-.->`, with the collection key |
  ///
  /// With [ancestorModules], each scope is one `subgraph` with the label of its
  /// module. The subgraph of an ancestor holds only the members that answer a
  /// read of this module: node `s0m2` is member 2 of the root. An arrow into
  /// such a subgraph is a read that crosses the scope boundary. `initialize`
  /// of the module does not wait for that member, so [edges] does not list
  /// the read. The arrow goes to the nearest scope that declares a publisher;
  /// a collection read goes to its members in every ancestor.
  ///
  /// The members of one origin are one `subgraph` with that label, inside the
  /// subgraph of their scope, so a module composed with `Module.all` shows
  /// its parts. A member without an origin, or with the label of the module
  /// itself, is outside such a subgraph. See `Module.origins`.
  ///
  /// With [collapsed], the chart has one node for each origin instead of
  /// one for each member, for a module that is too large to read member by
  /// member. The members of a scope without such a subgraph are one node with
  /// the label of the scope. A node states the number of its members. An
  /// arrow joins two nodes whose members read each other, with the number of
  /// those reads; the line is dotted when all of them are optional. A read
  /// inside one node has no arrow.
  ///
  /// The text is a view of the shape, not a format: it has no version, it
  /// leaves out [undeclared], [duplicates], [cycles], [depths], and
  /// [longestChain], and a later release can draw it differently. A tool
  /// reads [toJson].
  String toMermaid({bool collapsed = false}) {
    final members = module.components;
    final own = [for (var i = 0; i < members.length; i++) i];

    // The reads that an ancestor answers, and the members that answer them.
    final answering = [for (final _ in ancestorModules) <int>{}];
    final crossing =
        <({int from, int scope, int to, DiKeyBase key, ShapeEdgeKind kind})>[];
    for (var i = 0; i < members.length; i++) {
      void connect(DiKeyBase key, ShapeEdgeKind kind) {
        for (final (scope, to) in _ancestorTargets(key)) {
          answering[scope].add(to);
          crossing.add((from: i, scope: scope, to: to, key: key, kind: kind));
        }
      }

      final member = members[i];
      for (final key in member.requires) {
        connect(key, ShapeEdgeKind.require);
      }
      for (final key in member.optional) {
        connect(key, ShapeEdgeKind.optional);
      }
      for (final key in member.collectionKeys) {
        connect(key, ShapeEdgeKind.collection);
      }
      for (final key in member.optionalCollectionKeys) {
        connect(key, ShapeEdgeKind.optionalCollection);
      }
    }
    final drawn = [for (final members in answering) members.toList()..sort()];
    String title(int scope) =>
        (scope < ancestorModules.length ? ancestorModules[scope] : module)
            .debugLabel ??
        'scope $scope';

    final List<String> Function(int scope, String indent) nodes;
    final List<String> lines;
    if (collapsed) {
      final parts = [
        for (var scope = 0; scope < ancestorModules.length; scope++)
          _MermaidParts(
            ancestorModules[scope],
            drawn[scope],
            prefix: 's$scope',
            rest: title(scope),
          ),
        _MermaidParts(
          module,
          own,
          prefix: '',
          rest: title(ancestorModules.length),
        ),
      ];
      nodes = (scope, indent) => parts[scope].lines(indent);
      // The reads between two nodes, in the order of the first read.
      final reads = <(String, String), int>{};
      final strict = <(String, String)>{};
      void count(String from, String to, ShapeEdgeKind kind) {
        if (from == to) return;
        reads[(from, to)] = (reads[(from, to)] ?? 0) + 1;
        if (kind == ShapeEdgeKind.require || kind == ShapeEdgeKind.collection) {
          strict.add((from, to));
        }
      }

      for (final edge in edges) {
        count(parts.last.idOf(edge.from), parts.last.idOf(edge.to), edge.kind);
      }
      for (final read in crossing) {
        count(
          parts.last.idOf(read.from),
          parts[read.scope].idOf(read.to),
          read.kind,
        );
      }
      lines = [
        for (final MapEntry(key: (from, to), value: number) in reads.entries)
          '  $from ${strict.contains((from, to)) ? '-->' : '-.->'}'
              '|"$number"| $to',
      ];
    } else {
      nodes = (scope, indent) => scope < ancestorModules.length
          ? _mermaidNodes(
              ancestorModules[scope],
              drawn[scope],
              prefix: 's$scope',
              indent: indent,
            )
          : _mermaidNodes(module, own, prefix: '', indent: indent);
      String line(String from, ShapeEdgeKind kind, DiKeyBase key, String to) =>
          switch (kind) {
            ShapeEdgeKind.require => '  $from --> $to',
            ShapeEdgeKind.optional => '  $from -.-> $to',
            ShapeEdgeKind.collection =>
              '  $from ==>|"${_mermaidText('$key')}"| $to',
            ShapeEdgeKind.optionalCollection =>
              '  $from -.->|"${_mermaidText('$key')}"| $to',
          };
      lines = [
        for (final edge in edges)
          line('m${edge.from}', edge.kind, edge.key, 'm${edge.to}'),
        for (final read in crossing)
          line(
            'm${read.from}',
            read.kind,
            read.key,
            's${read.scope}m${read.to}',
          ),
      ];
    }

    if (ancestorModules.isEmpty) {
      return ['flowchart BT', ...nodes(0, '  '), ...lines].join('\n');
    }
    return [
      'flowchart BT',
      for (var scope = 0; scope <= ancestorModules.length; scope++)
        if (scope == ancestorModules.length || drawn[scope].isNotEmpty) ...[
          '  subgraph s$scope["${_mermaidText(title(scope))}"]',
          ...nodes(scope, '    '),
          '  end',
        ],
      ...lines,
    ].join('\n');
  }

  /// The ancestor members that answer a read of [key] from the module, each
  /// as the index of its scope in [ancestorModules] and its member index.
  ///
  /// A plain key and each entry of a map key go to the nearest scope that
  /// declares a publisher, so the module itself comes first. A set key goes
  /// to its contributors in every ancestor.
  Iterable<(int, int)> _ancestorTargets(DiKeyBase key) sync* {
    if (key is DiSetKey<Object?>) {
      for (var scope = 0; scope < ancestorModules.length; scope++) {
        final members = ancestorModules[scope].components;
        for (var to = 0; to < members.length; to++) {
          if (members[to].contributesTo == key) yield (scope, to);
        }
      }
      return;
    }
    final declared = <DiKeyBase>{...module.publishes};
    for (var scope = ancestorModules.length - 1; scope >= 0; scope--) {
      final members = ancestorModules[scope].components;
      final found = <DiKeyBase>{};
      for (var to = 0; to < members.length; to++) {
        final published = members[to].key;
        final matches = key is DiMapKey<Object?>
            ? published is DiMapEntryKey<Object?> && published.mapKey == key
            : published == key;
        if (matches && !declared.contains(published)) {
          found.add(published!);
          yield (scope, to);
        }
      }
      declared.addAll(found);
    }
  }
}

/// The label of the subgraph of member [index] of [module], or null for a
/// member outside such a subgraph.
///
/// The label of the module itself is the origin of a member that the module
/// lists directly, so it makes no subgraph: the subgraph of the scope has it.
String? _mermaidPart(Module module, int index) {
  final origin = module.origins[index];
  return origin == module.debugLabel ? null : origin;
}

/// The node lines of the members [indexes] of [module], in declaration order.
///
/// The members of one origin follow the others, as one `subgraph` for each
/// origin, in the order in which the origins first appear.
List<String> _mermaidNodes(
  Module module,
  Iterable<int> indexes, {
  required String prefix,
  required String indent,
}) {
  String node(int i) =>
      '${prefix}m$i["${_mermaidText(module.components[i].label)}"]';
  final lines = <String>[];
  final parts = <String, List<int>>{};
  for (final i in indexes) {
    final part = _mermaidPart(module, i);
    if (part == null) {
      lines.add('$indent${node(i)}');
    } else {
      parts.putIfAbsent(part, () => <int>[]).add(i);
    }
  }
  var number = 0;
  for (final MapEntry(:key, :value) in parts.entries) {
    lines
      ..add('${indent}subgraph ${prefix}g$number["${_mermaidText(key)}"]')
      ..addAll([for (final i in value) '$indent  ${node(i)}'])
      ..add('${indent}end');
    number++;
  }
  return lines;
}

/// The nodes of a collapsed chart for the members [drawn] of [module].
///
/// The node of an origin has the id that its subgraph has in the full chart,
/// `<prefix>g<k>`. The members outside such a subgraph are the node
/// `<prefix>r` with the label [rest].
final class _MermaidParts {
  _MermaidParts(
    this.module,
    Iterable<int> drawn, {
    required this.prefix,
    required this.rest,
  }) {
    for (final i in drawn) {
      final part = _mermaidPart(module, i);
      if (part == null) {
        _hasRest = true;
      } else {
        _ids.putIfAbsent(part, () => '${prefix}g${_ids.length}');
      }
    }
  }

  final Module module;
  final String prefix;
  final String rest;
  final _ids = <String, String>{};
  var _hasRest = false;

  /// The id of the node that holds member [index].
  String idOf(int index) {
    final part = _mermaidPart(module, index);
    return part == null ? '${prefix}r' : _ids[part]!;
  }

  /// One line for each node. A node states every member of its origin in the
  /// module, also the members that are not drawn.
  List<String> lines(String indent) {
    String node(String id, String label, String? part) {
      var members = 0;
      for (var i = 0; i < module.components.length; i++) {
        if (_mermaidPart(module, i) == part) members++;
      }
      return '$indent$id["${_mermaidText(label)}<br/>'
          '$members ${members == 1 ? 'member' : 'members'}"]';
    }

    return [
      if (_hasRest) node('${prefix}r', rest, null),
      for (final MapEntry(:key, :value) in _ids.entries) node(value, key, key),
    ];
  }
}

/// [text] for a quoted Mermaid label. Mermaid reads `#name;` as a character
/// reference, so the characters that end the label or start markup become
/// references.
String _mermaidText(String text) {
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    buffer.write(switch (rune) {
      0x22 => '#quot;',
      0x23 => '#35;',
      0x26 => '#amp;',
      0x3C => '#lt;',
      0x3E => '#gt;',
      0x60 => '#96;',
      0x0A => '<br/>',
      0x0D => '',
      _ => String.fromCharCode(rune),
    });
  }
  return buffer.toString();
}

/// The strongly connected components of [edges], in reverse topological
/// order (Tarjan). An edge `i → j` means that `i` waits for `j`.
List<List<int>> _stronglyConnected(List<Set<int>> edges) {
  final count = edges.length;
  final index = List<int?>.filled(count, null);
  final low = List<int>.filled(count, 0);
  final onStack = List<bool>.filled(count, false);
  final stack = <int>[];
  final result = <List<int>>[];
  var next = 0;

  void visit(int v) {
    index[v] = next;
    low[v] = next;
    next++;
    stack.add(v);
    onStack[v] = true;
    for (final w in edges[v]) {
      if (index[w] == null) {
        visit(w);
        if (low[w] < low[v]) low[v] = low[w];
      } else if (onStack[w] && index[w]! < low[v]) {
        low[v] = index[w]!;
      }
    }
    if (low[v] == index[v]) {
      final component = <int>[];
      int w;
      do {
        w = stack.removeLast();
        onStack[w] = false;
        component.add(w);
      } while (w != v);
      result.add(component);
    }
  }

  for (var v = 0; v < count; v++) {
    if (index[v] == null) visit(v);
  }
  return result;
}
