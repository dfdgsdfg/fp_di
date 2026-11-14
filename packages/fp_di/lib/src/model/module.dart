import 'component.dart';
import 'key.dart';

/// An immutable list of components that a scope declares.
///
/// A package exports a module and the application composes modules. Each
/// member stays its own node: it has its own dormancy and its own
/// reconciliation. A member that waits for a key does not block its siblings.
///
/// The members are plain values. The application chooses them with ordinary
/// Dart conditionals; `fp_di` has no notion of a profile.
///
/// Declare a module as the contents of a scope with `Scope(module: module)`
/// or `scope.child(module: module)`, then call `initialize`. It activates
/// members that do not depend on each other at the same time. A member starts
/// after every member that publishes a key it needs. The keys are the only
/// order: when a member needs the effect of another member, the other member
/// publishes a token key and the member requires it.
///
/// A module is a value. [replacing], [without], and [where] return a new
/// module and keep the declaration order of every remaining member, so a test
/// or a feature flag edits the module before a scope exists. [publishes],
/// [requires], and [reads] are its derived shape.
///
/// [withoutRequiring] removes the members that a variant cannot activate,
/// because they require a key that the variant does not publish. [requiring]
/// returns those members.
///
/// A composed module remembers the label of the module that listed each
/// member, as [origins]. Only diagnostics and the shape export read it.
///
/// {@category Declaration}
final class Module {
  /// A module of [components], listed in declaration order.
  ///
  /// Members that do not need each other's keys activate concurrently.
  /// [debugLabel] labels the module in diagnostics.
  Module({required Iterable<ComponentBase> components, String? debugLabel})
    : this._listed(List<ComponentBase>.unmodifiable(components), debugLabel);

  Module._listed(this.components, this.debugLabel)
    : origins = List<String?>.unmodifiable(
        List<String?>.filled(components.length, debugLabel),
      );

  Module._({
    required Iterable<ComponentBase> components,
    required Iterable<String?> origins,
    required this.debugLabel,
  }) : components = List<ComponentBase>.unmodifiable(components),
       origins = List<String?>.unmodifiable(origins);

  /// The concatenation of [modules], keeping their order.
  ///
  /// [debugLabel] labels the result; the labels of [modules] are not its
  /// label. Each member keeps its origin, so [origins] still names the module
  /// that listed it.
  factory Module.all({required Iterable<Module> modules, String? debugLabel}) {
    final parts = List<Module>.of(modules);
    return Module._(
      components: <ComponentBase>[
        for (final module in parts) ...module.components,
      ],
      origins: <String?>[for (final module in parts) ...module.origins],
      debugLabel: debugLabel,
    );
  }

  /// The members, in declaration order.
  final List<ComponentBase> components;

  /// An optional label for diagnostics.
  final String? debugLabel;

  /// The origin of each member, by index: the [debugLabel] of the module
  /// whose constructor listed the member, or null when that module has no
  /// label.
  ///
  /// [Module.all] and `+` keep the origin of each member, also when
  /// [Module.all] gets a label. An edit keeps the origin of each position: a
  /// member that [replacing] or [overriddenBy] puts in takes the origin of
  /// the member that it replaces. The unnamed constructor gives every member
  /// the label of the new module, so `Module(components: other.components)`
  /// does not keep the origins of `other`; use [Module.all] to label a
  /// composed module.
  final List<String?> origins;

  /// The keys that the members publish.
  late final Set<DiKeyBase> publishes = Set<DiKeyBase>.unmodifiable(<DiKeyBase>{
    for (final member in components) ?member.key,
  });

  /// The required keys that no other member publishes.
  ///
  /// A scope that declares this module needs an ancestor that declares these
  /// keys; otherwise `Scope.initialize` throws `UndeclaredKeyError`.
  /// A member that injects a key it publishes itself still needs another
  /// member to publish it, so its own publication does not count.
  late final Set<DiKeyBase> requires = _external((member) => member.requires);

  /// Every key that a member reads, required or optional, that no other
  /// member publishes.
  ///
  /// It contains [requires], like `Component.reads` contains
  /// `Component.requires`. The keys in [reads] but not in [requires] are read
  /// optionally.
  ///
  /// A collection key that a member reads is always in [reads] and never in
  /// [requires]: an ancestor can add members, and an empty collection is
  /// valid.
  late final Set<DiKeyBase> reads = _external((member) => member.reads);

