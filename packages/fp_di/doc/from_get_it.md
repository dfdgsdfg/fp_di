This guide is for readers who know [get_it](https://pub.dev/packages/get_it).
It maps each get_it call to its `fp_di` form, explains where the two models
differ, and suggests an order for moving an application over. The get_it
names are those of its current API.

## Two models

get_it is a service locator. You register factories in a global object, one
call at a time, and you ask the object for an instance wherever you need it.
The order of the registrations and of the `get` calls decides when an
instance is created.

`fp_di` declares first and runs later. You describe every component as a
value: what it reads, what it publishes, and how its value is created and
released. A `Module` lists the components, and a `Scope` runs a module. The
runtime derives the order of creation and release from the keys that each
component reads, so the list order does not matter, and a missing
registration is reported by `initialize` before anything is created.

| get_it | `fp_di` |
|---|---|
| One global `GetIt.instance` | A `Scope` that you create and pass on, or publish with `ScopeProvider` |
| Registration calls that run one after another | A `Module`: a list of `Component` values, fixed when the scope is created |
| A type, optionally with an `instanceName` | A key: `DiKey<T>()`, or `DiKey<T>(name: ...)` |
| `dependsOn` and `allReady()` | The reads of each `Dependency`; `await scope.initialize()` |
| `dispose:` on a registration | `dispose:` on a `Dependency`, run in reverse order of the reads |
| `pushNewScope` / `popScope` | `scope.child(module: ...)`, `initialize()`, and `dispose()` |

With a locator, several facts about the app live only in your head: who needs
whom, what must exist before what, and what to undo when something fails or
goes away. You keep them true by hand. In `fp_di` each of them follows from
the shapes of the components and from how pairs of `create` and `dispose`
compose, so the runtime keeps them true.

The sections below follow the life of the dependencies: registration, the
running app, release, and tests. Each case shows what you watch for with
get_it, and the rule that makes it unnecessary in `fp_di`.

## Registration

### Registrations

```dart
// get_it: one call for each registration.
getIt.registerSingleton<Config>(config);

getIt.registerLazySingleton<Api>(
  () => Api(getIt<Http>()),
  dispose: (api) => api.close(),
);

getIt.registerFactory<Form>(() => Form(getIt<Api>()));

getIt.registerSingletonAsync<Db>(
  () => Db.open(),
  dispose: (db) => db.close(),
);

getIt.registerSingleton<Duration>(
  const Duration(seconds: 5),
  instanceName: 'timeout',
);

// fp_di: one component for each registration.
final config = Component<Config>.value(value: config);

final api = Component<Api>(
  dependency: Dependency1<Http, Api>(
    create: Api.new,
    dispose: (api) => api.close(),
  ),
);

final form = Component<Form Function()>(
  dependency: Dependency1<Api, Form Function()>(
    create: (api) => () => Form(api),
  ),
);

final db = Component<Db>(
  dependency: Dependency<Db>(
    create: Db.open, // may return a Future
    dispose: (db) => db.close(),
  ),
);

final timeout = Component<Duration>.value(
  value: const Duration(seconds: 5),
  key: const DiKey<Duration>(name: 'timeout'),
);
```

Collect the components in a module and run it:

```dart
final app = Scope(
  module: Module(components: [config, http, api, form, db, timeout]),
);
await app.initialize();   // instead of await getIt.allReady()
```

A few registrations change their meaning on the way:

- **Lazy singletons are created at `initialize`.** A component activates as
  soon as its keys resolve, not at the first `get`. To defer the work to the
  first use, keep the value behind a `Lazy` inside the service that uses it:
  `dependency.lazy().map(Service.new)`. The Dependency topic shows the recipe.
- **A factory is a component whose value is a function.** The function type
  is the key, so `getIt<Form>()` becomes `scope.get<Form Function()>()()`.
  `registerFactoryParam<Row, String, void>` becomes a component of
  `Row Function(String)`, and the compiler checks the argument. Name the
  function type with a `typedef`.
- **`dependsOn` disappears.** A component that reads `Db` waits for the
  component that publishes `Db`. You never list the order.
- **Each async registration is just an async `create`.** A `create` may
  return a `Future`, and independent members start at the same time.

### The order of startup

With get_it, you write the order. With `fp_di`, `initialize` derives it.

```dart
// get_it: you write the order.
getIt.registerSingletonAsync<Http>(Http.connect);
getIt.registerSingletonAsync<Db>(Db.open);
getIt.registerSingletonAsync<Api>(
  () async => Api(getIt<Http>()),
  dependsOn: [Http],
);
getIt.registerSingletonAsync<Repo>(
  () async => Repo(getIt<Api>(), getIt<Db>()),
  dependsOn: [Api, Db], // must match the calls above
);
await getIt.allReady();

// fp_di: the reads are the order.
final app = Scope(
  module: Module(components: [repo, api, db, http]), // any order
);
await app.initialize();
```

`dependsOn` waits only for the types that it lists, so a dependency that a
factory uses and the list misses is not waited for. In `fp_di` the components
state their reads once, where they create the value, and the list order does
not matter:

```dart
final api = Component<Api>(
  dependency: Dependency1<Http, Api>(create: Api.new),
);
final repo = Component<Repo>(
  dependency: Dependency2<Api, Db, Repo>(create: Repo.new),
);
```

**Why it holds.** The shape of a `Dependency` is the set of keys that it
reads, and it is computed from the expression, so it cannot miss a read:

```text
requires(DependencyN<A1, …, An, R>(…)) = {A1, …, An}
```

The order is one relation between members, where `provides(a)` is the key that
`a` publishes or the collection key that it contributes to:

```text
a ⇢ b   ⇔   provides(a) ∩ reads(b) ≠ ∅
b starts after each a with a ⇢ b has settled
```

`Repo` reads `Api` and `Db`, so it starts after both. `Http` and `Db` have no
path of `⇢` between them, so they start at the same time, and startup takes
as long as the slowest chain, not the sum of all services.

### A forgotten registration

With get_it, a missing registration throws at the first `getIt<T>()` that asks
for it, which may be a screen that few users open.

In `fp_di` the missing keys are a set that the runtime computes from the
shape before it creates anything:

```text
undeclared(m) = requires(m) \ ⋃ publishes(ancestors)
initialize throws UndeclaredKeyError   unless undeclared(m) = ∅
```

`ShapeGraph.of(module).undeclared` computes the same set in a test, for every
variant of the app, without starting a service.

### A failure halfway through startup

With get_it, the singletons that were created before a failing one stay
created. Cleaning them up, or resetting the locator before a retry, is your
code.

In `fp_di` a failure undoes exactly what was done, in reverse. Within one
component this is the composition of pairs; across members, `initialize`
releases every node that it created, in reverse order:

```text
c₁ … c_{j-1} completed and c_j throws   ⇒   d_{j-1} ∘ … ∘ d₁ runs
```

The scope returns to `declared`, so a retry is a second `initialize`.

## Runtime

### Lookups

Both libraries let a class take its values as constructor arguments, so the
class itself need not know about the container. The difference is who knows
what the class reads:

```dart
class Repo {
  Repo(this.api, this.db);
  final Api api;
  final Db db;
}

// get_it: the factory looks the values up when it runs.
getIt.registerLazySingleton<Repo>(() => Repo(getIt<Api>(), getIt<Db>()));

// fp_di: the component declares what it reads.
final repo = Component<Repo>(
  dependency: Dependency2<Api, Db, Repo>(create: Repo.new),
);
```

With get_it, the `getIt<Api>()` and `getIt<Db>()` calls run inside the
factory, so the locator learns of them only when they run. It cannot order
`Repo` after `Api` and `Db`, wait for them, or tell you before startup that
one is missing; `dependsOn` and the registration order make up for that by
hand. The same holds whether the lookup sits in the factory or inside the
class.

With `fp_di`, `Api` and `Db` are the shape of the component, known before
anything runs. The runtime uses that shape for the order of startup, for the
wait while a key is missing, for the rebuild when a publisher changes, and
for the check that `initialize` runs first. A lookup with `scope.get` is left
only at the edges of the app: the entry point that starts it, a widget that
reads with `context.di<T>()`, and a test that checks a value.

The table maps every get_it lookup, for the places that still need one. Most
apps need only the first two rows. The others answer questions that the
runtime already answers: `initialize` rejects a key that nothing publishes,
so you do not ask whether a type is registered, and a component waits for its
keys, so you do not ask whether a service is ready.

| get_it | `fp_di` |
|---|---|
| `getIt<T>()`, `getIt.get<T>()` | `scope.get<T>()`, or `context.di<T>()` in a widget |
| `getIt<T>(instanceName: 'n')` | `scope.get<T>(key: const DiKey<T>(name: 'n'))` |
| `getIt.isRegistered<T>()` | Rarely needed. `module.publishes.contains(const DiKey<T>())`, or `scope.findNode<T>() != null` after `initialize` |
| `getIt.isReadySync<T>()` | Rarely needed. `scope.findNode<T>()?.state.phase == NodePhase.active` |
| `await getIt.isReady<T>()` | Rarely needed. `await scope.node(key: const DiKey<T>()).whenActive`, after `initialize` |
| A lookup inside a factory | Not a lookup: a read in the `Dependency`, such as `Dependency1<A, T>` or `Dependency.require<A>()` |

Read inside the `Dependency`, never with `scope.get` inside `create`. A read in
the `Dependency` is part of the shape: the runtime orders the components by
it, waits for it, and rebuilds the component when the publisher changes. A
`get` inside `create` is invisible to all three.

`get` throws an `UnavailableKeyException` when the key has no value, and the
exception names the failed activations behind the key. `maybeGet` returns
null instead.

### Services that come and go

With get_it, code that uses a service that only exists after login checks
`isRegistered`, or catches the error, and a reference taken before logout
stays in use after it.

In `fp_di` a component runs only while every key that it requires resolves:

```text
satisfied(n)  ⇔  ∀ k ∈ requires(n). k resolves in the scope of n
```

When a publisher appears, the waiting components activate. When it goes away,
every component that read it is released first and waits again. No reader
holds a value whose publisher is gone.

### Variants of the app

With get_it, a web build without a camera skips the camera registration, and
also every registration that needs the camera, directly or through another
service. That list is kept by hand.

In `fp_di` the list is computed from the shapes. `withoutRequiring` removes
each member that requires an absent key, and the keys of the removed members
become absent in turn:

```text
requires(c) ∩ K = ∅                         for each c in withoutRequiring(m, K, A)
requires(withoutRequiring(m, K, A))  ⊆  requires(m) ∪ A
```

The result never needs a key that you did not name, so `initialize` accepts
it.

## Release

### Scopes

get_it has one stack of scopes. `fp_di` has a tree: a child scope reads the
keys of its ancestors, and a nearer publisher shadows a farther one.

```dart
// get_it: a stack of scopes.
getIt.pushNewScope(
  scopeName: 'session',
  init: (getIt) => getIt.registerSingleton<Session>(Session(user)),
);
// ...
await getIt.popScope();

// fp_di: a tree of scopes; a child reads its ancestors.
final session = await app
    .child(
      module: Module(
        components: [Component<Session>.value(value: Session(user))],
      ),
    )
    .initialize();
// ...
await session.dispose(); // releases the session; the app scope stays
```

The disposal releases each member after the members that read it, while the
values that it read are still alive. You do not order the `dispose`
functions yourself.

### The order of teardown

With get_it, the order of the registrations is the order of the disposal,
reversed: the last registered object is disposed first. You keep that order
in step with who uses whom. With `fp_di`, `dispose` derives it.

```dart
// get_it: register each service after the services that it uses.
getIt.registerSingleton<Http>(
  Http(),
  dispose: (http) => http.close(),
);
getIt.registerSingleton<Api>(
  Api(getIt<Http>()),
  dispose: (api) => api.close(),
);
// A service registered before Http that uses it
// would be disposed after Http was closed.
await getIt.reset();

// fp_di: readers first, unrelated members at the same time.
await app.dispose();
```

**Why it holds.** A `Dependency` is a pair of `create` and `dispose`, and
pairs compose like functions and their inverses: the `create` functions run
forward, and the `dispose` functions run backward.

```text
(c₂, d₂) · (c₁, d₁)  =  (c₂ ∘ c₁ ,  d₁ ∘ d₂)
```

Across members, the release follows the same relation `⇢` as startup, in
reverse:

```text
a releases after each b that read a value of a
```

Every release therefore runs while the values that it reads are still alive,
and members without a path of `⇢` between them release at the same time.

## Test

### Fakes

With get_it, a test calls `reset()` or sets `allowReassignment` and registers a
fake. A fake for a type that was renamed or moved replaces nothing, and the
test still passes against the real service.

In `fp_di` a test edits the module before the scope exists, and an override
must replace exactly one member that publishes its key. `overriddenBy` throws
otherwise, so the mistake fails the test:

```dart
final underTest = appModule.overriddenBy(
  Module(components: [Component<Api>.value(value: FakeApi())]),
);
final scope = await Scope(module: underTest).initialize();
```

### A part of the graph

With get_it, a test that needs only some services registers them by hand, and
keeps that list in step with what those services need.

In `fp_di` a test takes the module of the app and removes what it does not
provide. `withoutRequiring` follows the required keys, so the result needs no
key that the test did not name:

```dart
// Everything that does not need the network.
final offline = appModule.withoutRequiring(keys: {const DiKey<Http>()});
```

The Declaration topic explains both edits.

## Where the guarantees stop

The rules above hold for what the runtime controls. A `dispose` function is
yours: the runtime runs it in the right order, but it cannot prove that it
undoes its `create`. Members without a key between them may run at the same
time, so they must not share state outside the keys; a token key orders them.
The [algebra](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/README.md#the-algebra)
section of the README lists the laws and their conditions.

## Flutter

Publish the scope once, above the widgets that read it:

```dart
runApp(ScopeProvider.fixed(scope: app, child: const App()));

// In a widget, instead of getIt<Api>():
final api = context.di<Api>();
```

`context.watchDi<T>()` also rebuilds the widget when the value of the key is
replaced. For a scope that changes, such as a login session, publish a
`ValueListenable<Scope>` with `ScopeProvider.listenable`. The
[`fp_di_flutter` README](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di_flutter/README.md)
explains the rules for routes and dialogs.

## Moving an application

1. **Write a module for each package or feature.** Turn each registration into
   a component, and move each `getIt<T>()` inside a factory into the reads of
   its `Dependency`.
2. **Write the type argument of every component.** `Component<Api>` publishes
   `DiKey<Api>()`. Without it, Dart infers the implementation type, and a
   reader of the interface does not find the value.
3. **Name the keys of core types.** A `DiKey` of `int`, `String`, `bool`, or
   another core value type needs a `name`, because a bare `int` says nothing
   about which value it is.
4. **Compose and check.** Combine the modules with `Module.all` or `+`. Run
   `initialize` in a test: it reports every key that no member publishes and
   every key that two members publish, before anything is created.
   `ShapeGraph` from `package:fp_di/tooling.dart` reports the same without a
   scope.
5. **Replace the lookups.** Keep one place that holds the root scope, and
   replace `getIt<T>()` with `scope.get<T>()` there, or with `context.di<T>()`
   in widgets. Code that runs during startup moves into components, so it
   runs in the order of its reads.
6. **Replace scopes.** Each `pushNewScope` becomes a child scope that the code
   which pushed it creates, initializes, and disposes.
