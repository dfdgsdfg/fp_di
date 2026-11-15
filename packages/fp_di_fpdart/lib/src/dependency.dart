import 'dart:async';

import 'package:fpdart/fpdart.dart';

import 'cause.dart';
import 'environment.dart';
import 'failure.dart';
import 'finalizers.dart';
import 'key.dart';

/// The type tag of [Dependency] for the fpdart higher-kinded types.
abstract final class _DependencyHKT {}

/// The context of one component while the runtime creates its value.
///
/// The context holds the owner label, the values that the component can read,
/// and the place where the steps register the dispose functions of the values
/// that they own. A scope creates one context for each component.
final class StepContext {
  /// Creates the context of the component with the label [owner].
  const StepContext(this.owner, this.environment, this.finalizers);

  /// The label of the component.
  final String owner;

  /// The values that the component can read.
  final Environment environment;

  /// The dispose functions of the values that the component owns.
  final IORef<Finalizers> finalizers;
}

/// A step program: the form that a dependency has after the interpreter ran.
typedef _Program<A> = ReaderTaskEither<StepContext, Cause<DiFailure>, A>;

/// The reads of a dependency.
typedef _Reads = ({Set<DiKey<Object?>> requires, Set<DiKey<Object?>> optional});

/// The syntax tree of a dependency: a free applicative.
///
/// A node describes a value and does nothing. Two interpreters read the tree:
/// [_readsOf] folds the tree into the keys that it reads, and `compile`
/// turns the tree into a step program.
sealed class _Node<A> {
  const _Node();

  /// The sub-trees of the node, without their value types.
  ///
  /// A fold reads the tree through this list. A fold needs no type of a
  /// value, so it can ignore the types of the function values of an [_Ap].
  List<_Node<Object?>> get operands;

  /// The interpreter that makes the step program of the tree.
  _Program<A> compile();
}

/// A value that exists already.
final class _Pure<A> extends _Node<A> {
  const _Pure(this.value);

  final A value;

  @override
  List<_Node<Object?>> get operands => const [];

  @override
  _Program<A> compile() => ReaderTaskEither<StepContext, Cause<DiFailure>, A>(
    (_) async => Right(value),
  );
}

/// A required read of [key].
final class _Require<A> extends _Node<A> {
  const _Require(this.key);

  final DiKey<A> key;

  @override
  List<_Node<Object?>> get operands => const [];

  @override
  _Program<A> compile() => ReaderTaskEither<StepContext, Cause<DiFailure>, A>(
    (context) async => Right(context.environment.read(key)),
  );
}

/// An optional read of [key].
final class _Optional<A> extends _Node<Option<A>> {
  const _Optional(this.key);

  final DiKey<A> key;

  @override
  List<_Node<Object?>> get operands => const [];

  @override
  _Program<Option<A>> compile() =>
      ReaderTaskEither<StepContext, Cause<DiFailure>, Option<A>>(
        (context) async => Right(
          context.environment.contains(key)
              ? Some(context.environment.read(key))
              : const None(),
        ),
      );
}

/// The application of a function value [ff] to the value [fa].
///
/// The interpreter runs [fa] first and then [ff].
final class _Ap<A, B> extends _Node<B> {
  const _Ap(this.fa, this.ff);

  final _Node<A> fa;
  final _Node<B Function(A a)> ff;

  @override
  List<_Node<Object?>> get operands => [fa, ff];

  @override
  _Program<B> compile() => fa.compile().flatMap(
    (a) => ff.compile().flatMap(
      (g) => _attempt<B>(() async => Right<Object?, B>(g(a)), null),
    ),
  );
}

/// One effect after the value of [source], with an optional release.
///
/// The step covers `create`, `map`, `mapTask`, and `mapTaskEither`. The
/// [effect] gives a `Right` value, or a `Left` that fails the activation. A
/// throw of the effect fails the activation, too. With a [release], the step
/// owns its result.
final class _Step<A, B> extends _Node<B> {
  const _Step(this.source, this.effect, this.release);

  final _Node<A> source;
  final Future<Either<Object?, B>> Function(A a) effect;
  final FutureOr<void> Function(B value)? release;

  @override
  List<_Node<Object?>> get operands => [source];

