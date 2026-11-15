import 'package:fpdart/fpdart.dart';

import 'cause.dart';
import 'dependency.dart';
import 'failure.dart';
import 'key.dart';

/// A [Dependency] and the key that publishes its value.
///
/// A component is the layer of this package, like a `ZLayer` of ZIO. It has
/// one output key, and its inputs are the keys that its [Dependency] reads.
/// A `Scope` takes a list of components. The scope derives the wiring from
/// the keys, so the package has no operator that composes components. The
/// scope creates the value of a component when the scope runs.
final class Component<A> {
  /// Creates a component that publishes the value of [dependency].
  ///
  /// The key is `DiKey<A>()` when [key] is `null`. The [debugLabel] names the
  /// component in a failure.
  Component({
    required Dependency<A> dependency,
    DiKey<A>? key,
    String? debugLabel,
  }) : this._(dependency, key ?? DiKey<A>(), debugLabel);

  /// Creates a component that publishes a [value] that exists already.
  ///
  /// The component reads nothing and owns nothing.
  Component.value({required A value, DiKey<A>? key, String? debugLabel})
    : this._(Dependency<A>.of(value), key ?? DiKey<A>(), debugLabel);

  /// Creates a component that publishes no key.
  ///
  /// The component runs for its effect. It reads the keys of [dependency], so
  /// it runs after the components that publish them. It owns its values like
  /// any component, and a scope releases it before the components that it
  /// reads. Nobody can read the value, and the component cannot be
  /// overridden. Two effects of one type can exist in one list.
  ///
  /// The [debugLabel] names the component in a failure.
  Component.effect({required Dependency<A> dependency, String? debugLabel})
    : this._(dependency, effectKey<A>(debugLabel), debugLabel, isEffect: true);

  /// Creates a component that contributes its value to the set [key].
  ///
  /// The component publishes no plain key, so nothing reads it by a key and an
  /// override cannot replace it. Each declaration of the component is one
  /// contribution: a scope that declares it twice has two contributions, and
  /// equal values give one element of the set. A reader of the set sees the
  /// value in the order of the declarations. The component is not an effect:
  /// it can be a reader of the same set, and it does not count as a member of
  /// the set that it reads.
  Component.into({
    required DiSetKey<A> key,
    required Dependency<A> dependency,
    String? debugLabel,
  }) : this._(
         dependency,
         effectKey<A>(debugLabel),
         debugLabel,
         contributesTo: key,
       );

  Component._(
    this._dependency,
    this.key,
    this._debugLabel, {
    this.isEffect = false,
    this.contributesTo,
  }) : invalidReason = isEffect
           ? null
           : _invalidReason<A>(contributesTo ?? key, contributesTo != null);

  final Dependency<A> _dependency;
  final String? _debugLabel;

  /// The key under which the component publishes its value.
  ///
  /// An effect component has a key that equals only itself.
  final DiKey<A> key;

  /// Whether the component is an effect: it publishes no key.
  final bool isEffect;

  /// The set that the component contributes to, or `null`.
  ///
  /// A contribution publishes no plain key.
  final DiSetKey<Object?>? contributesTo;

  /// Why the declaration does not fit, or `null` when it fits.
  ///
  /// The constructors never throw. `Scope.run` fails with an
  /// [InvalidComponentFailure] for a component that has a reason. There are
  /// two reasons. The type argument is `void`, `dynamic`, or `Null`, so no
  /// other component can read the value: use [Component.effect]. Or the type
  /// of the key is not the type argument, which Dart accepts when it infers
  /// the type argument from the dependency.
  final String? invalidReason;

  /// Whether the component publishes [key]: it is neither an effect nor a
  /// contribution.
  bool get hasKey => !isEffect && contributesTo == null;

  /// The keys that the component must read.
  Set<DiKey<Object?>> get requires => _dependency.requires;

  /// The keys that the component reads when a scope publishes them.
  Set<DiKey<Object?>> get optional => _dependency.optional;

