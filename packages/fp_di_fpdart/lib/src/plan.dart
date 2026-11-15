// Internal type. The library file does not export this file.
import 'package:fpdart/fpdart.dart';

import 'cause.dart';
import 'component.dart';
import 'environment.dart';
import 'failure.dart';
import 'finalizers.dart';
import 'key.dart';

/// The components of a scope, in strata.
///
/// A component is in the stratum after the strata of the components that it
/// reads. The components of one stratum keep the declaration order.
typedef Strata = List<List<Component<Object?>>>;

/// What a stratum or a sequence of strata committed, and how it failed.
typedef _Settled = ({Cause<DiFailure> failure, Built built});

/// The pure plan of a scope: a function of the components and of the keys
/// that the ancestors publish.
abstract final class Plan {
  /// Checks [components] and groups them in strata.
  ///
  /// The check is an applicative validation. It reports every duplicate key
  /// first, and then every undeclared key, each in declaration order. The
  /// failures combine with `&`. The check for a cycle runs only when the
  /// first two checks pass. The check reads only [components] and
  /// [ancestors], and it creates no value.
  static Exit<DiFailure, Strata> of(
    List<Component<Object?>> components,
    List<Set<DiKey<Object?>>> ancestors,
  ) {
    final labels = <DiKey<Object?>, List<String>>{};
    for (final component in components) {
      (labels[component.key] ??= []).add(component.label);
    }
    final invalid =
        _duplicates(labels) & _undeclared(components, labels, ancestors);
    if (!invalid.isEmpty) return Left(invalid);
    return _strata(components, {...labels.keys}, [], const {}, components);
  }

  /// Interprets [strata] as one build: the `>+>` of ZIO over components.
  ///
  /// A component is a function from an environment to a `TaskEither`. A
  /// stratum is the parallel combination of its components: they read the
  /// same environment, start together, and all settle. The strata accumulate
  /// in order. Each stratum reads the environment with the outputs of the
  /// strata before it. The output is [input] with the outputs of all strata
  /// on top.
  ///
  /// When a component fails, the later strata do not start. One release
  /// folds the committed values in reverse order: the strata one after the
  /// other (`+`), and the members of one stratum at the same time (`&`). The
  /// cause is the failures of the stratum followed by the release cause.
  static TaskEither<Cause<DiFailure>, Built> build(
    Strata strata,
    Environment input,
  ) =>
      TaskEither<Cause<DiFailure>, _Settled>.fromTask(
        _accumulate(input, Finalizers.monoid.empty, strata),
      ).flatMap(
        (settled) => settled.failure.isEmpty
            ? TaskEither<Cause<DiFailure>, Built>.right(settled.built)
            : TaskEither<Cause<DiFailure>, Cause<DiFailure>>.fromTask(
                settled.built.$2.release(),
              ).flatMap(
                (rollback) => TaskEither<Cause<DiFailure>, Built>.left(
                  settled.failure + rollback,
                ),
              ),
      );

  /// The sequential accumulation of the strata.
  static Task<_Settled> _accumulate(
    Environment environment,
    Finalizers finalizers,
    Strata rest,
  ) {
    if (rest.isEmpty) {
      return Task.of((
        failure: const Empty<DiFailure>(),
        built: (environment, finalizers),
      ));
    }
    return _parallel(rest.first, environment).flatMap((settled) {
      final grown = Environment.monoid.combine(environment, settled.built.$1);
      final stack = Finalizers.monoid.combine(finalizers, settled.built.$2);
      return settled.failure.isEmpty
          ? _accumulate(grown, stack, rest.sublist(1))
          : Task.of((failure: settled.failure, built: (grown, stack)));
    });
  }