  @override
  _Program<B> compile() =>
      source.compile().flatMap((a) => _attempt<B>(() => effect(a), release));
}

/// The step program of one effect.
///
/// A throw becomes a typed `ActivationFailure`, like the `attempt` of ZIO. A
/// `Left` becomes an `ActivationFailure` that holds the `Left` value. A
/// `Right` value goes to the finalizers when it has a [release].
_Program<B> _attempt<B>(
  Future<Either<Object?, B>> Function() effect,
  FutureOr<void> Function(B value)? release,
) => ReaderTaskEither<StepContext, Cause<DiFailure>, B>((context) async {
  final Either<Object?, B> result;
  try {
    result = await effect();
  } catch (error, stackTrace) {
    return Left(Fail(ActivationFailure(context.owner, error), stackTrace));
  }
  return result.match(
    (error) => Left<Cause<DiFailure>, B>(
      Fail(ActivationFailure(context.owner, error), StackTrace.current),
    ),
    (value) {
      if (release != null) {
        context.finalizers
            .modify((owned) => owned.push(context.owner, () => release(value)))
            .run();
      }
      return Right<Cause<DiFailure>, B>(value);
    },
  );
});

/// The interpreter that folds a tree into the keys that it reads.
_Reads _readsOf(_Node<Object?> node) => switch (node) {
  _Require<Object?>() => (requires: {node.key}, optional: const {}),
  _Optional<Object?>() => (requires: const {}, optional: {node.key}),
  _ => node.operands.map(_readsOf).fold((
    requires: const {},
    optional: const {},
  ), _union),
};

_Reads _union(_Reads left, _Reads right) => (
  requires: Set.unmodifiable({...left.requires, ...right.requires}),
  optional: Set.unmodifiable({...left.optional, ...right.optional}),
);