  /// The collection keys that the component reads strictly.
  Set<DiCollectionKey<Object?>> get collectionKeys =>
      _dependency.collectionKeys;

  /// The collection keys that the component reads without a wait.
  Set<DiCollectionKey<Object?>> get optionalCollectionKeys =>
      _dependency.optionalCollectionKeys;

  /// Every key that the component reads: the required keys, the optional keys,
  /// and the collection keys of both kinds.
  Set<DiKeyBase> get reads => Set.unmodifiable({
    ...requires,
    ...optional,
    ...collectionKeys,
    ...optionalCollectionKeys,
  });

  /// The name of the component in a failure.
  ///
  /// The label is the debug label, or the key when the component has no debug
  /// label. The label of a contribution names its set.
  String get label =>
      _debugLabel ??
      (contributesTo == null
          ? key.toString()
          : 'Component<$A> into $contributesTo');

  /// The debug label of the component, or `null`.
  String? get debugLabel => _debugLabel;
}

Type _typeOf<X>() => X;

/// The type arguments whose default key no component can read.
final Set<Type> _publishesNothing = {
  _typeOf<void>(),
  _typeOf<dynamic>(),
  _typeOf<Null>(),
};

String? _invalidReason<A>(DiKeyBase key, bool contribution) {
  if (!contribution && _publishesNothing.contains(A)) {
    return 'Component<$A> has no value that another component can read. '
        'Use Component.effect(dependency: ...) for a component that only '
        'has effects, or state the type argument: Component<T>(...)';
  }
  if (key.type != A) {
    return 'the key has the type ${key.type}, but the type argument of the '
        'component is $A. State the type argument: '
        'Component<${key.type}>(...)';
  }
  return null;
}

/// Runs the steps of [component] in [context] and gives its value.
///
/// The task never throws. A failed task has not released the values that the
/// steps registered in the finalizers of the context. The runtime releases
/// them.
TaskEither<Cause<DiFailure>, Object?> runComponent(
  Component<Object?> component,
  StepContext context,
) => runDependency(component._dependency, context);

/// Operations on a group of components.
///
/// A group is a plain list. Join groups with the list operations, such as
/// `[...a, ...b]`.
extension ComponentsOps on Iterable<Component<Object?>> {
  /// The keys that the components publish.
  ///
  /// An effect component and a contribution publish no key. A map entry
  /// publishes its entry key.
  Set<DiKey<Object?>> get publishes => Set.unmodifiable({
    for (final component in this)
      if (component.hasKey) component.key,
  });

  /// The number of contributions to each set key, in the order that the
  /// group first names the key.
  ///
  /// A component that is declared twice counts twice.
  Map<DiSetKey<Object?>, int> get contributes {
    final result = <DiSetKey<Object?>, int>{};
    for (final component in this) {
      final set = component.contributesTo;
      if (set != null) result[set] = (result[set] ?? 0) + 1;
    }
    return Map.unmodifiable(result);
  }

  /// The keys that a component requires and that no other component of the
  /// group publishes.
  ///
  /// The publication of a component does not satisfy its own requirement. The
  /// reads of an effect component count. A collection key is never in the
  /// result.
  Set<DiKey<Object?>> get requires => Set.unmodifiable({
    for (final (i, component) in toList().indexed)
      for (final key in component.requires)
        if (!_publishedExcept(i, key)) key,
  });

  /// The keys and the collection keys that a component reads, and that no
  /// other component of the group publishes.
  ///
  /// A collection key is a read and never a requirement, so it stays in the
  /// result. An optional read counts.
  Set<DiKeyBase> get reads => Set.unmodifiable({
    for (final (i, component) in toList().indexed)
      for (final key in component.reads)
        if (key is! DiKey<Object?> || !_publishedExcept(i, key)) key,
  });

