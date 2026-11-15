import 'dart:async';

import 'package:fpdart/fpdart.dart';

import 'cause.dart';
import 'environment.dart';
import 'failure.dart';
import 'finalizers.dart';
import 'key.dart';
import 'syntax.dart';

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

/// The tag of the reads interpreter.
abstract final class _ReadsTag {}

/// The result of the reads interpreter. The type `A` is a phantom type.
final class _ReadsOf<A> extends HKT<_ReadsTag, A> {
  const _ReadsOf(this.reads);

  final _Reads reads;
}

_Reads _readsIn<A>(HKT<_ReadsTag, A> result) => (result as _ReadsOf<A>).reads;

_Reads _union(_Reads left, _Reads right) => (
  requires: Set.unmodifiable({...left.requires, ...right.requires}),
  optional: Set.unmodifiable({...left.optional, ...right.optional}),
);

/// The interpreter that folds a tree into the keys that it reads.
final class _ReadsAlgebra implements DependencyAlgebra<_ReadsTag> {
  const _ReadsAlgebra();

  @override
  HKT<_ReadsTag, A> pure<A>(A value) =>
      _ReadsOf<A>((requires: const {}, optional: const {}));

  @override
  HKT<_ReadsTag, A> require<A>(DiKey<A> key) =>
      _ReadsOf<A>((requires: {key}, optional: const {}));

  @override
  HKT<_ReadsTag, Option<A>> optional<A>(DiKey<A> key) =>
      _ReadsOf<Option<A>>((requires: const {}, optional: {key}));

  @override
  HKT<_ReadsTag, B> ap<A, B>(
    HKT<_ReadsTag, A> fa,
    HKT<_ReadsTag, B Function(A a)> ff,
  ) => _ReadsOf<B>(_union(_readsIn(fa), _readsIn(ff)));

  @override
  HKT<_ReadsTag, B> step<A, B>(
    HKT<_ReadsTag, A> source,
    StepEffect<A, B> effect,
    StepRelease<B>? release,
  ) => _ReadsOf<B>(_readsIn(source));
}

/// The tag of the runner interpreter.
abstract final class _ProgramTag {}

/// The result of the runner interpreter: a step program.
final class _ProgramOf<A> extends HKT<_ProgramTag, A> {
  const _ProgramOf(this.program);

  final _Program<A> program;
}

_Program<A> _programIn<A>(HKT<_ProgramTag, A> result) =>
    (result as _ProgramOf<A>).program;

/// A step program that needs the context of the component.
///
/// The program reads the context with `ask`, so no code runs a task while it
/// builds the program.
_Program<B> _withContext<B>(
  TaskEither<Cause<DiFailure>, B> Function(StepContext context) f,
) => ReaderTaskEither.ask<StepContext, Cause<DiFailure>>().flatMap(
  (context) => ReaderTaskEither.fromTaskEither(f(context)),
);

/// The registration of a dispose function, as a task.
///
/// The task gives [value] after it registered the release. The registration is
/// part of the effect, so it happens when the step runs.
TaskEither<Cause<DiFailure>, B> _own<B>(
  StepContext context,
  B value,
  StepRelease<B>? release,
) => release == null
    ? TaskEither<Cause<DiFailure>, B>.right(value)
    : TaskEither<Cause<DiFailure>, Unit>.fromTask(
        context.finalizers
            .modify((owned) => owned.push(context.owner, () => release(value)))
            .toTask(),
      ).map((_) => value);

/// The step program of one effect.
///
/// A throw becomes a typed `ActivationFailure`, like the `attempt` of ZIO. A
/// `Left` becomes an `ActivationFailure` that holds the `Left` value. A
/// `Right` value goes to the finalizers when it has a [release].
_Program<B> _attempt<B>(
  Future<Either<Object?, B>> Function() effect,
  StepRelease<B>? release,
) => _withContext<B>(
  (context) =>
      TaskEither<Cause<DiFailure>, Either<Object?, B>>.tryCatch(
            effect,
            (error, stackTrace) => Fail<DiFailure>(
              ActivationFailure(context.owner, error),
              stackTrace,
            ),
          )
          .chainEither(
            (result) => result.mapLeft<Cause<DiFailure>>(
              (error) => Fail<DiFailure>(
                ActivationFailure(context.owner, error),
                StackTrace.current,
              ),
            ),
          )
          .flatMap((value) => _own(context, value, release)),
);