/// The value of a component and the keys that the value reads.
///
/// A dependency is an applicative description of the reads and the steps that
/// make a value. It plays the role of the `R` of ZIO and of `ZIO.service`:
/// the reads are the environment that the value needs. Dart has no
/// intersection types to track `R` in a type, so a dependency states the
/// reads as a set of keys instead. A dependency does nothing until a scope
/// runs the component. The dependency is a syntax tree, so a scope can read
/// the keys of the tree before it creates a value.
///
/// A dependency is an `Applicative`, and it is deliberately not a `Monad`.
/// A `flatMap` would let a step choose a read from a value. The reads would
/// then depend on a value, so the scope could not know the graph before it
/// creates a value. Without `flatMap`, the reads stay static.
///
/// A step that has a `dispose` argument owns its value. Within one component,
/// the scope disposes the owned values in reverse creation order.
final class Dependency<A> extends HKT<_DependencyHKT, A>
    with Functor<_DependencyHKT, A>, Applicative<_DependencyHKT, A> {
  Dependency._(this._node);

  /// Creates a value with [create].
  ///
  /// With [dispose], the dependency owns the value. A throw from [create]
  /// becomes an `ActivationFailure`.
  factory Dependency({
    required FutureOr<A> Function() create,
    FutureOr<void> Function(A value)? dispose,
  }) => Dependency._(
    _Step<Unit, A>(
      const _Pure(unit),
      (_) async => Right<Object?, A>(await create()),
      dispose,
    ),
  );

  /// A dependency of a [value] that exists already.
  ///
  /// The dependency reads nothing and owns nothing.
  factory Dependency.of(A value) => Dependency._(_Pure<A>(value));

  /// A dependency that runs the [create] task.
  ///
  /// With [dispose], the dependency owns the value.
  static Dependency<A> task<A>(
    Task<A> create, {
    FutureOr<void> Function(A value)? dispose,
  }) => Dependency<A>(create: create.run, dispose: dispose);

  /// A dependency that runs the [create] task.
  ///
  /// A `Left` fails the activation, and the `Left` value is the error of the
  /// `ActivationFailure`. With [dispose], the dependency owns the `Right`
  /// value.
  static Dependency<A> taskEither<E, A>(
    TaskEither<E, A> create, {
    FutureOr<void> Function(A value)? dispose,
  }) => Dependency<A>._(
    _Step<Unit, A>(
      const _Pure(unit),
      (_) async => (await create.run()).mapLeft<Object?>((error) => error),
      dispose,
    ),
  );

  /// A dependency that reads the value of [key].
  ///
  /// The key is `DiKey<T>()` when [key] is `null`. A scope or an ancestor
  /// must publish the key.
  static Dependency<T> require<T>({DiKey<T>? key}) =>
      Dependency<T>._(_Require<T>(key ?? DiKey<T>()));

  /// A dependency that reads the value of [key] when a scope publishes it.
  ///
  /// The result is `None` when neither the scope nor an ancestor publishes
  /// the key. When the key is present, the activation still waits for the
  /// publisher.
  static Dependency<Option<T>> option<T>({DiKey<T>? key}) =>
      Dependency<Option<T>>._(_Optional<T>(key ?? DiKey<T>()));

  /// A dependency of the list of the values of [list] after [f].
  ///
  /// The function [f] makes one dependency for each element. The steps run
  /// from the first element to the last element.
  static Dependency<List<B>> traverseList<A, B>(
    List<A> list,
    Dependency<B> Function(A a) f,
  ) => list.fold(
    Dependency<List<B>>.of(const []),
    (all, a) => all.map2<B, List<B>>(f(a), (done, b) => [...done, b]),
  );

  /// A dependency of the list of the values of the dependencies in [list].
  ///
  /// The steps run from the first dependency to the last dependency.
  static Dependency<List<A>> sequenceList<A>(List<Dependency<A>> list) =>
      traverseList<Dependency<A>, A>(list, (dependency) => dependency);

  final _Node<A> _node;

  late final _Reads _reads = _readsOf(_node);

  /// The keys that the dependency must read.
  ///
  /// A scope or an ancestor must publish each key.
  Set<DiKey<Object?>> get requires => _reads.requires;

  /// The keys that the dependency reads when a scope publishes them.
  Set<DiKey<Object?>> get optional => _reads.optional;

  /// A dependency of [b].
  ///
  /// The dependency reads nothing and owns nothing.
  @override
  Dependency<B> pure<B>(B b) => Dependency<B>.of(b);

  /// Applies the function that [f] creates to the value of this dependency.
  ///
  /// The reads are the union of both reads. The steps run this dependency
  /// first and then [f]. A throw from the function becomes an
  /// `ActivationFailure`.
  @override
  Dependency<B> ap<B>(covariant Dependency<B Function(A a)> f) =>
      Dependency<B>._(_Ap<A, B>(_node, f._node));

  /// Creates the next value from this value with [f].
  ///
  /// A throw from [f] becomes an `ActivationFailure`. With [dispose], the
  /// step owns the new value.
  @override
  Dependency<B> map<B>(
    B Function(A value) f, {
    FutureOr<void> Function(B value)? dispose,
  }) => Dependency<B>._(
    _Step<A, B>(_node, (a) async => Right<Object?, B>(f(a)), dispose),
  );

  /// Runs the task that [f] creates from this value.
  ///
  /// With [dispose], the step owns the result.
  Dependency<B> mapTask<B>(
    Task<B> Function(A value) f, {
    FutureOr<void> Function(B value)? dispose,
  }) => Dependency<B>._(
    _Step<A, B>(
      _node,
      (a) async => Right<Object?, B>(await f(a).run()),
      dispose,
    ),
  );

  /// Runs the task that [f] creates from this value.
  ///
  /// A `Left` fails the activation, and the `Left` value is the error of the
  /// `ActivationFailure`. The runtime then disposes the earlier owned values
  /// of the component in reverse order. With [dispose], the step owns the
  /// `Right` value.
  Dependency<B> mapTaskEither<E, B>(
    TaskEither<E, B> Function(A value) f, {
    FutureOr<void> Function(B value)? dispose,
  }) => Dependency<B>._(
    _Step<A, B>(
      _node,
      (a) async => (await f(a).run()).mapLeft<Object?>((error) => error),
      dispose,
    ),
  );

  /// Combines this value and the value of [other] with [f].
  ///
  /// The reads are the union of both reads. The steps run left to right.
  Dependency<C> map2<B, C>(Dependency<B> other, C Function(A a, B b) f) =>
      ap<C>(
        other.map<C Function(A a)>(
          (b) =>
              (a) => f(a, b),
        ),
      );

  /// Combines this value, [b], and [c] with [f].
  ///
  /// The reads are the union of all reads. The steps run left to right.
  Dependency<D> map3<B, C, D>(
    Dependency<B> b,
    Dependency<C> c,
    D Function(A a, B b, C c) f,
  ) => map2<B, (A, B)>(
    b,
    (x, y) => (x, y),
  ).map2<C, D>(c, (p, z) => f(p.$1, p.$2, z));
}

