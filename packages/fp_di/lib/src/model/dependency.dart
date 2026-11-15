part of 'lease.dart';

/// A component reads keys through a [Dependency] and builds its value from
/// them.
///
/// A [Dependency] states the keys that the component reads and how it creates
/// its value from them, with an optional `dispose`. It reads keys and never
/// publishes one; the `key` of `Component` adds the publication. Building a
/// [Dependency] does no work. Its shape is derived: [requires] holds the keys
/// that must resolve, and [optional] holds the keys that are read optionally.
/// [collectionKeys] and [optionalCollectionKeys] hold the collection keys that
/// are read strictly and optionally.
///
/// {@category Dependency}
final class Dependency<A> {
  Dependency._(
    this.requires,
    this.optional,
    this._run, {
    this.collectionKeys = _noCollections,
    this.optionalCollectionKeys = _noCollections,
  });

  /// Keys that must resolve before the component may activate.
  final Set<DiKeyBase> requires;

  /// Keys that are read optionally but still tracked for changes.
  final Set<DiKeyBase> optional;

  /// Collection keys whose every contribution must resolve before the
  /// component may activate. They are never in [requires]: an empty collection
  /// is valid.
  final Set<DiCollectionKey<Object?>> collectionKeys;

  /// Collection keys that are read optionally: only the active contributions
  /// are read, and the component never waits for one.
  final Set<DiCollectionKey<Object?>> optionalCollectionKeys;

  final Future<A> Function(DiContext context) _run;

  /// A [Dependency] that reads no key and creates its value with [create] on
  /// each activation.
  ///
  /// Without [dispose] the value needs no dispose; with [dispose] the
  /// component owns the value and disposes it at teardown. It never waits,
  /// because it reads no key. Use `Dependency1` to `Dependency8` to read keys.
  factory Dependency({
    required FutureOr<A> Function() create,
    FutureOr<void> Function(A value)? dispose,
  }) => Dependency<A>._(_noKeys, _noKeys, (context) async {
    context.checkpoint();
    return dispose == null
        ? await create()
        : context.acquire(create, dispose: dispose);
  });

  /// Reads the [CancellationToken] of the activation. It reads no key, so the
  /// shape is unchanged.
  ///
  /// Combine it with the reads of a step, so a long `create` can stop when the
  /// owner is disposed:
  /// `(Dependency.require<Api>(), Dependency.cancellation()).zip.mapN(...)`.
  /// The token stays valid as long as the activation: it is canceled when the
  /// disposal of the owner is requested and when the activation deactivates.
  static Dependency<CancellationToken> cancellation() =>
      Dependency<CancellationToken>._(
        _noKeys,
        _noKeys,
        (context) async => context.cancellation,
      );

  /// Reads [T]. The component waits while the key is unbound.
  ///
  /// This is the one-key form. Use [require2] to [require8] for several keys
  /// at once; there is no `require1`.
  static Dependency<T> require<T>({DiKey<T>? key}) {
    final actual = key ?? DiKey<T>();
    return Dependency<T>._(
      Set<DiKeyBase>.unmodifiable(<DiKeyBase>{actual}),
      _noKeys,
      (context) async => context.require<T>(key: actual),
    );
  }

  /// Reads [T] if it is bound, and reloads when that changes either way.
  static Dependency<T?> maybe<T>({DiKey<T>? key}) {
    final actual = key ?? DiKey<T>();
    return Dependency<T?>._(
      _noKeys,
      Set<DiKeyBase>.unmodifiable(<DiKeyBase>{actual}),
      (context) async => context.maybeGet<T>(key: actual),
    );
  }

  /// Reads every contribution to the set [key], in declaration order,
  /// ancestors first. The component waits while one contribution does not
  /// resolve, and activates again when the contributions change. Equal values
  /// are one element. A set without contributions is empty.
  static Dependency<Set<T>> requireSet<T>({required DiSetKey<T> key}) =>
      Dependency<Set<T>>._(
        _noKeys,
        _noKeys,
        (context) async => context.readSet<T>(key, strict: true),
        collectionKeys: Set<DiCollectionKey<Object?>>.unmodifiable({key}),
      );

  /// Reads the active contributions to the set [key] and never waits. The
  /// component activates again when a contributor activates or deactivates.
  static Dependency<Set<T>> maybeSet<T>({required DiSetKey<T> key}) =>
      Dependency<Set<T>>._(
        _noKeys,
        _noKeys,
        (context) async => context.readSet<T>(key, strict: false),
        optionalCollectionKeys: Set<DiCollectionKey<Object?>>.unmodifiable({
          key,
        }),
      );

  /// Reads the entry of every id of the map [key]. Each id selects the
  /// nearest active entry, as `Dependency.require` of `key.entryKey(id)` does.
  /// The component waits while one id does not resolve.
  static Dependency<Map<String, T>> requireMap<T>({required DiMapKey<T> key}) =>
      Dependency<Map<String, T>>._(
        _noKeys,
        _noKeys,
        (context) async => context.readMap<T>(key, strict: true),
        collectionKeys: Set<DiCollectionKey<Object?>>.unmodifiable({key}),
      );

