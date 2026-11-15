import 'dart:async';

import 'package:fpdart/fpdart.dart';

import 'cancellation.dart';
import 'cause.dart';
import 'failure.dart';
import 'finalizers.dart';
import 'key.dart';
import 'lazy.dart';
import 'syntax.dart';

/// The type tag of [Dependency] for the fpdart higher-kinded types.
abstract final class _DependencyHKT {}

/// The context of one component while the runtime creates its value.
///
/// The context holds the owner label, the reads of the activation, the check
/// that tells whether a caller canceled the activation, and the place where
/// the steps register the dispose functions of the values that they own. The
/// runtime creates one context for each activation of a component.
///
/// The functions of the context read the state of the runtime when a step
/// runs, so a read sees the publishers of that moment. A read records the
/// publisher that it saw.
final class StepContext {
  /// Creates the context of the component with the label [owner].
  const StepContext({
    required this.owner,
    required this.finalizers,
    required this.read,
    required this.readOption,
    required this.readCollection,
    required this.checkpoint,
    required this.cancellation,
    required this.ownerClosed,
  });

  /// The label of the component.
  final String owner;

  /// The dispose functions of the values that the component owns.
  final IORef<Finalizers> finalizers;

  /// A required read of a key: the value, or the cause of the failed read.
  final Either<Cause<DiFailure>, Object?> Function(DiKey<Object?> key) read;

  /// An optional read of a key: the value when a publisher resolves.
  final Option<Object?> Function(DiKey<Object?> key) readOption;

  /// A read of a collection: a `Set<Object?>` for a [DiSetKey], and a
  /// `Map<String, Object?>` for a [DiMapKey]. A strict read fails when a
  /// contribution does not resolve.
  final Either<Cause<DiFailure>, Object> Function(
    DiCollectionKey<Object?> key, {
    required bool strict,
  })
  readCollection;

  /// The token of the activation.
  final CancellationToken cancellation;

  /// Whether the disposal of the owner of the activation was requested.
  final bool Function() ownerClosed;

  /// Gives a `Left` with an [Interrupt] when a caller canceled the
  /// activation.
  ///
  /// A step runs the check before it starts.
  final Either<Cause<DiFailure>, Unit> Function() checkpoint;
}

/// A step program: the form that a dependency has after the interpreter ran.
typedef _Program<A> = ReaderTaskEither<StepContext, Cause<DiFailure>, A>;

/// The reads of a dependency.
typedef _Reads = ({
  Set<DiKey<Object?>> requires,
  Set<DiKey<Object?>> optional,
  Set<DiCollectionKey<Object?>> collections,
  Set<DiCollectionKey<Object?>> optionalCollections,
});

const _Reads _noReads = (
  requires: <DiKey<Object?>>{},
  optional: <DiKey<Object?>>{},
  collections: <DiCollectionKey<Object?>>{},
  optionalCollections: <DiCollectionKey<Object?>>{},
);

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
  collections: Set.unmodifiable({...left.collections, ...right.collections}),
  optionalCollections: Set.unmodifiable({
    ...left.optionalCollections,
    ...right.optionalCollections,
  }),
);

/// The interpreter that folds a tree into the keys that it reads.
final class _ReadsAlgebra implements DependencyAlgebra<_ReadsTag> {
  const _ReadsAlgebra();

  @override
  HKT<_ReadsTag, A> pure<A>(A value) => _ReadsOf<A>(_noReads);

  @override
  HKT<_ReadsTag, A> require<A>(DiKey<A> key) => _ReadsOf<A>((
    requires: Set.unmodifiable({key}),
    optional: _noReads.optional,
    collections: _noReads.collections,
    optionalCollections: _noReads.optionalCollections,
  ));

  @override
  HKT<_ReadsTag, Option<A>> optional<A>(DiKey<A> key) => _ReadsOf<Option<A>>((
    requires: _noReads.requires,
    optional: Set.unmodifiable({key}),
    collections: _noReads.collections,
    optionalCollections: _noReads.optionalCollections,
  ));

