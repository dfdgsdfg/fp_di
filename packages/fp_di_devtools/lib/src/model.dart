// The models of the inspector protocol of fp_di. The protocol is a contract
// between the inspector of the same `version` and this app, so a parser reads
// only the fields that the app shows.

/// The format name of each answer and event.
const String protocolFormat = 'fp_di.devtools';

/// The protocol version that this app reads.
const int protocolVersion = 1;

/// A protocol answer or event with another `version` than
/// [protocolVersion], or a `format` that is not [protocolFormat].
final class ProtocolMismatch implements Exception {
  const ProtocolMismatch(this.found);

  /// The `version` of the answer, or null when it has none.
  final int? found;

  @override
  String toString() => 'ProtocolMismatch(found: $found)';
}

/// An error answer of the inspector.
final class InspectorError implements Exception {
  const InspectorError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Checks the `format` and the `version` of [answer] before any field is read.
///
/// Throws [ProtocolMismatch] for another version and [InspectorError] for an
/// error answer.
Map<String, Object?> checkAnswer(Map<String, Object?> answer) {
  final version = answer['version'];
  if (answer['format'] != protocolFormat ||
      version is! int ||
      version != protocolVersion) {
    throw ProtocolMismatch(version is int ? version : null);
  }
  final error = answer['error'];
  if (error != null) throw InspectorError('$error');
  return answer;
}

Map<String, Object?> _map(Object? value) =>
    value is Map ? Map<String, Object?>.from(value) : const {};

List<Object?> _list(Object? value) => value is List ? value : const [];

List<String> _strings(Object? value) => [
  for (final item in _list(value)) '$item',
];

List<int> _ints(Object? value) => [
  for (final item in _list(value))
    if (item is int) item,
];

/// A live root.
final class RootInfo {
  const RootInfo({
    required this.id,
    required this.label,
    required this.revision,
  });

  factory RootInfo.fromJson(Map<String, Object?> json) => RootInfo(
    id: json['id']! as int,
    label: '${json['label']}',
    revision: json['revision'] as int? ?? 0,
  );

  final int id;
  final String label;
  final int revision;
}

/// The failure that the state of a node names.
final class FailureInfo {
  const FailureInfo({
    required this.type,
    required this.message,
    required this.truncated,
  });

  factory FailureInfo.fromJson(Map<String, Object?> json) => FailureInfo(
    type: '${json['type']}',
    message: '${json['message']}',
    truncated: json['truncated'] == true,
  );

  final String type;
  final String message;

  /// Whether the inspector cut [message].
  final bool truncated;
}

/// The state of one node.
final class NodeInfo {
  const NodeInfo({
    required this.id,
    required this.label,
    required this.key,
    required this.phase,
    required this.missing,
    required this.failure,
    required this.commits,
    required this.origin,
    required this.value,
    required this.truncated,
  });

  factory NodeInfo.fromJson(Map<String, Object?> json) {
    final failure = json['failure'];
    return NodeInfo(
      id: json['id']! as int,
      label: '${json['label']}',
      key: json['key'] as String?,
      phase: '${json['phase']}',
      missing: _strings(json['missing']),
      failure: failure is Map
          ? FailureInfo.fromJson(Map<String, Object?>.from(failure))
          : null,
      commits: json['commits'] as int? ?? 0,
      origin: json['origin'] as String?,
      value: json['value'] as String?,
      truncated: json['truncated'] == true,
    );
  }

  final int id;
  final String label;
  final String? key;
  final String phase;
  final List<String> missing;
  final FailureInfo? failure;
  final int commits;
  final String? origin;

  /// The `toString()` of the value, only when the app was asked for values.
  final String? value;

  /// Whether the inspector cut [value].
  final bool truncated;
}

/// A scope with its nodes and its child scopes.
final class ScopeInfo {
  const ScopeInfo({
    required this.id,
    required this.phase,
    required this.module,
    required this.children,
    required this.nodes,
  });

  factory ScopeInfo.fromJson(Map<String, Object?> json) => ScopeInfo(
    id: json['id']! as int,
    phase: '${json['phase']}',
    module: json['module'] as String?,
    children: [
      for (final child in _list(json['children']))
        ScopeInfo.fromJson(_map(child)),
    ],
    nodes: [
      for (final node in _list(json['nodes'])) NodeInfo.fromJson(_map(node)),
    ],
  );