  /// Reads the entries of the ids of the map [key] that resolve, and never
  /// waits.
  static Dependency<Map<String, T>> maybeMap<T>({required DiMapKey<T> key}) =>
      Dependency<Map<String, T>>._(
        _noKeys,
        _noKeys,
        (context) async => context.readMap<T>(key, strict: false),
        optionalCollectionKeys: Set<DiCollectionKey<Object?>>.unmodifiable({
          key,
        }),
      );

  /// Reads two keys and yields their values as a record, in order.
  ///
  /// Each key defaults to `DiKey<T>()` for its type; pass `key1` to `key2` to
  /// select a named key. The component waits until every key resolves.
  static Dependency<(A, B)> require2<A, B>({DiKey<A>? key1, DiKey<B>? key2}) =>
      _requireAll<(A, B)>(<DiKey<Object?>>[
        key1 ?? DiKey<A>(),
        key2 ?? DiKey<B>(),
      ], (v) => (v[0] as A, v[1] as B));

  /// Reads three keys and yields their values as a record, in order.
  ///
  /// Each key defaults to `DiKey<T>()` for its type; pass `key1` to `key3` to
  /// select a named key. The component waits until every key resolves.
  static Dependency<(A, B, C)> require3<A, B, C>({
    DiKey<A>? key1,
    DiKey<B>? key2,
    DiKey<C>? key3,
  }) => _requireAll<(A, B, C)>(<DiKey<Object?>>[
    key1 ?? DiKey<A>(),
    key2 ?? DiKey<B>(),
    key3 ?? DiKey<C>(),
  ], (v) => (v[0] as A, v[1] as B, v[2] as C));

  /// Reads four keys and yields their values as a record, in order.
  ///
  /// Each key defaults to `DiKey<T>()` for its type; pass `key1` to `key4` to
  /// select a named key. The component waits until every key resolves.
  static Dependency<(A, B, C, D)> require4<A, B, C, D>({
    DiKey<A>? key1,
    DiKey<B>? key2,
    DiKey<C>? key3,
    DiKey<D>? key4,
  }) => _requireAll<(A, B, C, D)>(<DiKey<Object?>>[
    key1 ?? DiKey<A>(),
    key2 ?? DiKey<B>(),
    key3 ?? DiKey<C>(),
    key4 ?? DiKey<D>(),
  ], (v) => (v[0] as A, v[1] as B, v[2] as C, v[3] as D));

  /// Reads five keys and yields their values as a record, in order.
  ///
  /// Each key defaults to `DiKey<T>()` for its type; pass `key1` to `key5` to
  /// select a named key. The component waits until every key resolves.
  static Dependency<(A, B, C, D, E)> require5<A, B, C, D, E>({
    DiKey<A>? key1,
    DiKey<B>? key2,
    DiKey<C>? key3,
    DiKey<D>? key4,
    DiKey<E>? key5,
  }) => _requireAll<(A, B, C, D, E)>(<DiKey<Object?>>[
    key1 ?? DiKey<A>(),
    key2 ?? DiKey<B>(),
    key3 ?? DiKey<C>(),
    key4 ?? DiKey<D>(),
    key5 ?? DiKey<E>(),
  ], (v) => (v[0] as A, v[1] as B, v[2] as C, v[3] as D, v[4] as E));

  /// Reads six keys and yields their values as a record, in order.
  ///
  /// Each key defaults to `DiKey<T>()` for its type; pass `key1` to `key6` to
  /// select a named key. The component waits until every key resolves.
  static Dependency<(A, B, C, D, E, F)> require6<A, B, C, D, E, F>({
    DiKey<A>? key1,
    DiKey<B>? key2,
    DiKey<C>? key3,
    DiKey<D>? key4,
    DiKey<E>? key5,
    DiKey<F>? key6,
  }) => _requireAll<(A, B, C, D, E, F)>(<DiKey<Object?>>[
    key1 ?? DiKey<A>(),
    key2 ?? DiKey<B>(),
    key3 ?? DiKey<C>(),
    key4 ?? DiKey<D>(),
    key5 ?? DiKey<E>(),
    key6 ?? DiKey<F>(),
  ], (v) => (v[0] as A, v[1] as B, v[2] as C, v[3] as D, v[4] as E, v[5] as F));

  /// Reads seven keys and yields their values as a record, in order.
  ///
  /// Each key defaults to `DiKey<T>()` for its type; pass `key1` to `key7` to
  /// select a named key. The component waits until every key resolves.
  static Dependency<(A, B, C, D, E, F, G)> require7<A, B, C, D, E, F, G>({
    DiKey<A>? key1,
    DiKey<B>? key2,
    DiKey<C>? key3,
    DiKey<D>? key4,
    DiKey<E>? key5,
    DiKey<F>? key6,
    DiKey<G>? key7,
  }) => _requireAll<(A, B, C, D, E, F, G)>(
    <DiKey<Object?>>[
      key1 ?? DiKey<A>(),
      key2 ?? DiKey<B>(),
      key3 ?? DiKey<C>(),
      key4 ?? DiKey<D>(),
      key5 ?? DiKey<E>(),
      key6 ?? DiKey<F>(),
      key7 ?? DiKey<G>(),
    ],
    (v) => (
      v[0] as A,
      v[1] as B,
      v[2] as C,
      v[3] as D,
      v[4] as E,
      v[5] as F,
      v[6] as G,
    ),
  );

