import 'dart:async';

import 'context.dart';
import 'exception.dart';
import 'key.dart';
import 'lease.dart';
import 'state.dart';

/// The supertype of every [Component], whatever its type argument is.
///
/// A list of components, such as the `components` of a `Module`, has this
/// element type. A generic element type would become the inference context of
/// each `Component(...)` in the list and fix its type argument to `Object?`;
/// this type has no type argument, so Dart infers each component's type from
/// its own `dependency` and `key`. Provider's `SingleChildWidget` does the same
/// for `MultiProvider`. [Component] is the only subtype.
///
/// {@category Declaration}
sealed class ComponentBase {
  const ComponentBase();

  /// Keys that must resolve before this component may activate.
  Set<DiKeyBase> get requires;

  /// Keys this component reads optionally but still tracks for changes.
  Set<DiKeyBase> get optional;

  /// Collection keys whose every member must resolve before this component
  /// may activate.
  Set<DiCollectionKey<Object?>> get collectionKeys;

  /// Collection keys this component reads optionally.
  Set<DiCollectionKey<Object?>> get optionalCollectionKeys;

  /// The key this component publishes into its owner scope, if any.
  DiKeyBase? get key;

  /// The set key this component contributes its value to, if any. A
  /// contribution publishes no key.
  DiSetKey<Object?>? get contributesTo;

  /// All keys that this component reads: required, optional, and collection
  /// keys. A change of the member that publishes one of them, or of the
  /// members of a collection, activates this component again.
  Set<DiKeyBase> get reads;

  /// The label for lifecycle diagnostics: [debugLabel] if set, otherwise the
  /// published key, otherwise the type.
  String get label;

  /// The label that the constructor set, if any.
  String? get debugLabel;
}

/// A component is a [Dependency] plus the key it publishes.
///
/// A component is a value, not a callback: its **shape** — what it requires,
/// what it reads optionally, and what it publishes — is available before
/// anything runs. The runtime uses that shape to decide whether the component
/// may activate at all, so a component whose requirements are absent waits
/// instead of failing.
///
/// The dependency states everything except publication. A [Dependency] that
/// reads no key, `Dependency(create: ...)`, makes a component that never waits.
/// One that reads keys makes a component that waits until they resolve and
/// activates again when the members that publish them change. A component
/// publishes `DiKey<A>()` of its type argument, or the `key` argument when
/// one is given. [Component.effect] publishes nothing. `initialize` creates
/// one node of the `Scope` for each component.
///
/// Like a `Provider<T>`, the type argument states what the component publishes:
/// `Component<Db>(dependency: Dependency<Db>(create: PgDb.new))` publishes
/// `DiKey<Db>()`. Write the type argument: without it, Dart infers the type of
/// the implementation, and the component publishes that type instead. The
/// constructor checks that the type of a key is exactly [A], so a key of an
/// unrelated type fails when the component is built, even when inference
/// widens [A].
///
/// {@category Declaration}
final class Component<A> extends ComponentBase {
  Component._(
    this._dependency,
    this.key,
    this.debugLabel, {
    this.contributesTo,
  });

  /// A component that builds its value from [dependency] on activation.
  ///
  /// The [dependency] reads its keys and creates the value on each activation,
  /// never when the component is built, and what it owns is disposed at
  /// teardown. The shape comes from [dependency]: its `requires` and
  /// `optional`. The component publishes its value under [key], or under
  /// `DiKey<A>()` without one. A member whose value no other member reads is
  /// a [Component.effect]. [debugLabel] labels the component in diagnostics;
  /// without it the label is the key.
  ///
  /// Throws an [ArgumentError] when [A] is `void`, `dynamic`, or `Null`, when
  /// the type of [key] is not exactly [A], or when the published key or a key
  /// that [dependency] reads is a [DiKey] without a name of a core value type
  /// ([DiKey.needsName]). A key whose type is `FutureOr<...>` is rejected at
  /// activation with `UnreachableKeyError`.
  factory Component({
    required Dependency<A> dependency,
    DiKey<A>? key,
    String? debugLabel,
  }) {
    if (_publishesNothing.contains(A)) {
      throw ArgumentError(
        'Component<$A> has no value that another member can read. Use '
        'Component.effect(dependency: ...) for a member that only has '
        'effects, or state the type argument: Component<T>(...)',
      );
    }
    key ??= DiKey<A>();
    if (key.type != A) {
      throw ArgumentError.value(
        key,
        'key',
        'has type ${key.type}, but the type argument of the component is '
            '$A. State the type argument: Component<${key.type}>(...)',
      );
    }
    _checkNamed(key, 'key');
    _checkReads(dependency);
    return Component<A>._(dependency, key, debugLabel);
  }

