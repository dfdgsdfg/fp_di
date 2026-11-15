// Internal types. The library file does not export this file.

/// The identity of a node.
///
/// The runtime creates the ids from one counter, so the id is the ordering
/// key of the lifecycle: ascending order is the order of activation, and
/// descending order is the order of release.
extension type const NodeId(int value) {}

/// The identity of a scope. The runtime creates the ids from one counter.
extension type const ScopeId(int value) {}

/// The identity of one commit of one node.
///
/// A commit of the same node a second time is a new publisher identity, so a
/// reader of the first commit sees a changed target.
final class PublisherRef {
  /// Creates the identity of the commit number [commit] of [node].
  const PublisherRef(this.node, this.commit);

  /// The node that published the value.
  final NodeId node;

  /// The number of the commit of [node], counted from one.
  final int commit;

  @override
  bool operator ==(Object other) =>
      other is PublisherRef && other.node == node && other.commit == commit;

  @override
  int get hashCode => Object.hash(PublisherRef, node.value, commit);

  @override
  String toString() => 'PublisherRef(${node.value}#$commit)';
}