  /// Reads eight keys and yields their values as a record, in order.
  ///
  /// Each key defaults to `DiKey<T>()` for its type; pass `key1` to `key8` to
  /// select a named key. The component waits until every key resolves.
  static Dependency<(A, B, C, D, E, F, G, H)> require8<A, B, C, D, E, F, G, H>({
    DiKey<A>? key1,
    DiKey<B>? key2,
    DiKey<C>? key3,
    DiKey<D>? key4,
    DiKey<E>? key5,
    DiKey<F>? key6,
    DiKey<G>? key7,
    DiKey<H>? key8,
  }) => _requireAll<(A, B, C, D, E, F, G, H)>(
    <DiKey<Object?>>[
      key1 ?? DiKey<A>(),
      key2 ?? DiKey<B>(),
      key3 ?? DiKey<C>(),
      key4 ?? DiKey<D>(),
      key5 ?? DiKey<E>(),
      key6 ?? DiKey<F>(),
      key7 ?? DiKey<G>(),
      key8 ?? DiKey<H>(),
    ],
    (v) => (
      v[0] as A,
      v[1] as B,
      v[2] as C,
      v[3] as D,
      v[4] as E,
      v[5] as F,
      v[6] as G,
      v[7] as H,
    ),
  );

  static Dependency<R> _requireAll<R>(
    List<DiKey<Object?>> keys,
    R Function(List<Object?> values) build,
  ) => Dependency<R>._(
    Set<DiKeyBase>.unmodifiable(keys),
    _noKeys,
    (context) async => build(<Object?>[
      for (final key in keys) context.require<Object?>(key: key),
    ]),
  );

  /// Creates the next value from this one. The shape is unchanged.
  ///
  /// [create] runs after the earlier steps, at activation, and may be
  /// asynchronous; the runtime checks the cancellation token before it runs.
  /// Without [dispose] it is a plain step, and whatever earlier steps own
  /// stays owned. With [dispose] the component owns the new value and
  /// disposes it before the earlier steps, as a later creation disposes
  /// first.
  Dependency<B> map<B>(
    FutureOr<B> Function(A value) create, {
    FutureOr<void> Function(B value)? dispose,
  }) => Dependency<B>._(
    requires,
    optional,
    collectionKeys: collectionKeys,
    optionalCollectionKeys: optionalCollectionKeys,
    dispose == null
        ? (context) async {
            final value = await _run(context);
            context.checkpoint();
            return create(value);
          }
        : (context) async {
            final value = await _run(context);
            context.checkpoint();
            return context.acquire(() => create(value), dispose: dispose);
          },
  );

  /// Creates the value on the first `Lazy.force`, not at activation.
  ///
  /// The keys are read at activation, so they stay tracked: a change of the
  /// members that publish them reactivates the owner. The steps run on the
  /// first `force`, against the values read at activation. What they create is
  /// disposed with the owner, only if it was created, and before the earlier
  /// creations of the same component. The shape is unchanged.
  Dependency<Lazy<A>> lazy() => Dependency<Lazy<A>>._(
    requires,
    optional,
    collectionKeys: collectionKeys,
    optionalCollectionKeys: optionalCollectionKeys,
    (context) async {
      final values = <DiKeyBase, Object?>{
        for (final key in requires)
          key: context.require<Object?>(key: key as DiKey<Object?>),
        for (final key in optional)
          key: context.maybeGet<Object?>(key: key as DiKey<Object?>),
        for (final key in collectionKeys)
          key: _readCollection(context, key, true),
        for (final key in optionalCollectionKeys)
          key: _readCollection(context, key, false),
      };
      Future<Lease<A>> createDeferred() async {
        // Each creation is a child region of the owner: the owner's
        // cancellation reaches it, and its own failure stays in it.
        final snapshot = _SnapshotContext(
          values,
          CancellationSource.child(context.cancellation),
          () => context.ownerDisposalRequested,
        );
        try {
          final value = await _run(snapshot);
          return Lease<A>(value: value, dispose: snapshot.releaseAll);
        } on Object catch (error, stackTrace) {
          snapshot.cancellation.cancel(CancelReason.failure);
          // Keep the cause, and the releases that failed after it.
          final disposeFailures = await snapshot.releaseFailures();
          if (disposeFailures.isEmpty) rethrow;
          Error.throwWithStackTrace(
            _withRollbackFailures(error, stackTrace, disposeFailures),
            stackTrace,
          );
        }
      }

      return context.acquire(
        () => Lazy<A>._(createDeferred, () => context.ownerDisposalRequested),
        dispose: (holder) => holder._release(),
      );
    },
  );