  final int id;
  final String phase;
  final String? module;
  final List<ScopeInfo> children;
  final List<NodeInfo> nodes;

  /// The name that a view shows for the scope.
  String get title => module ?? 'scope $id';

  /// This scope and its descendants, parents first.
  Iterable<ScopeInfo> get subtree sync* {
    yield this;
    for (final child in children) {
      yield* child.subtree;
    }
  }
}

/// One read of a node.
final class ReadInfo {
  const ReadInfo({
    required this.key,
    required this.kind,
    required this.resolves,
    required this.publisher,
    required this.members,
  });

  factory ReadInfo.fromJson(Map<String, Object?> json) => ReadInfo(
    key: '${json['key']}',
    kind: '${json['kind']}',
    resolves: json['resolves'] == true,
    publisher: json['publisher'] as int?,
    members: [
      for (final member in _list(json['members']))
        ReadInfo.fromJson(_map(member)),
    ],
  );

  final String key;

  /// `require`, `optional`, `collection`, `optionalCollection`, or `member`.
  final String kind;
  final bool resolves;

  /// The id of the node that publishes the key, or null.
  final int? publisher;

  /// The members of a collection read; each has the kind `member`.
  final List<ReadInfo> members;
}

/// A step in the search for an unavailable key.
final class CauseStep {
  const CauseStep({
    required this.node,
    required this.phase,
    required this.waitsFor,
  });

  factory CauseStep.fromJson(Map<String, Object?> json) => CauseStep(
    node: json['node']! as int,
    phase: '${json['phase']}',
    waitsFor: _strings(json['waitsFor']),
  );

  final int node;
  final String phase;
  final List<String> waitsFor;
}

/// The details of one node.
final class NodeDetails {
  const NodeDetails({
    required this.reads,
    required this.readers,
    required this.failureCause,
    required this.stackTrace,
    required this.cause,
    required this.value,
    required this.truncated,
  });

  factory NodeDetails.fromJson(Map<String, Object?> json) {
    final failure = _map(json['failure']);
    final cause = json['cause'];
    return NodeDetails(
      reads: [
        for (final read in _list(json['reads'])) ReadInfo.fromJson(_map(read)),
      ],
      readers: _ints(json['readers']),
      failureCause: failure['cause'] as String?,
      stackTrace: failure['stackTrace'] as String?,
      cause: cause is List
          ? [for (final step in cause) CauseStep.fromJson(_map(step))]
          : null,
      value: json['value'] as String?,
      truncated: json['truncated'] == true || failure['truncated'] == true,
    );
  }

  final List<ReadInfo> reads;

  /// The ids of the nodes that read this node.
  final List<int> readers;
  final String? failureCause;
  final String? stackTrace;

  /// The steps of the search for an unavailable key, or null.
  final List<CauseStep>? cause;
  final String? value;
  final bool truncated;
}

/// One member of a shape.
final class ShapeMember {
  const ShapeMember({
    required this.index,
    required this.label,
    required this.origin,
    required this.publishes,
    required this.contributesTo,
    required this.requires,
    required this.optional,
    required this.collections,
    required this.optionalCollections,
    required this.depth,
  });

  factory ShapeMember.fromJson(Map<String, Object?> json) => ShapeMember(
    index: json['index']! as int,
    label: '${json['label']}',
    origin: json['origin'] as String?,
    publishes: json['publishes'] as String?,
    contributesTo: json['contributesTo'] as String?,
    requires: _strings(json['requires']),
    optional: _strings(json['optional']),
    collections: _strings(json['collections']),
    optionalCollections: _strings(json['optionalCollections']),
    depth: json['depth'] as int? ?? 0,
  );

  final int index;
  final String label;
  final String? origin;
  final String? publishes;
  final String? contributesTo;
  final List<String> requires;
  final List<String> optional;
  final List<String> collections;
  final List<String> optionalCollections;
  final int depth;
}

/// The shape graph of one scope.
final class ShapeInfo {
  const ShapeInfo({
    required this.label,
    required this.members,
    required this.undeclared,
    required this.duplicates,
    required this.cycles,
    required this.longestChain,
    required this.ancestorLabels,
  });