  bool _publishedExcept(int index, DiKey<Object?> key) {
    for (final (j, other) in toList().indexed) {
      if (j != index && other.hasKey && other.key == key) return true;
    }
    return false;
  }

  /// The components that require a key of [keys], directly or through another
  /// component of the result, in the order of the group.
  ///
  /// A variant of an application can have no publisher for a key, for example
  /// a service of one platform. `Scope.run` reports an [UndeclaredKeyFailure]
  /// for a component that requires such a key, and then for each component
  /// that requires the key of a removed component. This operation names all of
  /// those components, and [withoutRequiring] removes them.
  ///
  /// A component is in the result when its `requires` holds a key of [keys],
  /// or the key that another component of the result publishes. An optional
  /// read and a collection read do not put a component in the result: the
  /// first gets `None`, and the second gets a collection without the removed
  /// contribution. A component that publishes a key of [keys] is not in the
  /// result for that reason, and each component that requires that key is.
  /// The reads of an effect component count.
  ///
  /// [ancestorKeys] holds the keys that an ancestor scope also publishes. A
  /// component of the result that publishes such a key does not take the
  /// readers of that key with it, because they read the value of the
  /// ancestor. [ancestorKeys] does not take a key out of [keys].
  ///
  /// The operation does not fail: a key that no component requires changes
  /// nothing. The time is near-linear in the components and their required
  /// keys, in every order of the group.
  List<Component<Object?>> requiring({
    required Iterable<DiKeyBase> keys,
    Iterable<DiKeyBase> ancestorKeys = const <DiKeyBase>[],
  }) {
    final group = toList();
    final selected = _requiringFlags(group, keys, ancestorKeys);
    return [
      for (var i = 0; i < group.length; i++)
        if (selected[i]) group[i],
    ];
  }

  /// The components that [requiring] does not return for the same arguments.
  ///
  /// No component of the result requires a key of [keys]. Each key in
  /// `requires` of the result is in `requires` of the group or in
  /// [ancestorKeys], so the removal adds no required key that the caller did
  /// not name.
  ///
  /// For the components of a child scope, pass the keys that the parent lost
  /// and the keys that the parent still publishes:
  ///
  /// ```dart
  /// final removed = all.requiring(keys: absent);
  /// final session = sessionComponents.withoutRequiring(
  ///   keys: {...absent, ...removed.publishes},
  ///   ancestorKeys: all.withoutRequiring(keys: absent).publishes,
  /// );
  /// ```
  List<Component<Object?>> withoutRequiring({
    required Iterable<DiKeyBase> keys,
    Iterable<DiKeyBase> ancestorKeys = const <DiKeyBase>[],
  }) {
    final group = toList();
    final selected = _requiringFlags(group, keys, ancestorKeys);
    return [
      for (var i = 0; i < group.length; i++)
        if (!selected[i]) group[i],
    ];
  }

  /// A list in which [component] replaces the one component that publishes
  /// [key]. The replacement keeps the place of the replaced component.
  ///
  /// The result is a `Left` when [component] does not publish [key]
  /// ([InvalidComponentFailure]), when no component publishes [key]
  /// ([UnmatchedOverrideFailure]), and when more than one component publishes
  /// [key] ([DuplicateKeyFailure]). An effect component and a contribution
  /// publish no key, so no key selects them.
  Exit<DiFailure, List<Component<Object?>>> replacing({
    required DiKey<Object?> key,
    required Component<Object?> component,
  }) {
    if (!component.hasKey || component.key != key) {
      return Left(
        Fail<DiFailure>(
          InvalidComponentFailure(component.label, 'does not publish $key'),
          StackTrace.current,
        ),
      );
    }
    final group = toList();
    final matches = [
      for (var i = 0; i < group.length; i++)
        if (group[i].hasKey && group[i].key == key) i,
    ];
    if (matches.length != 1) {
      return Left(
        Fail<DiFailure>(
          matches.isEmpty
              ? UnmatchedOverrideFailure(key, owner: component.label)
              : DuplicateKeyFailure(key, [
                  for (final i in matches) group[i].label,
                ]),
          StackTrace.current,
        ),
      );
    }
    return Right([
      for (var i = 0; i < group.length; i++)
        if (i == matches.single) component else group[i],
    ]);
  }