  @override
  String toString() => 'Dependency<$A>';
}

const Set<DiKeyBase> _noKeys = <DiKeyBase>{};

const Set<DiCollectionKey<Object?>> _noCollections =
    <DiCollectionKey<Object?>>{};

Set<DiCollectionKey<Object?>> _unionCollections(
  Set<DiCollectionKey<Object?>> a,
  Set<DiCollectionKey<Object?>> b,
) {
  if (b.isEmpty || identical(a, b)) return a;
  if (a.isEmpty) return b;
  return Set<DiCollectionKey<Object?>>.unmodifiable({...a, ...b});
}

/// The value of a collection read, typed by its element type `Object?`, for
/// the snapshot of a lazy step.
Object _readCollection(
  DiContext context,
  DiCollectionKey<Object?> key,
  bool strict,
) => switch (key) {
  final DiSetKey<Object?> set => context.readSet<Object?>(set, strict: strict),
  final DiMapKey<Object?> map => context.readMap<Object?>(map, strict: strict),
};

Set<DiKeyBase> _union(Set<DiKeyBase> a, Set<DiKeyBase> b) {
  if (b.isEmpty || identical(a, b)) return a;
  if (a.isEmpty) return b;
  return Set<DiKeyBase>.unmodifiable(<DiKeyBase>{...a, ...b});
}

/// Runs [dependency] in an activation. Only the runtime calls it.
Future<A> runDependency<A>(Dependency<A> dependency, DiContext context) =>
    dependency._run(context);

Dependency<(A, B)> _zip2<A, B>(Dependency<A> left, Dependency<B> right) =>
    Dependency<(A, B)>._(
      _union(left.requires, right.requires),
      _union(left.optional, right.optional),
      collectionKeys: _unionCollections(
        left.collectionKeys,
        right.collectionKeys,
      ),
      optionalCollectionKeys: _unionCollections(
        left.optionalCollectionKeys,
        right.optionalCollectionKeys,
      ),
      (context) async {
        final a = await left._run(context);
        context.checkpoint();
        final b = await right._run(context);
        return (a, b);
      },
    );

/// Applies a function to the values of a `Dependency.require2` or `zip` record.
///
/// {@category Dependency}
extension DependencyOfRecord2<A, B> on Dependency<(A, B)> {
  /// Like [Dependency.map], with the record spread into positional arguments,
  /// so a constructor tear-off works.
  Dependency<R> mapN<R>(
    FutureOr<R> Function(A, B) create, {
    FutureOr<void> Function(R value)? dispose,
  }) => map((v) => create(v.$1, v.$2), dispose: dispose);
}

/// Applies a function to the values of a `Dependency.require3` or `zip` record.
///
/// {@category Dependency}
extension DependencyOfRecord3<A, B, C> on Dependency<(A, B, C)> {
  /// Like [Dependency.map], with the record spread into positional arguments,
  /// so a constructor tear-off works.
  Dependency<R> mapN<R>(
    FutureOr<R> Function(A, B, C) create, {
    FutureOr<void> Function(R value)? dispose,
  }) => map((v) => create(v.$1, v.$2, v.$3), dispose: dispose);
}

/// Applies a function to the values of a `Dependency.require4` or `zip` record.
///
/// {@category Dependency}
extension DependencyOfRecord4<A, B, C, D> on Dependency<(A, B, C, D)> {
  /// Like [Dependency.map], with the record spread into positional arguments,
  /// so a constructor tear-off works.
  Dependency<R> mapN<R>(
    FutureOr<R> Function(A, B, C, D) create, {
    FutureOr<void> Function(R value)? dispose,
  }) => map((v) => create(v.$1, v.$2, v.$3, v.$4), dispose: dispose);
}

/// Applies a function to the values of a `Dependency.require5` or `zip` record.
///
/// {@category Dependency}
extension DependencyOfRecord5<A, B, C, D, E> on Dependency<(A, B, C, D, E)> {
  /// Like [Dependency.map], with the record spread into positional arguments,
  /// so a constructor tear-off works.
  Dependency<R> mapN<R>(
    FutureOr<R> Function(A, B, C, D, E) create, {
    FutureOr<void> Function(R value)? dispose,
  }) => map((v) => create(v.$1, v.$2, v.$3, v.$4, v.$5), dispose: dispose);
}

/// Applies a function to the values of a `Dependency.require6` or `zip` record.
///
/// {@category Dependency}
extension DependencyOfRecord6<A, B, C, D, E, F>
    on Dependency<(A, B, C, D, E, F)> {
  /// Like [Dependency.map], with the record spread into positional arguments,
  /// so a constructor tear-off works.
  Dependency<R> mapN<R>(
    FutureOr<R> Function(A, B, C, D, E, F) create, {
    FutureOr<void> Function(R value)? dispose,
  }) =>
      map((v) => create(v.$1, v.$2, v.$3, v.$4, v.$5, v.$6), dispose: dispose);
}

