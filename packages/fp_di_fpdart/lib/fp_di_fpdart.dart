/// A lifecycle-aware dependency-injection runtime built on fpdart.
///
/// A [Component] publishes a value under a [DiKey]. Its [Dependency] states
/// the keys that the value reads. A [Scope] takes a list of components, and
/// [Scope.run] creates one node for each component.
///
/// The graph of the keys is static. The runtime knows each read before it
/// creates a value, so it checks the components first and activates
/// independent nodes concurrently. The runtime is reactive: a node that reads
/// a key releases its value and creates it again when the publisher of the key
/// changes, and a node waits while a required key has no publisher. A node is
/// disposed before the nodes that it reads.
///
/// The design follows ZIO. A [Cause] is the tree of the failures of an
/// operation, and an [Exit] is a `Cause` or a value. A [Component] is the
/// `ZLayer` of this package: one output key, and the inputs that its
/// dependency reads. The list of components that a [Scope] takes is the
/// argument list of `ZLayer.make`. The package has no operator that composes
/// layers, such as `>>>` or `++`. The scope derives the wiring from the
/// graph. A [Dependency] is an applicative description, and it is not a
/// monad. A [Scope] holds finalizers and runs them in reverse order.
///
/// No operation throws. Every failure is a `Left` with a [Cause], or a
/// [DiFailure] in an `Either`. A step of a [Dependency] can return a
/// `TaskEither`, and a `Left` of the step fails the activation. An activation
/// that a disposal canceled is an [Interrupt]. `Scope.use` brackets a program
/// of type `ReaderTaskEither`: run, use, and always dispose.
///
/// The library depends on fpdart only.
library;

export 'src/cancellation.dart' hide CancelReason, CancellationSource;
export 'src/cause.dart';
export 'src/component.dart' hide runComponent;
export 'src/dependency.dart' hide StepContext, foldDependency, runDependency;
export 'src/failure.dart';
export 'src/hold.dart' hide createDisposeHold;
export 'src/key.dart' hide ContributionKey, effectKey;
export 'src/lazy.dart' hide createLazy;
export 'src/node.dart' hide componentNodeOf;
export 'src/scope.dart';
export 'src/slow_mutation.dart';
