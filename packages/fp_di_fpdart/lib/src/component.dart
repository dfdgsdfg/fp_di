import 'package:fpdart/fpdart.dart';

import 'cause.dart';
import 'dependency.dart';
import 'environment.dart';
import 'failure.dart';
import 'finalizers.dart';
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

  Component._(this._dependency, this.key, this._debugLabel);

  final Dependency<A> _dependency;
  final String? _debugLabel;

  /// The key under which the component publishes its value.
  final DiKey<A> key;

  /// The keys that the component must read.
  Set<DiKey<Object?>> get requires => _dependency.requires;

  /// The keys that the component reads when a scope publishes them.
  Set<DiKey<Object?>> get optional => _dependency.optional;

  /// The name of the component in a failure.
  ///
  /// The label is the debug label, or the key when the component has no debug
  /// label.
  String get label => _debugLabel ?? key.toString();

  /// Makes the value of the component from the [input] environment.
  ///
  /// The component is a function from an environment to a `TaskEither`, like
  /// a `ZLayer`. The task runs the dependency. When a step fails, the task
  /// releases the values that the component owns, in reverse order. The cause
  /// is then the failure followed by the dispose failures.
  TaskEither<Cause<DiFailure>, Built> _build(Environment input) => TaskEither(
    () => IORef.create<Finalizers>(Finalizers.empty).toTask().flatMap((owned) {
      final context = StepContext(label, input, owned);
      return runDependency(_dependency, context).flatMap(
        (exit) => owned.read().toTask().flatMap(
          (finalizers) => exit.match(
            (failure) => finalizers.release().map(
              (rollback) => Left<Cause<DiFailure>, Built>(failure + rollback),
            ),
            (value) => Task.of(
              Right<Cause<DiFailure>, Built>((
                Environment.of({key: value}),
                finalizers,
              )),
            ),
          ),
        ),
      );
    }).run(),
  );
}

/// Makes the value of [component] from the [input] environment.
///
/// The task never throws. A failed task has released the values that the
/// component owned.
TaskEither<Cause<DiFailure>, Built> buildComponent(
  Component<Object?> component,
  Environment input,
) => component._build(input);

/// Operations on a group of components.
///
/// A group is a plain list. Join groups with the list operations, such as
/// `[...a, ...b]`.
extension ComponentsOps on Iterable<Component<Object?>> {
  /// The keys that the components publish.
  Set<DiKey<Object?>> get publishes => {
    for (final component in this) component.key,
  };

  /// The keys that a component requires and that no component of the group
  /// publishes.
  Set<DiKey<Object?>> get requires {
    final published = publishes;
    return {
      for (final component in this)
        for (final key in component.requires)
          if (!published.contains(key)) key,
    };
  }

  /// A list in which the components of [overrides] replace this group.
  ///
  /// A component of [overrides] replaces the component with the same key, in
  /// place. A component with a new key goes to the end. A duplicate key in
  /// [overrides] stays, so the duplicate check of a scope reports it.
  List<Component<Object?>> overriddenBy(
    Iterable<Component<Object?>> overrides,
  ) {
    final replacements = <DiKey<Object?>, List<Component<Object?>>>{};
    for (final component in overrides) {
      (replacements[component.key] ??= []).add(component);
    }
    final present = publishes;
    return [
      for (final component in this)
        ...(replacements[component.key] ?? [component]),
      for (final component in overrides)
        if (!present.contains(component.key)) component,
    ];
  }
}
