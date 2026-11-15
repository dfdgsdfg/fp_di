import 'dart:async';

import 'package:fp_di/fp_di.dart';
import 'package:fpdart/fpdart.dart';

import 'failure.dart';

/// Steps of a [Dependency] that run fpdart effects.
///
/// Each step keeps the shape of the [Dependency]: it reads no new key and
/// decides nothing about the keys at run time, so fp_di can still check and
/// schedule the graph before it runs. There is no `flatMap` that would choose
/// the next reads from a value.
extension DependencyFpdart<A> on Dependency<A> {
  /// Runs [create] after this step. A `Left` fails the setup: the step throws
  /// a [DependencyLeft] with the `Left`, the completed steps are disposed in
  /// reverse order, and nothing is published. With [dispose], the component
  /// owns the `Right` value and disposes it at teardown.
  ///
  /// Use it when a `Left` means the component cannot exist, such as an
  /// invalid configuration. For a `Left` that is ordinary business data, use
  /// [mapTaskEitherAsData].
  Dependency<B> mapTaskEither<E, B>(
    TaskEither<E, B> Function(A value) create, {
    FutureOr<void> Function(B value)? dispose,
  }) => map<B>(
    (value) async => (await create(
      value,
    ).run()).getOrElse((left) => throw DependencyLeft<E>(left)),
    dispose: dispose,
  );

  /// Runs [create] after this step and keeps its `Either` as the value: a
  /// `Left` is data, publishes like a `Right`, and rolls nothing back. With
  /// [dispose], the component owns a `Right` value and disposes it at
  /// teardown; a `Left` needs no dispose.
  Dependency<Either<E, B>> mapTaskEitherAsData<E, B>(
    TaskEither<E, B> Function(A value) create, {
    FutureOr<void> Function(B value)? dispose,
  }) => map<Either<E, B>>(
    (value) => create(value).run(),
    dispose: dispose == null
        ? null
        : (either) async {
            if (either case Right(:final value)) await dispose(value);
          },
  );

  /// Runs [create] after this step as a `Task`, which cannot fail.
  Dependency<B> mapTask<B>(
    Task<B> Function(A value) create, {
    FutureOr<void> Function(B value)? dispose,
  }) => map<B>((value) => create(value).run(), dispose: dispose);
}

/// An optional read as an `Option`.
extension OptionalDependencyFpdart<A extends Object> on Dependency<A?> {
  /// The value of this optional read as an `Option`: `None` when the key is
  /// absent. A bound `null` is `None` too, so use it only for a type whose
  /// values are never null.
  Dependency<Option<A>> toOption() => map(Option.fromNullable);
}

/// A [Lazy] as an fpdart value.
extension LazyFpdart<A> on Lazy<A> {
  /// [Lazy.force] as a lazy task. Building the task creates nothing; the
  /// first run creates the value, and a later run returns the same value.
  ///
  /// A failure of the creation is a `Left` with the original error: read
  /// [DiFailure.cause] for the error that the creation threw. A failure is
  /// not cached, so a later run tries again, as [Lazy.force] does. After the
  /// disposal of the owner is requested, a run is a `Left` with a
  /// `DisposedLazyException`.
  TaskEither<DiFailure, A> toTaskEither() =>
      TaskEither<DiFailure, A>.tryCatch(force, DiFailure.new);
}

/// A [CancellationToken] as an fpdart value.
extension CancellationTokenFpdart on CancellationToken {
  /// A task that completes when the token is canceled, for an API that takes
  /// a cancel trigger as a `Task` or a `Future<void>`.
  Task<Unit> get canceledTask => Task(() async {
    await whenCanceled;
    return unit;
  });
}
