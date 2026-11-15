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

  Component._(
    this._dependency,
    this.key,
    this._debugLabel, {
    this.isEffect = false,
  });

  final Dependency<A> _dependency;
  final String? _debugLabel;

  /// The key under which the component publishes its value.
  ///
  /// An effect component has a key that equals only itself.
  final DiKey<A> key;

  /// Whether the component is an effect: it publishes no key.
  final bool isEffect;

  /// The keys that the component must read.
  Set<DiKey<Object?>> get requires => _dependency.requires;

  /// The keys that the component reads when a scope publishes them.
  Set<DiKey<Object?>> get optional => _dependency.optional;

  /// The name of the component in a failure.
  ///
  /// The label is the debug label, or the key when the component has no debug
  /// label.
  String get label => _debugLabel ?? key.toString();

  /// The debug label of the component, or `null`.
  String? get debugLabel => _debugLabel;
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
  /// An effect component publishes no key.
  Set<DiKey<Object?>> get publishes => {
    for (final component in this)
      if (!component.isEffect) component.key,
  };

  /// The keys that a component requires and that no component of the group
  /// publishes.
  ///
  /// The reads of an effect component count.
  Set<DiKey<Object?>> get requires {
    final published = publishes;
    return {
      for (final component in this)
        for (final key in component.requires)
          if (!published.contains(key)) key,
    };
  }

  /// A list in which each component of [overrides] replaces the component
  /// that publishes the same key.
  ///
  /// The replacement keeps the place of the replaced component. The result is
  /// a `Left` when an override has no single target. The cause accumulates
  /// every problem, in the order of [overrides], joined with `&`:
  ///
  /// - An override whose key no component publishes is an
  ///   [UnmatchedOverrideFailure]. An effect component as an override is an
  ///   [UnmatchedOverrideFailure], too, because it publishes no key.
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
          if (!component.isEffect && component.key == key) component,
      ];
      if (override.isEffect || targets.isEmpty) {
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
      if (same.length > 1 && !override.isEffect && reported.add(key)) {
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
        if (!component.isEffect && replacements.containsKey(component.key))
          replacements[component.key]!.single
        else
          component,
    ]);
  }
}