  factory ShapeInfo.fromJson(Map<String, Object?> json) => ShapeInfo(
    label: json['label'] as String?,
    members: [
      for (final member in _list(json['members']))
        ShapeMember.fromJson(_map(member)),
    ],
    undeclared: _strings(json['undeclared']),
    duplicates: _strings(json['duplicates']),
    cycles: [for (final cycle in _list(json['cycles'])) _ints(cycle)],
    longestChain: _ints(json['longestChain']),
    ancestorLabels: _strings(_map(json['ancestors'])['labels']),
  );

  final String? label;
  final List<ShapeMember> members;
  final List<String> undeclared;
  final List<String> duplicates;

  /// Each cycle as member indexes.
  final List<List<int>> cycles;

  /// The member indexes of the longest chain of waits.
  final List<int> longestChain;
  final List<String> ancestorLabels;

  /// The members ordered by depth, then by index.
  List<ShapeMember> get byDepth => [...members]
    ..sort((a, b) {
      final byDepth = a.depth.compareTo(b.depth);
      return byDepth != 0 ? byDepth : a.index.compareTo(b.index);
    });

  String labelOf(int index) => index >= 0 && index < members.length
      ? members[index].label
      : 'member $index';
}

/// One changed node of a transition event.
final class NodeChange {
  const NodeChange({
    required this.node,
    required this.before,
    required this.after,
  });

  factory NodeChange.fromJson(Map<String, Object?> json) {
    final before = json['before'];
    final after = json['after'];
    return NodeChange(
      node: json['node']! as int,
      before: before is Map
          ? NodeInfo.fromJson(Map<String, Object?>.from(before))
          : null,
      after: after is Map
          ? NodeInfo.fromJson(Map<String, Object?>.from(after))
          : null,
    );
  }

  final int node;
  final NodeInfo? before;
  final NodeInfo? after;
}

/// The kind of a posted event, as the `extensionKind` of the VM service.
abstract final class EventKinds {
  static const String transition = 'fp_di:transition';
  static const String error = 'fp_di:error';
  static const String slowMutation = 'fp_di:slowMutation';
}

/// An event that the inspector posts.
sealed class InspectorEvent {
  const InspectorEvent(this.root);

  /// Parses [data] of the event [kind], or returns null for an unknown kind.
  ///
  /// Throws [ProtocolMismatch] for another version.
  static InspectorEvent? parse(String kind, Map<String, Object?> data) {
    switch (kind) {
      case EventKinds.transition:
        checkAnswer(data);
        return TransitionEvent(
          root: data['root']! as int,
          revision: data['revision'] as int? ?? 0,
          changed: [
            for (final change in _list(data['changed']))
              NodeChange.fromJson(_map(change)),
          ],
          omitted: data['omitted'] as int? ?? 0,
          truncated: data['truncated'] == true,
        );
      case EventKinds.error:
        checkAnswer(data);
        return ErrorEvent(
          root: data['root']! as int,
          type: '${data['type']}',
          message: '${data['message']}',
          stackTrace: data['stackTrace'] as String?,
          truncated: data['truncated'] == true,
        );
      case EventKinds.slowMutation:
        checkAnswer(data);
        return SlowMutationEvent(
          root: data['root']! as int,
          operation: '${data['operation']}',
          elapsedMs: data['elapsedMs'] as int? ?? 0,
          running: _strings(data['running']),
          ignoringCancellation: _strings(data['ignoringCancellation']),
          disposing: _strings(data['disposing']),
          queued: data['queued'] as int? ?? 0,
        );
    }
    return null;
  }

  final int root;
}

final class TransitionEvent extends InspectorEvent {
  const TransitionEvent({
    required int root,
    required this.revision,
    required this.changed,
    required this.omitted,
    required this.truncated,
  }) : super(root);

  final int revision;
  final List<NodeChange> changed;

  /// The number of changed nodes that the event leaves out.
  final int omitted;
  final bool truncated;
}

final class ErrorEvent extends InspectorEvent {
  const ErrorEvent({
    required int root,
    required this.type,
    required this.message,
    required this.stackTrace,
    required this.truncated,
  }) : super(root);

  final String type;
  final String message;
  final String? stackTrace;
  final bool truncated;
}

final class SlowMutationEvent extends InspectorEvent {
  const SlowMutationEvent({
    required int root,
    required this.operation,
    required this.elapsedMs,
    required this.running,
    required this.ignoringCancellation,
    required this.disposing,
    required this.queued,
  }) : super(root);

  final String operation;
  final int elapsedMs;
  final List<String> running;
  final List<String> ignoringCancellation;
  final List<String> disposing;
  final int queued;
}
