// The allowed transitions of the lifecycle flags of one scope. The runtime
// writes the flags in place and asks this table before each write. The table
// reads and changes nothing.
import '../model/state.dart';
import 'core_graph.dart';

/// The events that change the lifecycle flags of one scope.
enum CoreScopeEvent {
  /// `initialize` creates the nodes of the scope and starts to run.
  beginInitialize,

  /// `initialize` ended with success.
  finishInitialize,

  /// `initialize` ended with a rollback.
  rollbackInitialize,

  /// A `dispose` call was accepted for the scope.
  requestDisposal,

  /// The disposal mutation of the scope, or of an ancestor, starts.
  markDisposing,

  /// The disposal mutation released the nodes of the scope.
  markDisposed,
}

/// The phase that the own flags of [scope] give. The flags of an ancestor do
/// not count, so a scope that only an ancestor disposes keeps its own phase
/// until the disposal of the ancestor reaches it.
ScopePhase coreOwnScopePhase<
  S extends CoreScope<S, P, N>,
  P extends CorePublisher<N>,
  N extends CoreNode<S, P, N>
>(CoreScope<S, P, N> scope) {
  if (scope.disposed) return ScopePhase.disposed;
  if (scope.disposing) return ScopePhase.disposing;
  if (scope.disposeRequested) return ScopePhase.disposeRequested;
  if (scope.initialized) return ScopePhase.initialized;
  if (scope.initializing) return ScopePhase.initializing;
  return ScopePhase.declared;
}

/// The own phase of a scope after [event] in the own phase [phase], or null
/// when [phase] does not allow [event].
///
/// A scope with a disposal request keeps the phase `disposeRequested` when
/// `initialize` ends, because the phase hides the flags of `initialize`. A
/// disposal that a release failure left half done keeps the phase `disposing`
/// when the disposal of an ancestor reaches the scope again.
ScopePhase? coreScopeTransition(ScopePhase phase, CoreScopeEvent event) =>
    switch (event) {
      CoreScopeEvent.beginInitialize => switch (phase) {
        ScopePhase.declared => ScopePhase.initializing,
        _ => null,
      },
      CoreScopeEvent.finishInitialize => switch (phase) {
        ScopePhase.initializing => ScopePhase.initialized,
        ScopePhase.disposeRequested => ScopePhase.disposeRequested,
        _ => null,
      },
      CoreScopeEvent.rollbackInitialize => switch (phase) {
        ScopePhase.initializing => ScopePhase.declared,
        ScopePhase.disposeRequested => ScopePhase.disposeRequested,
        _ => null,
      },
      CoreScopeEvent.requestDisposal => switch (phase) {
        ScopePhase.declared ||
        ScopePhase.initializing ||
        ScopePhase.initialized ||
        ScopePhase.disposeRequested => ScopePhase.disposeRequested,
        _ => null,
      },
      CoreScopeEvent.markDisposing => switch (phase) {
        ScopePhase.declared ||
        ScopePhase.initializing ||
        ScopePhase.initialized ||
        ScopePhase.disposeRequested ||
        ScopePhase.disposing => ScopePhase.disposing,
        _ => null,
      },
      CoreScopeEvent.markDisposed => switch (phase) {
        ScopePhase.disposing => ScopePhase.disposed,
        _ => null,
      },
    };