/// Applies a function to the values of a `Dependency.require7` or `zip` record.
///
/// {@category Dependency}
extension DependencyOfRecord7<A, B, C, D, E, F, G>
    on Dependency<(A, B, C, D, E, F, G)> {
  /// Like [Dependency.map], with the record spread into positional arguments,
  /// so a constructor tear-off works.
  Dependency<R> mapN<R>(
    FutureOr<R> Function(A, B, C, D, E, F, G) create, {
    FutureOr<void> Function(R value)? dispose,
  }) => map(
    (v) => create(v.$1, v.$2, v.$3, v.$4, v.$5, v.$6, v.$7),
    dispose: dispose,
  );
}

/// Applies a function to the values of a `Dependency.require8` or `zip` record.
///
/// {@category Dependency}
extension DependencyOfRecord8<A, B, C, D, E, F, G, H>
    on Dependency<(A, B, C, D, E, F, G, H)> {
  /// Like [Dependency.map], with the record spread into positional arguments,
  /// so a constructor tear-off works.
  Dependency<R> mapN<R>(
    FutureOr<R> Function(A, B, C, D, E, F, G, H) create, {
    FutureOr<void> Function(R value)? dispose,
  }) => map(
    (v) => create(v.$1, v.$2, v.$3, v.$4, v.$5, v.$6, v.$7, v.$8),
    dispose: dispose,
  );
}

/// Combines a record of two [Dependency] values into one [Dependency] of a
/// record.
///
/// {@category Dependency}
extension DependencyRecord2<A, B> on (Dependency<A>, Dependency<B>) {
  /// The values of every [Dependency], in record order.
  ///
  /// The shape is the union of the shapes. The [Dependency] values run left to
  /// right, and their values are disposed right to left.
  Dependency<(A, B)> get zip => _zip2($1, $2);
}

/// Combines a record of three [Dependency] values into one [Dependency] of a
/// record.
///
/// {@category Dependency}
extension DependencyRecord3<A, B, C>
    on (Dependency<A>, Dependency<B>, Dependency<C>) {
  /// The values of every [Dependency], in record order.
  ///
  /// The shape is the union of the shapes. The [Dependency] values run left to
  /// right, and their values are disposed right to left.
  Dependency<(A, B, C)> get zip => _zip2(($1, $2).zip, $3).map((v) {
    final p = v.$1;
    return (p.$1, p.$2, v.$2);
  });
}

/// Combines a record of four [Dependency] values into one [Dependency] of a
/// record.
///
/// {@category Dependency}
extension DependencyRecord4<A, B, C, D>
    on (Dependency<A>, Dependency<B>, Dependency<C>, Dependency<D>) {
  /// The values of every [Dependency], in record order.
  ///
  /// The shape is the union of the shapes. The [Dependency] values run left to
  /// right, and their values are disposed right to left.
  Dependency<(A, B, C, D)> get zip => _zip2(($1, $2, $3).zip, $4).map((v) {
    final p = v.$1;
    return (p.$1, p.$2, p.$3, v.$2);
  });
}

/// Combines a record of five [Dependency] values into one [Dependency] of a
/// record.
///
/// {@category Dependency}
extension DependencyRecord5<A, B, C, D, E>
    on
        (
          Dependency<A>,
          Dependency<B>,
          Dependency<C>,
          Dependency<D>,
          Dependency<E>,
        ) {
  /// The values of every [Dependency], in record order.
  ///
  /// The shape is the union of the shapes. The [Dependency] values run left to
  /// right, and their values are disposed right to left.
  Dependency<(A, B, C, D, E)> get zip =>
      _zip2(($1, $2, $3, $4).zip, $5).map((v) {
        final p = v.$1;
        return (p.$1, p.$2, p.$3, p.$4, v.$2);
      });
}

/// Combines a record of six [Dependency] values into one [Dependency] of a
/// record.
///
/// {@category Dependency}
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
  /// The values of every [Dependency], in record order.
  ///
  /// The shape is the union of the shapes. The [Dependency] values run left to
  /// right, and their values are disposed right to left.
  Dependency<(A, B, C, D, E, F)> get zip =>
      _zip2(($1, $2, $3, $4, $5).zip, $6).map((v) {
        final p = v.$1;
        return (p.$1, p.$2, p.$3, p.$4, p.$5, v.$2);
      });
}

/// Combines a record of seven [Dependency] values into one [Dependency] of a
/// record.
///
/// {@category Dependency}
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
  /// The values of every [Dependency], in record order.
  ///
  /// The shape is the union of the shapes. The [Dependency] values run left to
  /// right, and their values are disposed right to left.
  Dependency<(A, B, C, D, E, F, G)> get zip =>
      _zip2(($1, $2, $3, $4, $5, $6).zip, $7).map((v) {
        final p = v.$1;
        return (p.$1, p.$2, p.$3, p.$4, p.$5, p.$6, v.$2);
      });
}

