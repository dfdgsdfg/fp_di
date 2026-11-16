// The read-only views that the pure rules of `core/` read. The runtime
// classes implement them and keep their fields, so a rule reads the object
// graph in place and a change costs constant time. A rule never changes a
// view.
import '../model/exception.dart';
import '../model/key.dart';
import '../model/module.dart';
import '../model/state.dart';

/// A scope as the rules read it.
///
/// The type arguments name the classes of one graph: the scope [S], its
/// publishers [P], and its nodes [N].
abstract interface class CoreScope<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
> {
  /// The scope above, or null for the root.
  S? get parent;

  /// The scopes below.
  Iterable<S> get children;

  /// The components that `initialize` creates.
  Module get declared;

  /// The internal contribution key of each declared set contribution, by
  /// declaration index, or null for another component.
  List<DiKeyBase?> get contributionKeys;

  /// The declaration index of the component that publishes a key, and of the
  /// set contribution that has a contribution key.
  Map<DiKeyBase, int> get declarationIndexes;

  /// The nodes in declaration order, empty before `initialize` creates them.
  List<N> get nodes;

  /// The phase that the last transition stored.
  ScopePhase get phase;

  /// Whether `initialize` completed.
  bool get initialized;

  /// Whether `initialize` runs now.
  bool get initializing;

  /// Whether `dispose` was called for this scope and its mutation has not
  /// finished.
  bool get disposeRequested;

  /// Whether the disposal mutation of this scope runs.
  bool get disposing;

  /// Whether the disposal of this scope released its nodes.
  bool get disposed;

  /// Whether a requested disposal waits for holds.
  bool get waitsForHolds;

  /// The number of open holds of this scope alone.
  int get holdCount;

  /// The publisher that this scope binds to [key], or null.
  P? bindingOf(DiKeyBase key);
}

/// A publisher as the rules read it.
abstract interface class CorePublisher<N extends Object> {
  /// Whether the publisher still resolves.
  bool get available;

  /// The node that published the value.
  N get owner;

  /// The nodes that read the value.
  Iterable<N> get dependents;
}

/// A node as the rules read it.
abstract interface class CoreNode<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
> {
  /// The creation order of the node in its runtime.
  int get id;

  /// The name of the node in diagnostics.
  String get label;

  /// The scope that owns the node.
  S get scope;

  /// The position of the component of this node in the module of its scope.
  int get declarationIndex;

  /// The keys that the node requires.
  Set<DiKeyBase> get declaredRequires;

  /// Every key whose publisher identity the node is bound to.
  Set<DiKeyBase> get declaredPlainReads;

  /// The keys that the node publishes, with its contribution key.
  Set<DiKeyBase> get declaredPublishes;

  /// The collection keys that the node reads strictly.
  Set<DiCollectionKey<Object?>> get collectionKeys;

  /// The collection keys that the node reads optionally.
  Set<DiCollectionKey<Object?>> get optionalCollectionKeys;

  /// The key of the component, or null. A contribution key is never one.
  DiKeyBase? get publicKey;

  /// The set that this node contributes to, or null.
  DiSetKey<Object?>? get contributionSet;

  /// The state that the last transition stored.
  NodeState get state;

  /// For each strict collection read that is missing, the contribution key
  /// that the runtime found unresolved and its position.
  Map<DiCollectionKey<Object?>, ({DiKeyBase key, int index})> get witnesses;

  /// The number of activations that the node committed.
  int get commits;

  /// The publishers that the committed activation read.
  Iterable<P> get dependencies;

  /// The publishers of the committed activation.
  Iterable<P> get publishers;

  /// The publisher that each key resolved to at the committed activation.
  Map<DiKeyBase, P> get committed;

  /// The membership of each collection read at the committed activation.
  Map<DiCollectionKey<Object?>, List<DiKeyBase>> get committedMembership;

  /// Whether the node left its scope for good.
  bool get removed;

  /// Whether the node committed an activation and still holds it.
  bool get active;

  /// Whether the release of the node runs.
  bool get deactivating;

  /// Whether an activation failed while `initialize` of the scope runs.
  bool get doomed;

  /// Whether a release failed, so the node does not activate again.
  bool get reactivationBlocked;

  /// Whether an activation of this node runs now.
  bool get activationInFlight;

  /// The failure of the last activation, or null.
  ActivationException? get activationException;

  /// The nearest available publisher of [key] that this node does not own.
  P? resolve(DiKeyBase key);
}