/// The interpreter that turns a tree into a step program.
final class _ProgramAlgebra implements DependencyAlgebra<_ProgramTag> {
  const _ProgramAlgebra();

  @override
  HKT<_ProgramTag, A> pure<A>(A value) => _ProgramOf<A>(
    ReaderTaskEither<StepContext, Cause<DiFailure>, A>.of(value),
  );

  @override
  HKT<_ProgramTag, A> require<A>(DiKey<A> key) => _ProgramOf<A>(
    ReaderTaskEither<StepContext, Cause<DiFailure>, A>.asks(
      (context) => context.environment.read(key),
    ),
  );

  @override
  HKT<_ProgramTag, Option<A>> optional<A>(DiKey<A> key) =>
      _ProgramOf<Option<A>>(
        ReaderTaskEither<StepContext, Cause<DiFailure>, Option<A>>.asks(
          (context) => context.environment.contains(key)
              ? Some(context.environment.read(key))
              : const None(),
        ),
      );

  @override
  HKT<_ProgramTag, B> ap<A, B>(
    HKT<_ProgramTag, A> fa,
    HKT<_ProgramTag, B Function(A a)> ff,
  ) => _ProgramOf<B>(
    _programIn(fa).flatMap(
      (a) => _programIn(
        ff,
      ).flatMap((g) => _attempt<B>(() async => Right<Object?, B>(g(a)), null)),
    ),
  );

  @override
  HKT<_ProgramTag, B> step<A, B>(
    HKT<_ProgramTag, A> source,
    StepEffect<A, B> effect,
    StepRelease<B>? release,
  ) => _ProgramOf<B>(
    _programIn(source).flatMap((a) => _attempt<B>(() => effect(a), release)),
  );
}

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
    StepNode<Unit, A>(
      const PureNode(unit),
      (_) async => Right<Object?, A>(await create()),
      dispose,
    ),
  );

  /// A dependency of a [value] that exists already.
  ///
  /// The dependency reads nothing and owns nothing.
  factory Dependency.of(A value) => Dependency._(PureNode<A>(value));

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
    StepNode<Unit, A>(
      const PureNode(unit),
      (_) async => (await create.run()).mapLeft<Object?>((error) => error),
      dispose,
    ),
  );

  /// A dependency that reads the value of [key].
  ///
  /// The key is `DiKey<T>()` when [key] is `null`. A scope or an ancestor
  /// must publish the key.
  static Dependency<T> require<T>({DiKey<T>? key}) =>
      Dependency<T>._(RequireNode<T>(key ?? DiKey<T>()));

  /// A dependency that reads the value of [key] when a scope publishes it.
  ///
  /// The result is `None` when neither the scope nor an ancestor publishes
  /// the key. When the key is present, the activation still waits for the
  /// publisher.
  static Dependency<Option<T>> option<T>({DiKey<T>? key}) =>
      Dependency<Option<T>>._(OptionalNode<T>(key ?? DiKey<T>()));

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

  final DependencyNode<A> _node;

  late final _Reads _reads = _readsIn(_node.fold(const _ReadsAlgebra()));

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
      Dependency<B>._(ApNode<A, B>(_node, f._node));

  /// Creates the next value from this value with [f].
  ///
  /// A throw from [f] becomes an `ActivationFailure`. With [dispose], the
  /// step owns the new value.
  @override
  Dependency<B> map<B>(
    B Function(A value) f, {
    FutureOr<void> Function(B value)? dispose,
  }) => Dependency<B>._(
    StepNode<A, B>(_node, (a) async => Right<Object?, B>(f(a)), dispose),
  );

  /// Runs the task that [f] creates from this value.
  ///
  /// With [dispose], the step owns the result.
  Dependency<B> mapTask<B>(
    Task<B> Function(A value) f, {
    FutureOr<void> Function(B value)? dispose,
  }) => Dependency<B>._(
    StepNode<A, B>(
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
    StepNode<A, B>(
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
TaskEither<Cause<DiFailure>, A> runDependency<A>(
  Dependency<A> dependency,
  StepContext context,
) {
  final program = _programIn(dependency._node.fold(const _ProgramAlgebra()));
  // The adapter from a reader program to a task: it runs when the task runs.
  return TaskEither(() => program.run(context));
}

/// Folds the tree of [dependency] with [algebra].
///
/// The function reads the tree and runs nothing.
HKT<G, A> foldDependency<G, A>(
  Dependency<A> dependency,
  DependencyAlgebra<G> algebra,
) => dependency._node.fold(algebra);

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