/// Combines a record of eight [Dependency] values into one [Dependency] of a
/// record.
///
/// {@category Dependency}
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
  /// The values of every [Dependency], in record order.
  ///
  /// The shape is the union of the shapes. The [Dependency] values run left to
  /// right, and their values are disposed right to left.
  Dependency<(A, B, C, D, E, F, G, H)> get zip =>
      _zip2(($1, $2, $3, $4, $5, $6, $7).zip, $8).map((v) {
        final p = v.$1;
        return (p.$1, p.$2, p.$3, p.$4, p.$5, p.$6, p.$7, v.$2);
      });
}

Dependency<R> _built<V, R>(
  Dependency<V> reads,
  FutureOr<R> Function(V values) create,
  FutureOr<void> Function(R value)? dispose,
) => reads.map(create, dispose: dispose);

/// A [Dependency] that reads one key and builds its value from
/// it, like Provider's `ProxyProvider`.
///
/// [create] receives the value. Without [dispose] it is a plain step, as
/// [Dependency.map] is; with [dispose] the value is owned and disposed before
/// the values it reads, as [Dependency.map] with a `dispose` is. Each key
/// defaults to `DiKey<T>()` for its type; pass `key1` to select a named key. A
/// constructor tear-off works, and its parameter types give the type arguments.
///
/// {@category Dependency}
final class Dependency1<A, R> extends Dependency<R> {
  /// Reads the key and builds the value with [create].
  Dependency1({
    DiKey<A>? key1,
    required FutureOr<R> Function(A) create,
    FutureOr<void> Function(R value)? dispose,
  }) : this._from(
         _built(Dependency.require<A>(key: key1), (v) => create(v), dispose),
       );

  Dependency1._from(Dependency<R> built)
    : super._(
        built.requires,
        built.optional,
        built._run,
        collectionKeys: built.collectionKeys,
        optionalCollectionKeys: built.optionalCollectionKeys,
      );
}

/// A [Dependency] that reads two keys and builds its value from
/// them, like Provider's `ProxyProvider2`.
///
/// [create] receives the values in key order. Without [dispose] it is a plain
/// step, as [Dependency.map] is; with [dispose] the value is owned and disposed
/// before the values it reads, as [Dependency.map] with a `dispose` is. Each
/// key defaults to `DiKey<T>()` for its type; pass `key1` to `key2` to select a
/// named key. A constructor tear-off works, and its parameter types give the
/// type arguments.
///
/// {@category Dependency}
final class Dependency2<A, B, R> extends Dependency<R> {
  /// Reads the keys and builds the value with [create].
  Dependency2({
    DiKey<A>? key1,
    DiKey<B>? key2,
    required FutureOr<R> Function(A, B) create,
    FutureOr<void> Function(R value)? dispose,
  }) : this._from(
         _built(
           Dependency.require2<A, B>(key1: key1, key2: key2),
           (v) => create(v.$1, v.$2),
           dispose,
         ),
       );

  Dependency2._from(Dependency<R> built)
    : super._(
        built.requires,
        built.optional,
        built._run,
        collectionKeys: built.collectionKeys,
        optionalCollectionKeys: built.optionalCollectionKeys,
      );
}

/// A [Dependency] that reads three keys and builds its value from
/// them, like Provider's `ProxyProvider3`.
///
/// [create] receives the values in key order. Without [dispose] it is a plain
/// step, as [Dependency.map] is; with [dispose] the value is owned and disposed
/// before the values it reads, as [Dependency.map] with a `dispose` is. Each
/// key defaults to `DiKey<T>()` for its type; pass `key1` to `key3` to select a
/// named key. A constructor tear-off works, and its parameter types give the
/// type arguments.
///
/// {@category Dependency}
final class Dependency3<A, B, C, R> extends Dependency<R> {
  /// Reads the keys and builds the value with [create].
  Dependency3({
    DiKey<A>? key1,
    DiKey<B>? key2,
    DiKey<C>? key3,
    required FutureOr<R> Function(A, B, C) create,
    FutureOr<void> Function(R value)? dispose,
  }) : this._from(
         _built(
           Dependency.require3<A, B, C>(key1: key1, key2: key2, key3: key3),
           (v) => create(v.$1, v.$2, v.$3),
           dispose,
         ),
       );

  Dependency3._from(Dependency<R> built)
    : super._(
        built.requires,
        built.optional,
        built._run,
        collectionKeys: built.collectionKeys,
        optionalCollectionKeys: built.optionalCollectionKeys,
      );
}

/// A [Dependency] that reads four keys and builds its value from
/// them, like Provider's `ProxyProvider4`.
///
/// [create] receives the values in key order. Without [dispose] it is a plain
/// step, as [Dependency.map] is; with [dispose] the value is owned and disposed
/// before the values it reads, as [Dependency.map] with a `dispose` is. Each
/// key defaults to `DiKey<T>()` for its type; pass `key1` to `key4` to select a
/// named key. A constructor tear-off works, and its parameter types give the
/// type arguments.
///
/// {@category Dependency}
final class Dependency4<A, B, C, D, R> extends Dependency<R> {
  /// Reads the keys and builds the value with [create].
  Dependency4({
    DiKey<A>? key1,
    DiKey<B>? key2,
    DiKey<C>? key3,
    DiKey<D>? key4,
    required FutureOr<R> Function(A, B, C, D) create,
    FutureOr<void> Function(R value)? dispose,
  }) : this._from(
         _built(
           Dependency.require4<A, B, C, D>(
             key1: key1,
             key2: key2,
             key3: key3,
             key4: key4,
           ),
           (v) => create(v.$1, v.$2, v.$3, v.$4),
           dispose,
         ),
       );