/// Runs the steps of [dependency] in [context].
///
/// The task never throws. A failed step gives a `Left` with a `Cause`.
Task<Exit<DiFailure, A>> runDependency<A>(
  Dependency<A> dependency,
  StepContext context,
) => Task(() => dependency._node.compile().run(context));

/// Applies a function to the values of a zip of two dependencies.
extension DependencyOfRecord2<A, B> on Dependency<(A, B)> {
  /// Like [Dependency.map], with the record spread into positional
  /// arguments.
  Dependency<R> mapN<R>(
    R Function(A, B) f, {
    FutureOr<void> Function(R value)? dispose,
  }) => map((v) => f(v.$1, v.$2), dispose: dispose);
}

/// Applies a function to the values of a zip of three dependencies.
extension DependencyOfRecord3<A, B, C> on Dependency<(A, B, C)> {
  /// Like [Dependency.map], with the record spread into positional
  /// arguments.
  Dependency<R> mapN<R>(
    R Function(A, B, C) f, {
    FutureOr<void> Function(R value)? dispose,
  }) => map((v) => f(v.$1, v.$2, v.$3), dispose: dispose);
}

/// Applies a function to the values of a zip of four dependencies.
extension DependencyOfRecord4<A, B, C, D> on Dependency<(A, B, C, D)> {
  /// Like [Dependency.map], with the record spread into positional
  /// arguments.
  Dependency<R> mapN<R>(
    R Function(A, B, C, D) f, {
    FutureOr<void> Function(R value)? dispose,
  }) => map((v) => f(v.$1, v.$2, v.$3, v.$4), dispose: dispose);
}

/// Applies a function to the values of a zip of five dependencies.
extension DependencyOfRecord5<A, B, C, D, E> on Dependency<(A, B, C, D, E)> {
  /// Like [Dependency.map], with the record spread into positional
  /// arguments.
  Dependency<R> mapN<R>(
    R Function(A, B, C, D, E) f, {
    FutureOr<void> Function(R value)? dispose,
  }) => map((v) => f(v.$1, v.$2, v.$3, v.$4, v.$5), dispose: dispose);
}

/// Applies a function to the values of a zip of six dependencies.
extension DependencyOfRecord6<A, B, C, D, E, F>
    on Dependency<(A, B, C, D, E, F)> {
  /// Like [Dependency.map], with the record spread into positional
  /// arguments.
  Dependency<R> mapN<R>(
    R Function(A, B, C, D, E, F) f, {
    FutureOr<void> Function(R value)? dispose,
  }) => map((v) => f(v.$1, v.$2, v.$3, v.$4, v.$5, v.$6), dispose: dispose);
}

/// Applies a function to the values of a zip of seven dependencies.
extension DependencyOfRecord7<A, B, C, D, E, F, G>
    on Dependency<(A, B, C, D, E, F, G)> {
  /// Like [Dependency.map], with the record spread into positional
  /// arguments.
  Dependency<R> mapN<R>(
    R Function(A, B, C, D, E, F, G) f, {
    FutureOr<void> Function(R value)? dispose,
  }) =>
      map((v) => f(v.$1, v.$2, v.$3, v.$4, v.$5, v.$6, v.$7), dispose: dispose);
}

/// Applies a function to the values of a zip of eight dependencies.
extension DependencyOfRecord8<A, B, C, D, E, F, G, H>
    on Dependency<(A, B, C, D, E, F, G, H)> {
  /// Like [Dependency.map], with the record spread into positional
  /// arguments.
  Dependency<R> mapN<R>(
    R Function(A, B, C, D, E, F, G, H) f, {
    FutureOr<void> Function(R value)? dispose,
  }) => map(
    (v) => f(v.$1, v.$2, v.$3, v.$4, v.$5, v.$6, v.$7, v.$8),
    dispose: dispose,
  );
}

