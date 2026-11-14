A declaration states what a scope holds. It creates nothing.

- A `Component` publishes the value of its `Dependency` under a key, or
  contributes the value to a set key.
- A `Module` is an immutable list of components. Its edits return a new
  module, and its derived shape states the keys that it publishes and
  requires.
- A `Scope` declares a module. `initialize` creates the members, and
  `dispose` releases them. A child scope reads the keys of its ancestors.

The declarations follow Flutter conventions: the type argument first, named
arguments, and a value that is built first and mounted later.

## Components

A component description follows two steps:

1. **Create the value.** A `Dependency` states the keys that the value needs
   and how it is created from them, with an optional `dispose`. The number of
   inputs picks the form:

   | Inputs | Form |
   |---|---|
   | none | `Dependency<R>(create: () => ..., dispose: ...)` |
   | one to eight keys | `Dependency1<A, R>` to `Dependency8<A, ..., H, R>(create: (a, ...) => ..., dispose: ...)` |
   | several steps, optional reads, lazy | a chain: `Dependency.require<A>().map(...)`, `.lazy()` |

2. **Make a component.** `Component<T>(dependency: ...)` states the type that
   it provides, like `Provider<T>`, and publishes `DiKey<T>()`. Pass `key` for
   a named key. Diagnostics label it by its key; pass `debugLabel` only to tell
   apart components that the key does not, or an effect.

```dart
Component<Database>(                                      // 2. what it publishes
  dependency: Dependency1<Config, Database>(                  // 1. create the value
    create: (config) => PgDatabase(config.url),
    dispose: (db) => db.close(),
  ),
);
```

The type argument states what the component publishes, so an implementation
such as `PgDatabase` is published under the port `Database`. A `key`
replaces the default `DiKey<T>()`, and Dart checks it against the type
argument; a key of an unrelated type, which widens the inferred type to
`Object`, throws an `ArgumentError` where the component is built.

**Always write the type argument.** Without it, Dart infers the type of the
implementation: `Component(dependency: Dependency(create: PgDatabase.new))`
publishes `DiKey<PgDatabase>()`. A required read of `Database` then fails at
`initialize` only when no scope declares `Database`; when an ancestor
publishes `Database`, the child silently reads the ancestor value. A reader of
`Component<T>(...)` also sees what a component publishes before how it is
built, as with `Provider<T>`. The examples also write the type arguments of
every `Dependency` and `DependencyN`. Dart infers some of them, but one rule
keeps the reads and the type argument visible.