  Dependency4._from(Dependency<R> built)
    : super._(
        built.requires,
        built.optional,
        built._run,
        collectionKeys: built.collectionKeys,
        optionalCollectionKeys: built.optionalCollectionKeys,
      );
}

/// A [Dependency] that reads five keys and builds its value from
/// them, like Provider's `ProxyProvider5`.
///
/// [create] receives the values in key order. Without [dispose] it is a plain
/// step, as [Dependency.map] is; with [dispose] the value is owned and disposed
/// before the values it reads, as [Dependency.map] with a `dispose` is. Each
/// key defaults to `DiKey<T>()` for its type; pass `key1` to `key5` to select a
/// named key. A constructor tear-off works, and its parameter types give the
/// type arguments.
///
/// {@category Dependency}
final class Dependency5<A, B, C, D, E, R> extends Dependency<R> {
  /// Reads the keys and builds the value with [create].
  Dependency5({
    DiKey<A>? key1,
    DiKey<B>? key2,
    DiKey<C>? key3,
    DiKey<D>? key4,
    DiKey<E>? key5,
    required FutureOr<R> Function(A, B, C, D, E) create,
    FutureOr<void> Function(R value)? dispose,
  }) : this._from(
         _built(
           Dependency.require5<A, B, C, D, E>(
             key1: key1,
             key2: key2,
             key3: key3,
             key4: key4,
             key5: key5,
           ),
           (v) => create(v.$1, v.$2, v.$3, v.$4, v.$5),
           dispose,
         ),
       );

  Dependency5._from(Dependency<R> built)
    : super._(
        built.requires,
        built.optional,
        built._run,
        collectionKeys: built.collectionKeys,
        optionalCollectionKeys: built.optionalCollectionKeys,
      );
}

/// A [Dependency] that reads six keys and builds its value from
/// them, like Provider's `ProxyProvider6`.
///
/// [create] receives the values in key order. Without [dispose] it is a plain
/// step, as [Dependency.map] is; with [dispose] the value is owned and disposed
/// before the values it reads, as [Dependency.map] with a `dispose` is. Each
/// key defaults to `DiKey<T>()` for its type; pass `key1` to `key6` to select a
/// named key. A constructor tear-off works, and its parameter types give the
/// type arguments.
///
/// {@category Dependency}
final class Dependency6<A, B, C, D, E, F, R> extends Dependency<R> {
  /// Reads the keys and builds the value with [create].
  Dependency6({
    DiKey<A>? key1,
    DiKey<B>? key2,
    DiKey<C>? key3,
    DiKey<D>? key4,
    DiKey<E>? key5,
    DiKey<F>? key6,
    required FutureOr<R> Function(A, B, C, D, E, F) create,
    FutureOr<void> Function(R value)? dispose,
  }) : this._from(
         _built(
           Dependency.require6<A, B, C, D, E, F>(
             key1: key1,
             key2: key2,
             key3: key3,
             key4: key4,
             key5: key5,
             key6: key6,
           ),
           (v) => create(v.$1, v.$2, v.$3, v.$4, v.$5, v.$6),
           dispose,
         ),
       );

  Dependency6._from(Dependency<R> built)
    : super._(
        built.requires,
        built.optional,
        built._run,
        collectionKeys: built.collectionKeys,
        optionalCollectionKeys: built.optionalCollectionKeys,
      );
}

/// A [Dependency] that reads seven keys and builds its value from
/// them, like Provider's `ProxyProvider7`.
///
/// [create] receives the values in key order. Without [dispose] it is a plain
/// step, as [Dependency.map] is; with [dispose] the value is owned and disposed
/// before the values it reads, as [Dependency.map] with a `dispose` is. Each
/// key defaults to `DiKey<T>()` for its type; pass `key1` to `key7` to select a
/// named key. A constructor tear-off works, and its parameter types give the
/// type arguments.
///
/// {@category Dependency}
final class Dependency7<A, B, C, D, E, F, G, R> extends Dependency<R> {
  /// Reads the keys and builds the value with [create].
  Dependency7({
    DiKey<A>? key1,
    DiKey<B>? key2,
    DiKey<C>? key3,
    DiKey<D>? key4,
    DiKey<E>? key5,
    DiKey<F>? key6,
    DiKey<G>? key7,
    required FutureOr<R> Function(A, B, C, D, E, F, G) create,
    FutureOr<void> Function(R value)? dispose,
  }) : this._from(
         _built(
           Dependency.require7<A, B, C, D, E, F, G>(
             key1: key1,
             key2: key2,
             key3: key3,
             key4: key4,
             key5: key5,
             key6: key6,
             key7: key7,
           ),
           (v) => create(v.$1, v.$2, v.$3, v.$4, v.$5, v.$6, v.$7),
           dispose,
         ),
       );