  /// A member that runs [dependency] for its effects and publishes nothing.
  ///
  /// It keeps the reads of [dependency], so it waits for its keys, activates
  /// again when their publishers change, and disposes what it owns at
  /// teardown, like any component. No other member can read its value. A
  /// member that must wait for the effect reads a token type that another
  /// component publishes. `replacing`, `without`, and `overriddenBy` cannot
  /// select an effect; `where` can.
  ///
  /// Throws an [ArgumentError] when [dependency] reads a [DiKey] without a
  /// name of a core value type.
  factory Component.effect({
    required Dependency<A> dependency,
    String? debugLabel,
  }) {
    _checkReads(dependency);
    return Component<A>._(dependency, null, debugLabel);
  }

  /// A component of [value], which exists before activation.
  ///
  /// Every activation and every scope share that one object, and nothing
  /// disposes it. Use it for configuration and for values that another owner
  /// closes, for example
  /// `Component<Config>.value(value: config)`. Build a value
  /// that needs a dispose with
  /// `Dependency(create: ..., dispose: ...)`. [key] follows the rules of the
  /// unnamed constructor, so without one the component publishes
  /// `DiKey<A>()`.
  factory Component.value({
    required A value,
    DiKey<A>? key,
    String? debugLabel,
  }) => Component<A>(
    dependency: Dependency<A>(create: () => value),
    key: key,
    debugLabel: debugLabel,
  );

  /// A component that contributes the value of [dependency] to the set
  /// [key], for a reader of `Dependency.requireSet(key: ...)` or
  /// `Dependency.maybeSet(key: ...)`.
  ///
  /// It publishes no key, so another member cannot require it, and
  /// `replacing`, `without`, and `overriddenBy` cannot select it; `where` can.
  /// A member that another member reads, or that a test replaces by its id,
  /// belongs in a [DiMapKey] instead.
  ///
  /// Throws an [ArgumentError] when the element type of [key] is not exactly
  /// [A], or when [dependency] reads a [DiKey] without a name of a core value
  /// type.
  factory Component.into({
    required DiSetKey<A> key,
    required Dependency<A> dependency,
    String? debugLabel,
  }) {
    if (key.type != A) {
      throw ArgumentError.value(
        key,
        'key',
        'has element type ${key.type}, but the type argument of the '
            'component is $A. State the type argument: '
            'Component<${key.type}>.into(...)',
      );
    }
    _checkReads(dependency);
    return Component<A>._(dependency, null, debugLabel, contributesTo: key);
  }

  final Dependency<A> _dependency;

  @override
  Set<DiKeyBase> get requires => _dependency.requires;

  @override
  Set<DiKeyBase> get optional => _dependency.optional;

  @override
  Set<DiCollectionKey<Object?>> get collectionKeys =>
      _dependency.collectionKeys;

  @override
  Set<DiCollectionKey<Object?>> get optionalCollectionKeys =>
      _dependency.optionalCollectionKeys;

  @override
  final DiKey<A>? key;

  @override
  final DiSetKey<A>? contributesTo;

  @override
  late final Set<DiKeyBase> reads =
      collectionKeys.isEmpty && optionalCollectionKeys.isEmpty
      ? (optional.isEmpty
            ? requires
            : requires.isEmpty
            ? optional
            : Set<DiKeyBase>.unmodifiable(<DiKeyBase>{
                ...requires,
                ...optional,
              }))
      : Set<DiKeyBase>.unmodifiable(<DiKeyBase>{
          ...requires,
          ...optional,
          ...collectionKeys,
          ...optionalCollectionKeys,
        });

  @override
  final String? debugLabel;

  @override
  String get label =>
      debugLabel ??
      (key != null
          ? '$key'
          : contributesTo != null
          ? 'Component<$A> into $contributesTo'
          : 'Component<$A>');

  Future<A> _run(DiContext context) async {
    final value = await runDependency(_dependency, context);
    final key = this.key;
    if (key != null) context.publish<A>(value, key: key);
    if (contributesTo != null) context.contribute(value);
    return value;
  }

  @override
  String toString() => 'Component($label)';
}

/// Runs [component] in an activation. Only the runtime calls it.
Future<A> runComponent<A>(Component<A> component, DiContext context) =>
    component._run(context);