A member whose value no other member reads is an effect:
`Component.effect(dependency: ...)` publishes nothing, and still waits for its
keys, reacts to them, and disposes what it owns. `Component<void>` throws an
`ArgumentError` that points to `Component.effect`; so do `dynamic` and
`Null`. A member that must wait for an effect reads a token type that a
component publishes, as a token key (see [Modules](#modules)) orders two members.

`create` runs on each activation, never when the component is built. A
`Dependency` that reads no key makes a component that never waits. One that
reads keys makes a component that waits until they resolve and activates again
when their publishers change. An effect publishes nothing. A
`Module` is the list of components that a scope declares, and a node is a
component that the scope created in `initialize()`.

The `Dependency` type describes all the reads of one component. It is not one
key: a `DiKeyBase` is one key that a component reads.

## Modules

A package exports a `Module`: a list of independent components. The
application composes modules and gives them to a scope, which creates them in
one call.

```dart
final infrastructure = Module(components: [database, cache, search], debugLabel: 'infra');
final features = Module(components: [repository, checkout]);

final app = Scope(module: Module.all(modules: [infrastructure, features, if (debug) debugTools]));
await app.initialize();
await app.dispose();   // readers first; unrelated members at the same time
```

The contents of a scope are fixed when it is created. No call adds a component
to an initialized scope; a new set of components is a new child scope. Plain
Dart conditionals choose the members; `fp_di` has no profile concept.

A module is a value, so edit it before a scope exists. Each edit returns a new
module and keeps the position of every remaining member:

```dart
final session = await app.child(
  module: sessionModule(id)
      .replacing(key: DiKey<Api>(), component: fakeApi)     // the one member that publishes Api
      .without(key: DiKey<DebugTools>()),        // the one member that publishes it
).initialize();                             // completes with the scope

sessionModule(id).requires;   // {DiKey<HttpClient>}: an ancestor must publish it
sessionModule(id).reads;      // requires plus the keys read optionally
```

`replacing` and `without` throw an `ArgumentError` when no member or more
than one member publishes the key, and `replacing` throws when the new
component does not publish it. `where(test)` keeps the members for which
`test` returns true. `overriddenBy(overrides)` replaces, for each member of
`overrides`, the one member that publishes the same key. It throws an
`ArgumentError` for an override that replaces nothing: an effect, one
whose key no member publishes, or two overrides of one key. A fake for a key
that moved or was misspelled therefore fails instead of being added.
`requires` lists the required keys that no other member
publishes; a member that requires its own key still needs another publisher.

A variant can have no publisher for a key, for example a platform service.
`withoutRequiring` removes each member that requires such an absent key. It
also removes each member that requires the key of a removed member.
`requiring` returns the removed members with the same arguments:

```dart
final absent = {const DiKey<Camera>()};
final root = Scope(module: all.withoutRequiring(keys: absent));
final removed = all.requiring(keys: absent).components;   // a test compares them
```

Only required reads count. A member that reads an absent key optionally, or
reads a collection, stays in the module. `ancestorKeys` holds the keys that an
ancestor scope also publishes. A removed member that publishes such a key does
not remove the members that require it.

The keys are the only order. When one member needs the effect of another, such
as a crash reporter that hooks into a global logger, the other member publishes
a token key and the first member requires it. The need is then part of the
shape: the reader starts after the token, waits while the token is missing,
activates again with it, and is disposed before it.

```dart
final class LoggingReady { const LoggingReady(); }

final logging = Component<LoggingReady>(
  dependency: Dependency<LoggingReady>(
    create: () { setUpLogging(); return const LoggingReady(); },
  ),
);
final crashReporter = Component<CrashReporter>(
  dependency: Dependency1<LoggingReady, CrashReporter>(create: (_) => CrashReporter()),
);
```

`example/token_key.dart` shows the failure without a
token and the order with one. Effects that overlap in the Lifecycle topic
lists the patterns that keep members without a key between them safe.

A member that requires a key that nothing declares could never activate, so
`initialize()` rejects it before creating anything:

```dart
final app = Scope(module: Module(components: [
  Component(dependency: Dependency(create: PgDatabase.new)),  // forgot <Database>: publishes DiKey<PgDatabase>
  repository,                                    // requires DiKey<Database>
]));
await app.initialize();
// UndeclaredKeyError: repository requires DiKey<Database>, but no member
// of this scope or its ancestors publishes it. ...
```

The check reads the declarations of the scope and its ancestors, initialized
or not, so a child can still initialize before its parent. It cannot see a
forgotten type argument when an ancestor publishes `Database`: the child then
reads the ancestor value. Optional reads through `Dependency.maybe` are not
checked. An effect, such as a listener,
publishes no key, so nothing can require it.

## The algebra of modules

A `Component` keeps the reads of its `Dependency` and adds the key that it
publishes:

```text
requires(Component<A>(d)) = requires(d)       optional(Component<A>(d)) = optional(d)
publishes(Component<A>(d))          = {A}
publishes(Component<A>(d, key: k))  = {k}
publishes(Component.effect(d))      = ∅
```

A `Module` `m = Module([c1, …, cn])` publishes what its members publish, and it
requires what a member requires and no other member publishes:

```text
publishes(m) = publishes(c1) ∪ … ∪ publishes(cn)
requires(m)  = ⋃i ( requires(ci) \ ⋃j≠i publishes(cj) )
```

`requires(m)` is exactly what an ancestor scope must publish. The `j ≠ i` is
deliberate: a member that requires the key that it publishes itself still
needs another publisher, usually an ancestor.

Modules compose by concatenation. A module has no `==`, so the laws compare
the members and their origins:

```text
(m1 + m2) + m3   =  m1 + (m2 + m3)  =  Module.all([m1, m2, m3])
m + Module([])   =  Module([]) + m  =  m

publishes(m1 + m2) = publishes(m1) ∪ publishes(m2)
requires(m1 + m2)  ⊆ requires(m1) ∪ requires(m2)
```

The last line is the useful one: composing two modules never adds a
requirement. A member of one module can only satisfy a requirement of the
other.

The edits are functions from a module to a module. `replacing`, `without`, and
`where` keep the position of every member that stays. `requiring` and
`withoutRequiring` follow the required keys: for a set of absent keys `K`, and
the keys `A` that an ancestor also publishes, they compute the smallest set of
members that require an absent key, where a removed member makes its own key
absent too:

```text
absent := K
repeat until no member joins:
  a member that requires a key of absent joins the result
  the key that it publishes joins absent, unless A holds it
```

The two results divide the module, and the removal never adds a requirement
that you did not name:

```text
components(requiring(m, K, A)) ⊎ components(withoutRequiring(m, K, A)) = components(m)
requires(c) ∩ K = ∅                       for each c in withoutRequiring(m, K, A)
requires(withoutRequiring(m, K, A))  ⊆  requires(m) ∪ A
```

For a child scope, pass the keys that the removed members of the parent
published, and pass the keys that the remaining members of the parent publish
as `A`:

```dart
final removed = all.requiring(keys: absent);
final sessionModule = session.withoutRequiring(
  keys: {...absent, ...removed.publishes},
  ancestorKeys: all.withoutRequiring(keys: absent).publishes,
);
```

The property tests in [`laws_test.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/test/laws_test.dart) check each of these laws with
generated modules.

## Variants: platform, flavor, and test

`fp_di` has no profile concept. An application environment such as dev, prod,
or test mixes three axes, and each axis has its own form:

| Axis | What varies | Form |
|---|---|---|
| Platform (mobile, web) | the implementation of a few boundary adapters | a small module that a Dart `switch` chooses |
| Flavor (dev, stag, prod) | mostly configuration | a value under `DiKey<Flavor>` that components read; a flavor-only member is a Dart `if` |
| Test | replacement of members | fakes in test code, applied with `overriddenBy` |

```dart
Module appModule({required Flavor flavor, required Platform platform}) =>
    Module.all(modules: [
      coreModule,                            // the same in every environment
      platformModule(platform),              // only the boundary adapters
      if (flavor != Flavor.prod) debugModule,
    ]);
```

Keep the members that do not vary in one module. Do not split a module by the
set of roots that run it: a use case that every environment needs belongs in
the core module, not in a "live" module. Keep fakes under `test/`, or in a
library such as `lib/testing.dart` that only test code imports. A production
module does not refer to a fake.

When the flavor is known only at runtime, for example from a remote config,
boot in two stages. A boot scope resolves the flavor, and its child declares
the application module of that flavor. The child reads `DiKey<Flavor>` through
the boot scope:

```dart
final boot = await Scope(module: bootModule).initialize();
final flavor = boot.get<Flavor>();
final app = await boot
    .child(module: appModule(flavor: flavor, platform: platform))
    .initialize();
```

Pass the flavor that the boot scope publishes to `appModule`. A second source
of the flavor can disagree with the value that components read. Without a boot
stage, for a compile-time flavor or in a test, build the `DiKey<Flavor>` value
and the module from one argument, as `appRoot` in the example does.

Every variant is a value, so a test checks each one before anything runs.
`requires` lists the keys that no member publishes; only the boot scope may
publish them. A key that two members publish is not in `requires`, and
`Module` does not reject it; only `initialize` throws `DuplicateKeyError`.
Check the duplicates too:

```dart
for (final flavor in Flavor.values) {
  for (final platform in Platform.values) {
    final module = appModule(flavor: flavor, platform: platform);
    expect(module.requires.difference(bootModule.publishes), isEmpty,
        reason: '$flavor/$platform');
    expect(duplicatesOf(module), isEmpty, reason: '$flavor/$platform');
  }
}
```

`Module.all` and `+` keep the origin of each member in `origins`: the label
of the module that listed it. `Module.all` takes its own `debugLabel` for the
composed module; the result of `+` has no label. A label affects `toString`
and the shape export (Exporting the shape in the Observation topic), which groups the members by
origin. The runtime does not read it.

`example/environments.dart` runs the three axes,
the two-stage boot, and the check, and defines `duplicatesOf`.

## Testing

A scope's contents are fixed, so a test declares its fake instead of swapping
a live member:

```dart
// 1. Replace the member in the module. This is the simplest way.
final di = await Scope(module: appModule.replacing(key: DiKey<Api>(), component: fakeApi)).initialize();

// Replace a set of members at once, for example the fakes of a test package.
final fakes = Module(components: [fakeApi, fakeClock, fakeStorage]);
final test = await Scope(module: appModule.overriddenBy(fakes)).initialize();

// 2. Shadow it in a child scope. Only nodes of the child see the fake.
final test = app.child(
  module: Module(
        components: [Component<Api>.value(value: FakeApi())],
      ) +
      featureModule,
);
await test.initialize();
```

A binding in a child scope does not change what a parent node reads. Declare
the fake in the scope of the code under test or above it. To test a late
arrival, initialize a child before its parent.

A key whose type is `FutureOr<T>` is unreachable, because no reader can
require it. The runtime rejects it with `UnreachableKeyError`.