  /// A list in which each component of [overrides] replaces the component
  /// that publishes the same key.
  ///
  /// The replacement keeps the place of the replaced component. The result is
  /// a `Left` when an override has no single target. The cause accumulates
  /// every problem, in the order of [overrides], joined with `&`:
  ///
  /// - An override whose key no component publishes is an
  ///   [UnmatchedOverrideFailure]. An effect component or a contribution as an
  ///   override is an [UnmatchedOverrideFailure], too, because it publishes
  ///   no key.
  /// - An override whose key more than one component publishes is a
  ///   [DuplicateKeyFailure].
  /// - Two overrides with the same key are a [DuplicateKeyFailure].
  Exit<DiFailure, List<Component<Object?>>> overriddenBy(
    Iterable<Component<Object?>> overrides,
  ) {
    final base = toList();
    final replacements = <DiKey<Object?>, List<Component<Object?>>>{};
    for (final override in overrides) {
      (replacements[override.key] ??= []).add(override);
    }
    final failures = <Cause<DiFailure>>[];
    final reported = <DiKey<Object?>>{};
    for (final override in overrides) {
      final key = override.key;
      final targets = [
        for (final component in base)
          if (component.hasKey && component.key == key) component,
      ];
      if (!override.hasKey || targets.isEmpty) {
        failures.add(
          Fail<DiFailure>(
            UnmatchedOverrideFailure(key, owner: override.label),
            StackTrace.current,
          ),
        );
      } else if (targets.length > 1) {
        if (reported.add(key)) {
          failures.add(
            Fail<DiFailure>(
              DuplicateKeyFailure(key, [
                for (final target in targets) target.label,
              ]),
              StackTrace.current,
            ),
          );
        }
      }
      final same = replacements[key]!;
      if (same.length > 1 && override.hasKey && reported.add(key)) {
        failures.add(
          Fail<DiFailure>(
            DuplicateKeyFailure(key, [
              for (final component in same) component.label,
            ]),
            StackTrace.current,
          ),
        );
      }
    }
    final cause = failures.fold<Cause<DiFailure>>(
      const Empty<DiFailure>(),
      (all, next) => all & next,
    );
    if (!cause.isEmpty) return Left(cause);
    return Right([
      for (final component in base)
        if (component.hasKey && replacements.containsKey(component.key))
          replacements[component.key]!.single
        else
          component,
    ]);
  }
}

/// For each position of [group], whether the component requires a key of
/// [keys], or the key of another selected component that [ancestorKeys] does
/// not hold.
///
/// An index gives the components that require each key, and the search reads
/// each absent key one time.
List<bool> _requiringFlags(
  List<Component<Object?>> group,
  Iterable<DiKeyBase> keys,
  Iterable<DiKeyBase> ancestorKeys,
) {
  final readers = <DiKeyBase, List<int>>{};
  for (var i = 0; i < group.length; i++) {
    for (final key in group[i].requires) {
      (readers[key] ??= <int>[]).add(i);
    }
  }
  final ancestors = Set<DiKeyBase>.of(ancestorKeys);
  final absent = <DiKeyBase>{};
  final pending = <DiKeyBase>[];
  for (final key in keys) {
    if (absent.add(key)) pending.add(key);
  }
  final selected = List<bool>.filled(group.length, false);
  while (pending.isNotEmpty) {
    final key = pending.removeLast();
    for (final i in readers[key] ?? const <int>[]) {
      if (selected[i]) continue;
      selected[i] = true;
      if (!group[i].hasKey) continue;
      final published = group[i].key;
      if (ancestors.contains(published)) continue;
      if (absent.add(published)) pending.add(published);
    }
  }
  return selected;
}
