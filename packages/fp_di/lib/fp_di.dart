/// Lifecycle-aware dependency injection for Dart.
///
/// A [Component] publishes a value under a [DiKey], and its [Dependency]
/// states the keys that the value reads. A [Module] lists components. A
/// [Scope] declares a module and creates its components in
/// [Scope.initialize]. A component activates when each key that it requires
/// resolves. The runtime releases a component before the components whose
/// values it read.
///
/// The library has four layers:
///
/// - Dependency: [Dependency] and [Dependency1] to [Dependency8] state how a
///   value is created from the keys that it reads.
/// - Declaration: [Component], [Module], and [Scope] state what a scope
///   holds.
/// - Instance: a [ComponentNode] is the runtime form of one member of a
///   scope.
/// - Observation: [ScopeState], [NodeState], and [Scope.addListener] read
///   the state of the runtime and change nothing.
///
/// `package:fp_di/tooling.dart` reads the shape of a module without a
/// runtime, for scripts and tests.
library;

export 'src/model/cancellation.dart' hide CancelReason, CancellationSource;
export 'src/model/change.dart';
export 'src/model/component.dart' hide runComponent, createComponentNode;
export 'src/model/error.dart';
export 'src/model/exception.dart';
export 'src/model/key.dart';
export 'src/model/lease.dart'
    hide Lease, DisposeFunction, createLease, runDependency;
export 'src/model/module.dart';
export 'src/model/state.dart' hide createNodeState, createScopeState;
export 'src/runtime/scope.dart';