  /// The parallel combination of the components of one stratum.
  ///
  /// The failures combine with `&`, in declaration order. The built part
  /// holds the components that succeeded: their outputs stack, and their
  /// finalizers are one group.
  static Task<_Settled> _parallel(
    List<Component<Object?>> stratum,
    Environment input,
  ) =>
      Task.traverseList(
        stratum,
        (component) => buildComponent(component, input).match(
          Left<Cause<DiFailure>, Built>.new,
          Right<Cause<DiFailure>, Built>.new,
        ),
      ).map((results) {
        final failures = [
          for (final result in results) ?result.getLeft().toNullable(),
        ];
        final built = [
          for (final result in results) ?result.getRight().toNullable(),
        ];
        return (
          failure: _all(failures),
          built: (
            built.fold(
              Environment.empty,
              (out, next) => Environment.monoid.combine(out, next.$1),
            ),
            Finalizers.empty.pushGroup([for (final next in built) next.$2]),
          ),
        );
      });

  static Cause<DiFailure> _all(Iterable<Cause<DiFailure>> causes) =>
      causes.fold(const Empty<DiFailure>(), (all, next) => all & next);

  static Cause<DiFailure> _duplicates(
    Map<DiKey<Object?>, List<String>> labels,
  ) => _all([
    for (final MapEntry(:key, value: owners) in labels.entries)
      if (owners.length > 1)
        Fail<DiFailure>(DuplicateKeyFailure(key, owners), StackTrace.current),
  ]);

  static Cause<DiFailure> _undeclared(
    List<Component<Object?>> components,
    Map<DiKey<Object?>, List<String>> own,
    List<Set<DiKey<Object?>>> ancestors,
  ) => _all([
    for (final component in components)
      for (final key in component.requires)
        if (!own.containsKey(key) &&
            !ancestors.any((keys) => keys.contains(key)))
          Fail<DiFailure>(
            UndeclaredKeyFailure(key, owner: component.label),
            StackTrace.current,
          ),
  ]);

  /// The keys that [component] reads from the components of the scope.
  static Iterable<DiKey<Object?>> _ownReads(
    Component<Object?> component,
    Set<DiKey<Object?>> own,
  ) => [...component.requires, ...component.optional].where(own.contains);

  /// The strata, by repeated selection of the ready components (Kahn).
  static Exit<DiFailure, Strata> _strata(
    List<Component<Object?>> remaining,
    Set<DiKey<Object?>> own,
    Strata done,
    Set<DiKey<Object?>> placed,
    List<Component<Object?>> all,
  ) {
    if (remaining.isEmpty) return Right(done);
    final ready = [
      for (final component in remaining)
        if (_ownReads(component, own).every(placed.contains)) component,
    ];
    if (ready.isEmpty) {
      return Left(
        Fail(
          DependencyCycleFailure(_cycle(remaining, own, all)),
          StackTrace.current,
        ),
      );
    }
    return _strata(
      [
        for (final component in remaining)
          if (!ready.contains(component)) component,
      ],
      own,
      [...done, ready],
      {...placed, for (final component in ready) component.key},
      all,
    );
  }

  /// The path of a cycle that starts at the first stuck component.
  static List<DiKey<Object?>> _cycle(
    List<Component<Object?>> stuck,
    Set<DiKey<Object?>> own,
    List<Component<Object?>> all,
  ) {
    final byKey = {for (final component in all) component.key: component};
    Set<DiKey<Object?>> done = const {};
    for (final start in stuck) {
      final found = _visit(start.key, const [], done, byKey, own);
      if (found.cycle != null) return found.cycle!;
      done = found.done;
    }
    return [stuck.first.key, stuck.first.key];
  }

  static ({List<DiKey<Object?>>? cycle, Set<DiKey<Object?>> done}) _visit(
    DiKey<Object?> key,
    List<DiKey<Object?>> path,
    Set<DiKey<Object?>> done,
    Map<DiKey<Object?>, Component<Object?>> byKey,
    Set<DiKey<Object?>> own,
  ) {
    final at = path.indexOf(key);
    if (at >= 0) return (cycle: [...path.sublist(at), key], done: done);
    if (done.contains(key)) return (cycle: null, done: done);
    var seen = done;
    for (final read in _ownReads(byKey[key]!, own)) {
      final found = _visit(read, [...path, key], seen, byKey, own);
      if (found.cycle != null) return found;
      seen = found.done;
    }
    return (cycle: null, done: {...seen, key});
  }
}