  @override
  HKT<_ReadsTag, Set<A>> collectionSet<A>(
    DiSetKey<A> key, {
    required bool strict,
  }) => _ReadsOf<Set<A>>(_collection(key, strict));

  @override
  HKT<_ReadsTag, Map<String, A>> collectionMap<A>(
    DiMapKey<A> key, {
    required bool strict,
  }) => _ReadsOf<Map<String, A>>(_collection(key, strict));

  @override
  HKT<_ReadsTag, CancellationToken> cancellation() =>
      _ReadsOf<CancellationToken>(_noReads);

  @override
  HKT<_ReadsTag, Lazy<A>> lazy<A>(
    HKT<_ReadsTag, A> source,
    DependencyNode<A> tree,
  ) => _ReadsOf<Lazy<A>>(_readsIn(source));

  _Reads _collection(DiCollectionKey<Object?> key, bool strict) => (
    requires: _noReads.requires,
    optional: _noReads.optional,
    collections: strict ? Set.unmodifiable({key}) : _noReads.collections,
    optionalCollections: strict
        ? _noReads.optionalCollections
        : Set.unmodifiable({key}),
  );

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

/// The values that a lazy step reads when its owner activates.
///
/// A required read and an optional read of one key are two reads, so the
/// snapshot keeps them in two maps.
typedef _Snapshot = ({
  Map<DiKey<Object?>, Object?> required,
  Map<DiKey<Object?>, Option<Object?>> optional,
  Map<DiCollectionKey<Object?>, Object> collections,
});

/// The snapshot of the reads [reads] of a lazy step.
///
/// A required read that fails fails the activation. An optional read gives its
/// `Option`. The snapshot serves the deferred steps later.
Either<Cause<DiFailure>, _Snapshot> _snapshot(
  StepContext context,
  _Reads reads,
) {
  final required = <DiKey<Object?>, Object?>{};
  final optional = <DiKey<Object?>, Option<Object?>>{};
  final collections = <DiCollectionKey<Object?>, Object>{};
  for (final key in reads.requires) {
    final read = context.read(key);
    if (read.isLeft()) {
      return read.map(
        (_) =>
            (required: required, optional: optional, collections: collections),
      );
    }
    required[key] = read.getOrElse((_) => null);
  }
  for (final key in reads.optional) {
    optional[key] = context.readOption(key);
  }
  // A key that a step reads strictly and optionally keeps the strict read.
  for (final (keys, strict) in [
    (reads.optionalCollections, false),
    (reads.collections, true),
  ]) {
    for (final key in keys) {
      final read = context.readCollection(key, strict: strict);
      if (read.isLeft()) {
        return read.map(
          (_) => (
            required: required,
            optional: optional,
            collections: collections,
          ),
        );
      }
      collections[key] = read.getOrElse((_) => const <Object?>{});
    }
  }
  return Right((
    required: required,
    optional: optional,
    collections: collections,
  ));
}

/// The creation of a [Lazy]: it runs the steps of the source against the
/// snapshot, in a region of its own.
///
/// The token of the region is a child of the token of the owner. A failed
/// creation cancels the token of its region before it releases its steps, and
/// the owner stays as it is.
Future<Either<Cause<DiFailure>, (A, Finalizers)>> _createDeferred<A>(
  _Program<A> program,
  StepContext owner,
  _Snapshot values,
) async {
  final region = CancellationSource.child(owner.cancellation);
  final owned = IORef.create<Finalizers>(Finalizers.empty).run();
  final snapshot = StepContext(
    owner: owner.owner,
    finalizers: owned,
    read: (key) => values.required.containsKey(key)
        ? Right<Cause<DiFailure>, Object?>(values.required[key])
        : Left<Cause<DiFailure>, Object?>(
            Fail<DiFailure>(UnavailableKeyFailure(key), StackTrace.current),
          ),
    readOption: (key) => values.optional[key] ?? const None(),
    readCollection: (key, {required strict}) =>
        switch (values.collections[key]) {
          final Set<Object?> set => Right<Cause<DiFailure>, Object>(
            Set<Object?>.of(set),
          ),
          final Map<String, Object?> map => Right<Cause<DiFailure>, Object>(
            Map<String, Object?>.of(map),
          ),
          _ => Left<Cause<DiFailure>, Object>(
            Fail<DiFailure>(UnavailableKeyFailure(key), StackTrace.current),
          ),
        },
    checkpoint: () => region.isCanceled
        ? Left<Cause<DiFailure>, Unit>(Interrupt<DiFailure>(StackTrace.current))
        : const Right<Cause<DiFailure>, Unit>(unit),
    cancellation: region,
    ownerClosed: owner.ownerClosed,
  );
  final ran = await program.run(snapshot);
  return switch (ran) {
    Left(value: final cause) => await () async {
      region.cancel(CancelReason.failure);
      final rollback = await owned.read().run().release().run();
      return Left<Cause<DiFailure>, (A, Finalizers)>(cause + rollback);
    }(),
    Right(value: final value) => Right<Cause<DiFailure>, (A, Finalizers)>((
      value,
      owned.read().run(),
    )),
  };
}

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
      TaskEither<Cause<DiFailure>, Unit>.fromEither(
        context.checkpoint(),
      ).flatMap(
        (_) =>
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
      ),
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
    _withContext<A>(
      (context) => TaskEither<Cause<DiFailure>, A>.fromEither(
        context.read(key).map((value) => value as A),
      ),
    ),
  );

  @override
  HKT<_ProgramTag, Option<A>> optional<A>(DiKey<A> key) =>
      _ProgramOf<Option<A>>(
        ReaderTaskEither<StepContext, Cause<DiFailure>, Option<A>>.asks(
          (context) => context.readOption(key).map((value) => value as A),
        ),
      );

  @override
  HKT<_ProgramTag, Set<A>> collectionSet<A>(
    DiSetKey<A> key, {
    required bool strict,
  }) => _ProgramOf<Set<A>>(
    _withContext<Set<A>>(
      (context) => TaskEither<Cause<DiFailure>, Set<A>>.fromEither(
        context
            .readCollection(key, strict: strict)
            .map((value) => Set<A>.of((value as Set<Object?>).cast<A>())),
      ),
    ),
  );

  @override
  HKT<_ProgramTag, Map<String, A>> collectionMap<A>(
    DiMapKey<A> key, {
    required bool strict,
  }) => _ProgramOf<Map<String, A>>(
    _withContext<Map<String, A>>(
      (context) => TaskEither<Cause<DiFailure>, Map<String, A>>.fromEither(
        context
            .readCollection(key, strict: strict)
            .map(
              (value) => Map<String, A>.of(
                (value as Map<String, Object?>).cast<String, A>(),
              ),
            ),
      ),
    ),
  );

  @override
  HKT<_ProgramTag, CancellationToken> cancellation() =>
      _ProgramOf<CancellationToken>(
        _withContext<CancellationToken>(
          (context) => TaskEither<Cause<DiFailure>, CancellationToken>.right(
            context.cancellation,
          ),
        ),
      );

  @override
  HKT<_ProgramTag, Lazy<A>> lazy<A>(
    HKT<_ProgramTag, A> source,
    DependencyNode<A> tree,
  ) {
    final reads = _readsIn(tree.fold(const _ReadsAlgebra()));
    final program = _programIn(source);
    return _ProgramOf<Lazy<A>>(
      _withContext<Lazy<A>>(
        (context) => TaskEither<Cause<DiFailure>, Lazy<A>>.fromEither(
          _snapshot(context, reads).map((values) {
            final holder = createLazy<A>(
              () => _createDeferred(program, context, values),
              context.ownerClosed,
            );
            // The holder is an owned value at the position of this step.
            context.finalizers
                .modify((owned) => owned.pushCause(() => holder.release()))
                .run();
            return holder;
          }),
        ),
      ),
    );
  }

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
  /// The result is `None` when no scope resolves the key at the moment that
  /// the activation reads it. A later publisher makes the runtime release the
  /// value and create it again.
  static Dependency<Option<T>> option<T>({DiKey<T>? key}) =>
      Dependency<Option<T>>._(OptionalNode<T>(key ?? DiKey<T>()));

  /// A dependency that reads the set of the contributions to [key].
  ///
  /// The set holds the value of each `Component.into` of the key, in the order
  /// of the declarations: the ancestors first, then the scope of the reader.
  /// Equal values give one element. The component of the reader does not count
  /// as a member of the set that it contributes to. A scope that has no
  /// contribution gives an empty set.
  ///
  /// The read waits until every contribution resolves, so the node of the
  /// reader waits and `missing` names [key]. The reader releases and activates
  /// again when a contribution joins or leaves, or when its publisher changes.
  static Dependency<Set<T>> requireSet<T>({required DiSetKey<T> key}) =>
      Dependency<Set<T>>._(SetNode<T>(key, strict: true));

  /// Like [requireSet], and the read never waits.
  ///
  /// The set holds the contributions that resolve now. The reader still
  /// activates again when a contribution resolves or leaves.
  static Dependency<Set<T>> optionSet<T>({required DiSetKey<T> key}) =>
      Dependency<Set<T>>._(SetNode<T>(key, strict: false));

  /// A dependency that reads the map of the entries of [key], by id.
  ///
  /// An entry is a component that publishes `key.entryKey(id)`. The map keeps
  /// the order of the first declaration of each id. A nearer scope that
  /// publishes an entry of the same id gives the value, and a dormant nearer
  /// entry leaves the entry of the ancestor selected. The read waits until
  /// every declared id resolves.
  static Dependency<Map<String, T>> requireMap<T>({required DiMapKey<T> key}) =>
      Dependency<Map<String, T>>._(MapNode<T>(key, strict: true));

  /// Like [requireMap], and the read never waits.
  static Dependency<Map<String, T>> optionMap<T>({required DiMapKey<T> key}) =>
      Dependency<Map<String, T>>._(MapNode<T>(key, strict: false));

  /// A dependency of the cancellation token of the activation.
  ///
  /// The token reads no key and owns nothing. See [CancellationToken] for the
  /// moments at which the runtime cancels it.
  static Dependency<CancellationToken> cancellation() =>
      Dependency<CancellationToken>._(const CancellationNode());

  /// A dependency of the keys [key1] and [key2], as a record.
  ///
  /// The reads are the same as the reads of `(require, require).zip`. The
  /// key of each position is `DiKey<T>()` when its argument is `null`.
  static Dependency<(A, B)> require2<A, B>({DiKey<A>? key1, DiKey<B>? key2}) =>
      (Dependency.require<A>(key: key1), Dependency.require<B>(key: key2)).zip;

  /// A dependency of three keys, as a record. See [require2].
  static Dependency<(A, B, C)> require3<A, B, C>({
    DiKey<A>? key1,
    DiKey<B>? key2,
    DiKey<C>? key3,
  }) => (
    Dependency.require<A>(key: key1),
    Dependency.require<B>(key: key2),
    Dependency.require<C>(key: key3),
  ).zip;

  /// A dependency of four keys, as a record. See [require2].
  static Dependency<(A, B, C, D)> require4<A, B, C, D>({
    DiKey<A>? key1,
    DiKey<B>? key2,
    DiKey<C>? key3,
    DiKey<D>? key4,
  }) => (
    Dependency.require<A>(key: key1),
    Dependency.require<B>(key: key2),
    Dependency.require<C>(key: key3),
    Dependency.require<D>(key: key4),
  ).zip;

  /// A dependency of five keys, as a record. See [require2].
  static Dependency<(A, B, C, D, E)> require5<A, B, C, D, E>({
    DiKey<A>? key1,
    DiKey<B>? key2,
    DiKey<C>? key3,
    DiKey<D>? key4,
    DiKey<E>? key5,
  }) => (
    Dependency.require<A>(key: key1),
    Dependency.require<B>(key: key2),
    Dependency.require<C>(key: key3),
    Dependency.require<D>(key: key4),
    Dependency.require<E>(key: key5),
  ).zip;

  /// A dependency of six keys, as a record. See [require2].
  static Dependency<(A, B, C, D, E, F)> require6<A, B, C, D, E, F>({
    DiKey<A>? key1,
    DiKey<B>? key2,
    DiKey<C>? key3,
    DiKey<D>? key4,
    DiKey<E>? key5,
    DiKey<F>? key6,
  }) => (
    Dependency.require<A>(key: key1),
    Dependency.require<B>(key: key2),
    Dependency.require<C>(key: key3),
    Dependency.require<D>(key: key4),
    Dependency.require<E>(key: key5),
    Dependency.require<F>(key: key6),
  ).zip;

  /// A dependency of seven keys, as a record. See [require2].
  static Dependency<(A, B, C, D, E, F, G)> require7<A, B, C, D, E, F, G>({
    DiKey<A>? key1,
    DiKey<B>? key2,
    DiKey<C>? key3,
    DiKey<D>? key4,
    DiKey<E>? key5,
    DiKey<F>? key6,
    DiKey<G>? key7,
  }) => (
    Dependency.require<A>(key: key1),
    Dependency.require<B>(key: key2),
    Dependency.require<C>(key: key3),
    Dependency.require<D>(key: key4),
    Dependency.require<E>(key: key5),
    Dependency.require<F>(key: key6),
    Dependency.require<G>(key: key7),
  ).zip;

  /// A dependency of eight keys, as a record. See [require2].
  static Dependency<(A, B, C, D, E, F, G, H)> require8<A, B, C, D, E, F, G, H>({
    DiKey<A>? key1,
    DiKey<B>? key2,
    DiKey<C>? key3,
    DiKey<D>? key4,
    DiKey<E>? key5,
    DiKey<F>? key6,
    DiKey<G>? key7,
    DiKey<H>? key8,
  }) => (
    Dependency.require<A>(key: key1),
    Dependency.require<B>(key: key2),
    Dependency.require<C>(key: key3),
    Dependency.require<D>(key: key4),
    Dependency.require<E>(key: key5),
    Dependency.require<F>(key: key6),
    Dependency.require<G>(key: key7),
    Dependency.require<H>(key: key8),
  ).zip;

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

  /// The collection keys that the dependency reads strictly.
  ///
  /// A collection key is never in [requires].
  Set<DiCollectionKey<Object?>> get collectionKeys => _reads.collections;

  /// The collection keys that the dependency reads without a wait.
  Set<DiCollectionKey<Object?>> get optionalCollectionKeys =>
      _reads.optionalCollections;

  /// A dependency of a [Lazy] that runs the steps of this dependency on its
  /// first use.
  ///
  /// The reads are the same as the reads of this dependency. When the owner
  /// activates, it reads each key and keeps the values. The steps run on the
  /// first `Lazy.force`, against those values, in a region of their own. The
  /// holder is an owned value: the owner releases it, and the value that it
  /// created, at its position in the order of the steps. The owner activates
  /// again with a new holder when a publisher of a read key changes, and the
  /// old holder then fails with a `DisposedLazyFailure`.
  Dependency<Lazy<A>> lazy() => Dependency<Lazy<A>>._(LazyNode<A>(_node));

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