/// Creates a [ComponentNode] from the functions of one scope. Only the runtime
/// calls it.
ComponentNode<A> createComponentNode<A>({
  required Future<void> Function() dispose,
  required A Function() read,
  required bool Function() isActive,
  required Future<A> Function() whenActive,
  required NodeState Function() state,
}) => ComponentNode<A>._(
  dispose: dispose,
  read: read,
  isActive: isActive,
  whenActive: whenActive,
  state: state,
);

/// The node that a scope created from one declared component.
///
/// A [Component] is the immutable description, like a widget; a node is that
/// description created in one scope, like the element of a mounted widget. One
/// component declared in two scopes has two nodes. Get a node from
/// `Scope.node`, `Scope.nodes`, or `Scope.findNode`.
///
/// {@category Lifecycle}
final class ComponentNode<A> {
  ComponentNode._({
    required Future<void> Function() dispose,
    required A Function() read,
    required bool Function() isActive,
    required Future<A> Function() whenActive,
    required NodeState Function() state,
  }) : _dispose = dispose,
       _read = read,
       _isActive = isActive,
       _whenActive = whenActive,
       _state = state;

  final Future<void> Function() _dispose;
  final A Function() _read;
  final bool Function() _isActive;
  final Future<A> Function() _whenActive;
  final NodeState Function() _state;

  /// The value of the committed activation.
  ///
  /// Throws `InactiveNodeException` in a phase other than
  /// [NodePhase.active], also while the release of the node runs.
  A get value => _read();

  /// Whether the phase of this node is [NodePhase.active]. It is false while
  /// the release of the node runs.
  bool get isActive => _isActive();

  /// Completes with the value when this node is active.
  ///
  /// It completes at once for a node in the phase [NodePhase.active], and
  /// otherwise when the
  /// node next commits an activation. It fails with
  /// `InactiveNodeException` when the node is disposed first. A
  /// failed automatic activation does not complete it, because a later
  /// activation can still succeed; read `Scope.errors` for the failure.
  /// Listen to the future before the node can be disposed, or Dart reports
  /// the failure as uncaught. Do not await it inside a `create` or a `dispose`
  /// function: it completes in a mutation, so the wait can last forever.
  Future<A> get whenActive => _whenActive();

  /// The required keys that do not resolve while this node is not active:
  /// `state.missing`.
  ///
  /// It is empty for an active or a disposed node, and for a node
  /// whose keys resolve but whose last activation failed.
  List<DiKeyBase> get missing => _state().missing;

  /// The state of this node now, as an immutable value. It is the
  /// [NodeState] of this node in `Scope.state` of its scope. The read starts
  /// no mutation and changes no state. [isActive] is true only in the phase
  /// [NodePhase.active].
  NodeState get state => _state();

  /// The failure of the last activation, while the phase of [state] is
  /// [NodePhase.activationFailed]; otherwise null:
  /// `state.activationException`.
  ///
  /// Its `cause` is the error that the activation threw, and its `stackTrace`
  /// is the stack trace of that error. `Scope.errors` reports the same
  /// failure once, and only to the listeners of that moment; this read
  /// returns it until the node activates again, waits for a key, or is
  /// disposed. The read starts no mutation and changes no state.
  ActivationException? get activationException => _state().activationException;

  /// Disposes this node for good. Safe to call more than once.
  Future<void> dispose() => _dispose();
}

/// Rejects a [DiKey] without a name of a core value type (R-UC-RT-LC-025).
void _checkNamed(DiKeyBase? key, String argument) {
  if (key is! DiKey || !key.needsName) return;
  throw ArgumentError.value(
    key,
    argument,
    'has no name, and ${key.type} is a core value type. An extension type '
    'over ${key.type} erases to it at run time, so the key needs a name: '
    "DiKey<${key.type}>(name: 'port'), or an extension type with "
    'its own key: extension type Port(${key.type} value) { static const '
    "key = DiKey<Port>(name: 'Port'); }",
  );
}

/// Rejects the reads of [dependency] that [_checkNamed] rejects.
void _checkReads(Dependency<Object?> dependency) {
  for (final read in dependency.requires) {
    _checkNamed(read, 'dependency');
  }
  for (final read in dependency.optional) {
    _checkNamed(read, 'dependency');
  }
}

Type _typeOf<X>() => X;

/// The types whose default key no member can use (R-UC-RT-LC-026).
final Set<Type> _publishesNothing = {
  _typeOf<void>(),
  _typeOf<dynamic>(),
  _typeOf<Null>(),
};
