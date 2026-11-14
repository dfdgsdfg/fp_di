/// An fpdart-shaped API for fp_di.
///
/// fp_di owns composition and lifecycle: which values exist, what they read,
/// when they are created, and when they are disposed. fpdart describes the
/// programs that use them. This library puts the fp_di operations into
/// fpdart's types:
///
/// - scope lifecycle as `TaskEither` (`initializeTask`, `disposeTask`) and a
///   bracket (`use`);
/// - lookups as `Either` and `Option` (`getEither`, `getOption`), and node
///   availability as a `TaskEither` (`whenActiveTask`);
/// - `Dependency` steps that run a `TaskEither`, with the `Left` policy in
///   the name (`mapTaskEither` fails the setup, `mapTaskEitherAsData` keeps
///   the `Left` as data), and optional reads as `Option` (`toOption`).
///
/// A failure is a [DiFailure] that keeps the original error, its stack
/// trace, and its rollback failures. The core `fp_di` package does not depend
/// on fpdart.
library;

export 'src/dependency.dart';
export 'src/failure.dart';
export 'src/scope.dart';