  Dependency7._from(Dependency<R> built)
    : super._(
        built.requires,
        built.optional,
        built._run,
        collectionKeys: built.collectionKeys,
        optionalCollectionKeys: built.optionalCollectionKeys,
      );
}

/// A [Dependency] that reads eight keys and builds its value from
/// them, like Provider's `ProxyProvider8`.
///
/// [create] receives the values in key order. Without [dispose] it is a plain
/// step, as [Dependency.map] is; with [dispose] the value is owned and disposed
/// before the values it reads, as [Dependency.map] with a `dispose` is. Each
/// key defaults to `DiKey<T>()` for its type; pass `key1` to `key8` to select a
/// named key. A constructor tear-off works, and its parameter types give the
/// type arguments.
///
/// {@category Dependency}
final class Dependency8<A, B, C, D, E, F, G, H, R> extends Dependency<R> {
  /// Reads the keys and builds the value with [create].
  Dependency8({
    DiKey<A>? key1,
    DiKey<B>? key2,
    DiKey<C>? key3,
    DiKey<D>? key4,
    DiKey<E>? key5,
    DiKey<F>? key6,
    DiKey<G>? key7,
    DiKey<H>? key8,
    required FutureOr<R> Function(A, B, C, D, E, F, G, H) create,
    FutureOr<void> Function(R value)? dispose,
  }) : this._from(
         _built(
           Dependency.require8<A, B, C, D, E, F, G, H>(
             key1: key1,
             key2: key2,
             key3: key3,
             key4: key4,
             key5: key5,
             key6: key6,
             key7: key7,
             key8: key8,
           ),
           (v) => create(v.$1, v.$2, v.$3, v.$4, v.$5, v.$6, v.$7, v.$8),
           dispose,
         ),
       );

  Dependency8._from(Dependency<R> built)
    : super._(
        built.requires,
        built.optional,
        built._run,
        collectionKeys: built.collectionKeys,
        optionalCollectionKeys: built.optionalCollectionKeys,
      );
}

/// Serves the values read at activation to the deferred steps of a lazy
/// [Dependency], and owns what those steps create.
final class _SnapshotContext implements DiContext {
  _SnapshotContext(this._values, this.cancellation, this._ownerClosed);

  final bool Function() _ownerClosed;

  @override
  bool get ownerDisposalRequested => _ownerClosed();

  final Map<DiKeyBase, Object?> _values;

  @override
  final CancellationSource cancellation;

  @override
  void checkpoint() {
    if (cancellation.isCanceled) throw ActivationCanceledException();
  }

  final List<DisposeFunction> _releases = <DisposeFunction>[];

  @override
  T require<T>({DiKey<T>? key}) => _values[key ?? DiKey<T>()] as T;

  @override
  T? maybeGet<T>({DiKey<T>? key}) => _values[key ?? DiKey<T>()] as T?;

  @override
  T publish<T>(T value, {required DiKey<T> key}) =>
      throw StateError('A Dependency never publishes.');

  @override
  Set<T> readSet<T>(DiSetKey<T> key, {required bool strict}) =>
      Set<T>.of((_values[key]! as Set<Object?>).cast<T>());

  @override
  Map<String, T> readMap<T>(DiMapKey<T> key, {required bool strict}) =>
      Map<String, T>.of(
        (_values[key]! as Map<String, Object?>).cast<String, T>(),
      );

  @override
  void contribute(Object? value) =>
      throw StateError('A Dependency never publishes.');

  @override
  Future<B> acquire<B>(
    FutureOr<B> Function() create, {
    FutureOr<void> Function(B value)? dispose,
  }) async {
    final lease = await createLease(create, dispose);
    _releases.add(lease.dispose);
    return lease.value;
  }

  Future<void> releaseAll() async {
    final disposeFailures = await releaseFailures();
    if (disposeFailures.isNotEmpty) throw DisposeException(disposeFailures);
  }

  /// Releases in reverse order and returns the failures instead of throwing.
  Future<List<DisposeFailure>> releaseFailures() async {
    final disposeFailures = await _releaseAll(
      'Dependency.lazy',
      _releases.reversed.toList(),
    );
    _releases.clear();
    return disposeFailures;
  }
}

/// [error] of a failed `Lazy` creation with the [disposeFailures] of its
/// rollback.
Object _withRollbackFailures(
  Object error,
  StackTrace stackTrace,
  List<DisposeFailure> disposeFailures,
) => switch (error) {
  ActivationException() => ActivationException(
    error.cause,
    error.stackTrace,
    <DisposeFailure>[...error.rollbackFailures, ...disposeFailures],
  ),
  ActivationCanceledException() => ActivationCanceledException(
    cause: error.cause,
    stackTrace: error.stackTrace,
    rollbackFailures: <DisposeFailure>[
      ...error.rollbackFailures,
      ...disposeFailures,
    ],
  ),
  _ => ActivationException(error, stackTrace, disposeFailures),
};
