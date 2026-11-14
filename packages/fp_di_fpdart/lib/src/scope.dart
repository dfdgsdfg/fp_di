import 'package:fp_di/fp_di.dart';
import 'package:fpdart/fpdart.dart';

import 'failure.dart';

/// The lifecycle and the lookups of a [Scope] as fpdart values.
///
/// Each task is lazy: building it runs nothing, and every run calls fp_di
/// once. A `Right` scope is still owned by the caller, who disposes it; use
/// [use] to bracket a scope instead.
extension ScopeFpdart on Scope {
  /// [initialize] as a task. A second run on the same scope is a `Left` with
  /// a `StateError`, not a cached `Right`. A `Right` does not mean that
  /// every member is active: a member can wait for a key of an ancestor.
  TaskEither<DiFailure, Scope> initializeTask() =>
      TaskEither<DiFailure, Scope>.tryCatch(initialize, DiFailure.new);

  /// [dispose] as a task. A `Left` carries the `DisposeException` and its
  /// dispose failures.
  TaskEither<DiFailure, Unit> disposeTask() =>
      TaskEither<DiFailure, Unit>.tryCatch(() async {
        await dispose();
        return unit;
      }, DiFailure.new);

  /// Brackets this scope: initializes it, runs [use] against it, and
  /// disposes it on every path, so a caller cannot keep the scope by
  /// forgetting [dispose].
  ///
  /// [use] is a host program whose environment is the scope. It reads values
  /// with [get] or [getEither], outside any component, where no read needs
  /// tracking; a component reads through a `Dependency` instead.
  TaskEither<ScopeFailure<E>, A> use<E, A>(ReaderTaskEither<Scope, E, A> use) =>
      TaskEither(() async {
        final setup = await initializeTask().run();
        return setup.match(
          (failure) async {
            // A failed initialize can leave a partial declaration to release.
            await disposeTask().run();
            return Either<ScopeFailure<E>, A>.left(InitializeFailed(failure));
          },
          (_) async {
            final Either<E, A> result;
            try {
              result = await use.run(this);
            } on Object {
              await disposeTask().run();
              rethrow;
            }
            final teardown = await disposeTask().run();
            return teardown.match(
              (failure) => Either<ScopeFailure<E>, A>.left(
                DisposeFailed(failure, result.getLeft()),
              ),
              (_) => result.mapLeft<ScopeFailure<E>>(UseFailed.new),
            );
          },
        );
      });

  /// [get] as an `Either`: a `Left` when the key has no value or the scope
  /// cannot be read.
  Either<DiFailure, T> getEither<T>({DiKey<T>? key}) =>
      Either<DiFailure, T>.tryCatch(() => get<T>(key: key), DiFailure.new);

  /// [maybeGet] as an `Option`.
  ///
  /// `None` stands for both an absent key and a bound `null`; use it only for
  /// a type whose values are never null.
  Option<T> getOption<T extends Object>({DiKey<T>? key}) =>
      Option.fromNullable(maybeGet<T>(key: key));
}

/// The availability of a [ComponentNode] as a task.
extension ComponentNodeFpdart<A> on ComponentNode<A> {
  /// [whenActive] as a task: the value once the node commits an activation,
  /// or a `Left` when the node is disposed first. A failed automatic
  /// activation does not complete it.
  TaskEither<DiFailure, A> whenActiveTask() =>
      TaskEither<DiFailure, A>.tryCatch(() => whenActive, DiFailure.new);
}
