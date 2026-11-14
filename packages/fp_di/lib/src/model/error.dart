import 'key.dart';

/// A wiring mistake in the program: fix the code, do not catch it.
///
/// Following Dart, a `DiError` is an [Error], like `ArgumentError` and
/// `StateError`, which the runtime also throws for invalid arguments and
/// calls in the wrong state.
///
/// {@category Errors}
sealed class DiError extends Error {
  DiError(this.message);

  /// The description of the mistake.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// A declared member requires a key that nothing can ever publish.
///
/// A scope's contents and the contents of its ancestors are fixed when they
/// are created. When no other member of the scope and no member declared by
/// an ancestor publishes a key that a member injects, that member could never
/// activate. `Scope.initialize` reports this instead of leaving the member
/// dormant. A missing type argument on the intended component is the usual
/// cause: `Component(dependency: ...)` then publishes the type of the
/// implementation. Optional reads through `Dependency.maybe` are not checked.
///
/// {@category Errors}
final class UndeclaredKeyError extends DiError {
  /// Creates the error for the [undeclared] keys that members require.
  UndeclaredKeyError(Iterable<({String label, DiKeyBase key})> undeclared)
    : undeclared = List.unmodifiable(undeclared),
      super(
        '${undeclared.map((m) => '${m.label} requires ${m.key}').join('; ')}, '
        'but no member of this scope or its ancestors publishes it. Check that '
        'the publisher states the type argument, Component<T>(...), or its '
        'named key, and that it is not a Component.effect.',
      );

  /// The label of each member and the required key that nothing declares, in
  /// declaration order.
  final List<({String label, DiKeyBase key})> undeclared;
}

/// Two members of one scope publish the same key.
///
/// A key has one publisher in a scope; a nearer scope may shadow it.
/// `Scope.initialize` reports a duplicate among the declared members before
/// it creates anything, and [labels] then lists their labels.
///
/// {@category Errors}
final class DuplicateKeyError extends DiError {
  /// Creates the error for the duplicate [key]. [labels] lists the members
  /// that publish it.
  DuplicateKeyError(this.key, {Iterable<String> labels = const []})
    : labels = List.unmodifiable(labels),
      super(
        labels.isEmpty
            ? 'The scope already contains a publisher for $key.'
            : 'More than one member of the scope publishes $key: '
                  '${labels.join(', ')}. A key has one publisher in a scope.',
      );

  /// The key that more than one publisher claims.
  final DiKeyBase key;

  /// The labels of the members that publish [key], in declaration order.
  final List<String> labels;
}

/// The dependency graph has a cycle.
///
/// The unnamed constructor reports an edge that would close a cycle, with the
/// [path] of labels that the cycle follows. [DependencyCycleError.unsettled]
/// reports optional reads that feed back into each other, so a
/// reconciliation stopped after [passes] passes with [path] still stale.
///
/// {@category Errors}
final class DependencyCycleError extends DiError {
  /// Creates the error for an edge that would close a cycle along [path].
  DependencyCycleError(Iterable<String> path)
    : path = List.unmodifiable(path),
      passes = null,
      super('Dependency cycle detected: ${path.join(' -> ')}.');

  /// The nodes in [stale] still read outdated values after [passes] passes.
  DependencyCycleError.unsettled(Iterable<String> stale, int this.passes)
    : path = List.unmodifiable(stale),
      super(
        'The reads of ${stale.join(', ')} did not settle after $passes '
        'reconciliation passes: their optional reads feed back into each '
        'other. Break the feedback, for example with a required read.',
      );

  /// The labels of the cycle, or of the stale nodes for [unsettled].
  final List<String> path;

  /// The passes after which reconciliation stopped, or null for an edge.
  final int? passes;
}

/// An operation targeted a scope that has already been disposed.
///
/// {@category Errors}
final class DisposedScopeError extends DiError {
  /// Creates the error for a disposed scope.
  DisposedScopeError() : super('The DI scope has been disposed.');
}

/// An activation operation ran after its activation was gone.
///
/// {@category Errors}
final class OutsideActivationError extends DiError {
  /// Creates the error for the [operation] that ran outside an activation.
  OutsideActivationError(String operation)
    : super('$operation is only valid while a component is activating.');
}

/// A binding was keyed by a type no lookup can name.
///
/// No lookup names a `FutureOr<...>` or `Future<...>` key, so
/// `key: DiKey<FutureOr<Repository>>()` would bind a value that no
/// `Dependency.require<Repository>()` could ever find. The runtime rejects such
/// a key instead of publishing an unreachable binding.
///
/// {@category Errors}
final class UnreachableKeyError extends DiError {
  /// Creates the error for the unreachable [key].
  UnreachableKeyError(this.key)
    : super(
        'Cannot bind $key: a FutureOr/Future key can never be resolved. '
        'Publish under the value type, for example DiKey<Repository>().',
      );

  /// The key that no lookup can name.
  final DiKeyBase key;
}

/// A lifecycle mutation was attempted from inside another one.
///
/// Every mutation is serialized on one queue, so a nested `initialize` or
/// `dispose` issued from a `create`, a `dispose`, or a `Dependency`
/// function would wait for a mutation that cannot finish until the nested
/// call returns. The runtime reports this instead of deadlocking.
///
/// {@category Errors}
final class ReentrantMutationError extends DiError {
  /// Creates the error for the nested [operation].
  ReentrantMutationError(this.operation)
    : super(
        '$operation was called from inside a running mutation. '
        'Initialize or dispose scopes from outside a create, a dispose, '
        'or a Dependency function.',
      );

  /// The name of the nested mutation, such as `Scope.dispose`.
  final String operation;
}