  /// The set keys that members contribute to, each with its number of
  /// contributors, in declaration order.
  ///
  /// A test compares it across the variants of an application, because the
  /// runtime does not detect a contribution to a wrong key. Map entries are
  /// published keys, so they are in [publishes].
  late final Map<DiSetKey<Object?>, int> contributes = () {
    final counts = <DiSetKey<Object?>, int>{};
    for (final member in components) {
      final key = member.contributesTo;
      if (key != null) counts[key] = (counts[key] ?? 0) + 1;
    }
    return Map<DiSetKey<Object?>, int>.unmodifiable(counts);
  }();

  Set<DiKeyBase> _external(
    Set<DiKeyBase> Function(ComponentBase member) select,
  ) {
    final result = <DiKeyBase>{};
    for (var i = 0; i < components.length; i++) {
      for (final key in select(components[i])) {
        var internal = false;
        for (var j = 0; j < components.length && !internal; j++) {
          internal = j != i && components[j].key == key;
        }
        if (!internal) result.add(key);
      }
    }
    return Set<DiKeyBase>.unmodifiable(result);
  }

  /// A module in which [component] takes the place of the one member that
  /// publishes [key].
  ///
  /// The replacement keeps the position of that member.
  /// Throws an [ArgumentError] when no member or more than one member
  /// publishes [key], or when [component] does not publish [key].
  Module replacing({required DiKeyBase key, required ComponentBase component}) {
    if (component.key != key) {
      throw ArgumentError.value(
        component,
        'component',
        'does not publish $key',
      );
    }
    final index = _indexOf(key);
    return Module._(
      components: <ComponentBase>[
        for (var i = 0; i < components.length; i++)
          i == index ? component : components[i],
      ],
      origins: origins,
      debugLabel: debugLabel,
    );
  }

  /// A module in which each member of [overrides] takes the place of the
  /// member that publishes the same key.
  ///
  /// Use it to swap a set of real members for fakes in a test, or for a
  /// variant of the application. Each replacement keeps the position of the
  /// member it replaces, and the other members stay. [overrides] may only
  /// replace: a fake whose key no member publishes is a mistake, such as a
  /// wrong key or a member that moved, so it is rejected instead of added.
  ///
  /// Throws an [ArgumentError] when a member of [overrides] has no key, when
  /// no member or more than one member publishes its key, or when two
  /// members of [overrides] publish the same key.
  Module overriddenBy(Module overrides) {
    final replacements = <int, ComponentBase>{};
    for (final override in overrides.components) {
      final key = override.key;
      if (key == null) {
        throw ArgumentError.value(
          override,
          'overrides',
          'has a member without a key, which cannot replace a member',
        );
      }
      final matches = <int>[
        for (var i = 0; i < components.length; i++)
          if (components[i].key == key) i,
      ];
      if (matches.length != 1) {
        throw ArgumentError.value(
          key,
          'overrides',
          matches.isEmpty
              ? 'no member of $this publishes it, so there is nothing to '
                    'override'
              : '${matches.length} members of $this publish it',
        );
      }
      if (replacements.containsKey(matches.single)) {
        throw ArgumentError.value(
          key,
          'overrides',
          'more than one override publishes it',
        );
      }
      replacements[matches.single] = override;
    }
    return Module._(
      components: <ComponentBase>[
        for (var i = 0; i < components.length; i++)
          replacements[i] ?? components[i],
      ],
      origins: origins,
      debugLabel: debugLabel,
    );
  }

  /// A module without the one member that publishes [key].
  ///
  /// Throws an [ArgumentError] when no member or more than one member
  /// publishes [key].
  Module without({required DiKeyBase key}) {
    final index = _indexOf(key);
    var position = 0;
    return where((_) => position++ != index);
  }

  /// A module of the members for which [test] returns true.
  Module where(bool Function(ComponentBase member) test) {
    final kept = <int>[
      for (var i = 0; i < components.length; i++)
        if (test(components[i])) i,
    ];
    return Module._(
      components: <ComponentBase>[for (final i in kept) components[i]],
      origins: <String?>[for (final i in kept) origins[i]],
      debugLabel: debugLabel,
    );
  }

