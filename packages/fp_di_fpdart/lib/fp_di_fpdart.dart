/// A lifecycle-aware dependency-injection runtime built on fpdart.
///
/// A [Component] publishes a value under a [DiKey]. Its [Dependency] states
/// the keys that the value reads. A [Scope] takes a list of components, runs
/// the list once, and disposes the values when the scope ends.
///
/// The graph is static. The runtime knows each read before it creates a
/// value, so it checks the components first and creates independent
/// components concurrently. A component is disposed before the components
/// that it reads.
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
/// No operation throws. Every failure is a `Left` with a [Cause]. A step of a
/// [Dependency] can return a `TaskEither`, and a `Left` of the step fails the
/// activation. `Scope.use` brackets a program of type `ReaderTaskEither`:
/// run, use, and always dispose.
///
/// The library depends on fpdart only.
library;

export 'src/cause.dart';
export 'src/component.dart' hide buildComponent;
export 'src/dependency.dart' hide StepContext, foldDependency, runDependency;
export 'src/failure.dart';
export 'src/key.dart';
export 'src/scope.dart';
