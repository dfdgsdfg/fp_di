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

## Scopes and modules

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

Each member stays its own node. A member that waits for a key does not block
its siblings, and each member reactivates on its own. Members can depend on
keys that a later member publishes.

`initialize()` activates members by dependency. A member starts when every
member that publishes a key it reads has settled, and a member
with no such dependency starts at once. Independent members therefore activate
at the same time, so a scope of slow members takes as long as its slowest
chain and not the sum. A member publishes its bindings as soon as its own
activation succeeds, and a dependent never starts before its publishers have.
The commit order of independent members follows completion order and is not
deterministic.

`dispose()` releases along the same reads in reverse: a member releases after
every member that read its value has finished, and members that do not read
each other release at the same time. The dispose functions of one member run
last first, and a `DisposeException` lists dispose failures in reverse declaration
order. Two members that share an external resource without a key between
them, such as one file that one flushes and the other closes, need a token key
so that their releases keep an order.

```dart
// Both probes run at the same time; `sync` starts when both are ready.
final app = Scope(module: Module(components: [connectivity, database, sync]));
await app.initialize();
```

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
token and the order with one. Effects that overlap in the Instance topic
lists the patterns that keep members without a key between them safe.

A child can initialize before its parent. Its nodes wait, and they activate
when the parent initializes and publishes their keys. A scope that initializes
later between a node and its publisher shadows that publisher, so the node
rebinds. These are the only ways that a key appears for an existing node.

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

Dormancy is not failure. If the activation of any member throws, `initialize()`
is atomic, whatever the declaration order. No further member starts, and the
runtime waits for the members still in flight; a failure does not cancel
another member, because each member is its own failure region. Then
every node that the call created is deactivated and disposed in reverse
declaration order, and the error of the first failed member in declaration order
is rethrown. The scope stays uninitialized, and a later `initialize()` may
retry. Rollback dispose failures are attached to an `ActivationException`. A
node of a descendant scope that wakes because of the new bindings keeps the
usual rule: its failure is reported through `Scope.errors` and `initialize()`
succeeds. Of two members that publish the same key, the later one fails with
`DuplicateKeyError`. A second `initialize()` throws a `StateError`.

The atomicity covers failure, not visibility. Each member's bindings become
visible when that member commits, so other code can see some members before
`initialize()` returns. Publish a record under one key when several values
must become visible together.

`node(key: ...)` returns the node of the member that publishes the key,
typed as the key, so the code does not depend on the declaration order:
`value`, `isActive`, `whenActive`, `missing`, and `dispose()`. `nodes` lists
every node in declaration order, for an effect, which publishes no key.
Disposing one member withdraws its bindings, deactivates its dependents
first, and leaves the other members in the runtime. `dispose()` of the scope then
skips the members that are already disposed.

```dart
final database = app.node(key: DiKey<Database>());
await database.dispose();   // its dependents go dormant
```

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