  /// A module of the members that require a key of [keys], directly or
  /// through another member of the result.
  ///
  /// An application variant can have no publisher for a key, for example a
  /// service of one platform. `Scope.initialize` throws an
  /// `UndeclaredKeyError` for a member that requires such a key, and then
  /// for each member that requires the key of a removed member. This edit
  /// names all of those members, and [withoutRequiring] removes them:
  ///
  /// ```dart
  /// final absent = {const DiKey<Camera>()};
  /// final root = Scope(module: all.withoutRequiring(keys: absent));
  /// // A test compares the removed members with an expected list.
  /// final removed = all.requiring(keys: absent).components;
  /// ```
  ///
  /// A member is in the result when its `requires` holds a key of [keys], or
  /// the key that another member of the result publishes. An optional read
  /// and a collection read do not put a member in the result: the first
  /// gets `null`, and the second gets a collection without the removed
  /// contribution. A member that publishes a key of [keys] is not in the
  /// result for that reason, and each member that requires that key is.
  ///
  /// [ancestorKeys] holds the keys that an ancestor scope also publishes. A
  /// member of the result that publishes such a key does not take the
  /// readers of that key with it, because they read the value of the
  /// ancestor. [ancestorKeys] does not take a key out of [keys].
  ///
  /// The result keeps the declaration order, the origin of each member, and
  /// the [debugLabel], as [where] does. The call does not throw: a key that
  /// no member requires changes nothing.
  Module requiring({
    required Iterable<DiKeyBase> keys,
    Iterable<DiKeyBase> ancestorKeys = const <DiKeyBase>[],
  }) => _selected(_requiring(keys, ancestorKeys), true);

  /// A module without the members that [requiring] returns for the same
  /// arguments.
  ///
  /// No member of the result requires a key of [keys]. Each key in
  /// [requires] of the result is in [requires] of this module or in
  /// [ancestorKeys], so the removal adds no required key that the caller did
  /// not name.
  ///
  /// For the module of a child scope, pass the keys that the parent lost and
  /// the keys that the parent still publishes:
  ///
  /// ```dart
  /// final removed = all.requiring(keys: absent);
  /// final sessionModule = session.withoutRequiring(
  ///   keys: {...absent, ...removed.publishes},
  ///   ancestorKeys: all.withoutRequiring(keys: absent).publishes,
  /// );
  /// ```
  Module withoutRequiring({
    required Iterable<DiKeyBase> keys,
    Iterable<DiKeyBase> ancestorKeys = const <DiKeyBase>[],
  }) => _selected(_requiring(keys, ancestorKeys), false);

  /// For each position, whether the member requires a key of [keys] or the
  /// key of another selected member that [ancestorKeys] does not hold.
  ///
  /// An index gives the members that require each key, and the search reads
  /// each absent key one time. The time is therefore near-linear in the
  /// members plus their required keys, in every declaration order.
  List<bool> _requiring(
    Iterable<DiKeyBase> keys,
    Iterable<DiKeyBase> ancestorKeys,
  ) {
    final readers = <DiKeyBase, List<int>>{};
    for (var i = 0; i < components.length; i++) {
      for (final key in components[i].requires) {
        (readers[key] ??= <int>[]).add(i);
      }
    }
    final ancestors = Set<DiKeyBase>.of(ancestorKeys);
    final absent = <DiKeyBase>{};
    final pending = <DiKeyBase>[];
    for (final key in keys) {
      if (absent.add(key)) pending.add(key);
    }
    final selected = List<bool>.filled(components.length, false);
    while (pending.isNotEmpty) {
      final key = pending.removeLast();
      for (final i in readers[key] ?? const <int>[]) {
        if (selected[i]) continue;
        selected[i] = true;
        final published = components[i].key;
        if (published == null || ancestors.contains(published)) continue;
        if (absent.add(published)) pending.add(published);
      }
    }
    return selected;
  }

  /// The members whose position in [selected] holds [value], with their
  /// origins.
  Module _selected(List<bool> selected, bool value) {
    final kept = <int>[
      for (var i = 0; i < components.length; i++)
        if (selected[i] == value) i,
    ];
    return Module._(
      components: <ComponentBase>[for (final i in kept) components[i]],
      origins: <String?>[for (final i in kept) origins[i]],
      debugLabel: debugLabel,
    );
  }

  int _indexOf(DiKeyBase key) {
    final matches = <int>[
      for (var i = 0; i < components.length; i++)
        if (components[i].key == key) i,
    ];
    if (matches.length != 1) {
      throw ArgumentError.value(
        key,
        'key',
        matches.isEmpty
            ? 'no member publishes it'
            : '${matches.length} members publish it',
      );
    }
    return matches.single;
  }

  /// The concatenation of this module and [other]. The result is unnamed.
  Module operator +(Module other) => Module.all(modules: <Module>[this, other]);

  @override
  String toString() => debugLabel == null
      ? 'Module(${components.length})'
      : 'Module($debugLabel)';
}