/// Combines a record of two dependencies into one dependency of a record.
extension DependencyRecord2<A, B> on (Dependency<A>, Dependency<B>) {
  /// The values of every dependency, in record order.
  ///
  /// The reads are the union of all reads. The steps run left to right. The
  /// scope disposes the owned values right to left.
  Dependency<(A, B)> get zip => $1.map2($2, (a, b) => (a, b));
}

/// Combines a record of three dependencies into one dependency of a record.
extension DependencyRecord3<A, B, C>
    on (Dependency<A>, Dependency<B>, Dependency<C>) {
  /// The values of every dependency, in record order.
  ///
  /// The reads are the union of all reads. The steps run left to right. The
  /// scope disposes the owned values right to left.
  Dependency<(A, B, C)> get zip =>
      ($1, $2).zip.map2($3, (p, c) => (p.$1, p.$2, c));
}

/// Combines a record of four dependencies into one dependency of a record.
extension DependencyRecord4<A, B, C, D>
    on (Dependency<A>, Dependency<B>, Dependency<C>, Dependency<D>) {
  /// The values of every dependency, in record order.
  ///
  /// The reads are the union of all reads. The steps run left to right. The
  /// scope disposes the owned values right to left.
  Dependency<(A, B, C, D)> get zip =>
      ($1, $2, $3).zip.map2($4, (p, d) => (p.$1, p.$2, p.$3, d));
}

/// Combines a record of five dependencies into one dependency of a record.
extension DependencyRecord5<A, B, C, D, E>
    on
        (
          Dependency<A>,
          Dependency<B>,
          Dependency<C>,
          Dependency<D>,
          Dependency<E>,
        ) {
  /// The values of every dependency, in record order.
  ///
  /// The reads are the union of all reads. The steps run left to right. The
  /// scope disposes the owned values right to left.
  Dependency<(A, B, C, D, E)> get zip =>
      ($1, $2, $3, $4).zip.map2($5, (p, e) => (p.$1, p.$2, p.$3, p.$4, e));
}

/// Combines a record of six dependencies into one dependency of a record.
extension DependencyRecord6<A, B, C, D, E, F>
    on
        (
          Dependency<A>,
          Dependency<B>,
          Dependency<C>,
          Dependency<D>,
          Dependency<E>,
          Dependency<F>,
        ) {
  /// The values of every dependency, in record order.
  ///
  /// The reads are the union of all reads. The steps run left to right. The
  /// scope disposes the owned values right to left.
  Dependency<(A, B, C, D, E, F)> get zip => (
    $1,
    $2,
    $3,
    $4,
    $5,
  ).zip.map2($6, (p, f) => (p.$1, p.$2, p.$3, p.$4, p.$5, f));
}

/// Combines a record of seven dependencies into one dependency of a record.
extension DependencyRecord7<A, B, C, D, E, F, G>
    on
        (
          Dependency<A>,
          Dependency<B>,
          Dependency<C>,
          Dependency<D>,
          Dependency<E>,
          Dependency<F>,
          Dependency<G>,
        ) {
  /// The values of every dependency, in record order.
  ///
  /// The reads are the union of all reads. The steps run left to right. The
  /// scope disposes the owned values right to left.
  Dependency<(A, B, C, D, E, F, G)> get zip => (
    $1,
    $2,
    $3,
    $4,
    $5,
    $6,
  ).zip.map2($7, (p, g) => (p.$1, p.$2, p.$3, p.$4, p.$5, p.$6, g));
}

/// Combines a record of eight dependencies into one dependency of a record.
extension DependencyRecord8<A, B, C, D, E, F, G, H>
    on
        (
          Dependency<A>,
          Dependency<B>,
          Dependency<C>,
          Dependency<D>,
          Dependency<E>,
          Dependency<F>,
          Dependency<G>,
          Dependency<H>,
        ) {
  /// The values of every dependency, in record order.
  ///
  /// The reads are the union of all reads. The steps run left to right. The
  /// scope disposes the owned values right to left.
  Dependency<(A, B, C, D, E, F, G, H)> get zip => (
    $1,
    $2,
    $3,
    $4,
    $5,
    $6,
    $7,
  ).zip.map2($8, (p, h) => (p.$1, p.$2, p.$3, p.$4, p.$5, p.$6, p.$7, h));
}
