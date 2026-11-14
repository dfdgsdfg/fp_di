A `Dependency` describes how a value is created from the keys that it reads.
Building or combining a `Dependency` runs nothing. A scope runs it when the
component that holds it activates.

- `Dependency(create:, dispose:)` reads no key.
- `Dependency1` to `Dependency8` read one to eight keys and create the value
  in one call.
- A chain adds steps, optional reads, and lazy values:
  `Dependency.require<A>().map(...)`, `Dependency.maybe`, and `lazy()`.
- `(d1, d2).zip` combines a record of `Dependency` values into a
  `Dependency` of a record.

Each step can own its value through `dispose`. A failed activation runs the
`dispose` functions of the completed steps in reverse order. A step reads the
`CancellationToken` of its activation with `Dependency.cancellation()` to stop
early, and a `Lazy` creates its value at the first `force`.

## Two steps

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
component publishes, as a token key (Scopes and modules in the Declaration topic) orders two members.

`create` runs on each activation, never when the component is built. A
`Dependency` that reads no key makes a component that never waits. One that
reads keys makes a component that waits until they resolve and activates again
when their publishers change. An effect publishes nothing. A
`Module` is the list of components that a scope declares, and a node is a
component that the scope created in `initialize()`.

The `Dependency` type describes all the reads of one component. It is not one
key: a `DiKeyBase` is one key that a component reads.

## Primitives

```dart
// No input: create runs on each activation; dispose is optional.
Dependency<A>       Dependency<A>({required FutureOr<A> Function() create,
    FutureOr<void> Function(A value)? dispose});

// The common case: read N keys and create the value, like ProxyProvider2.
Dependency2<A, B, R> Dependency2({DiKey<A>? key1, DiKey<B>? key2,
    required FutureOr<R> Function(A, B) create, FutureOr<void> Function(R)? dispose});
// ... Dependency1<A, R> to Dependency8<A, ..., H, R>; each is a Dependency<R>.

// A Dependency chain: reads keys, never publishes.
Dependency<T>       Dependency.require<T>({DiKey<T>? key});     // adds to requires
Dependency<T?>      Dependency.maybe<T>({DiKey<T>? key});       // adds to optional
Dependency<(A, B)>  Dependency.require2<A, B>({DiKey<A>? key1, DiKey<B>? key2});
Dependency<Set<T>>  Dependency.requireSet<T>({required DiSetKey<T> key});  // every contribution; maybeSet: the active ones
Dependency<Map<String, T>> Dependency.requireMap<T>({required DiMapKey<T> key}); // every id; maybeMap
// ... up to Dependency.require8; there is no require1 (use Dependency.require)
Dependency<B>       map<B>(FutureOr<B> Function(A) create,
    {FutureOr<void> Function(B)? dispose});                 // a next step, owned if dispose
Dependency<Lazy<A>> lazy();                                 // create on first force()
// On Dependency<(A, B)> .. Dependency<(A, ..., H)>:
Dependency<R>       mapN<R>(FutureOr<R> Function(A, B) create, {FutureOr<void> Function(R)? dispose});
// On a record of 2 .. 8 Dependency values:
Dependency<(A, B)>  get zip;                                // (d1, d2).zip

// A component: a Dependency plus its published key, DiKey<A>() by default.
Component<A>        Component<A>({required Dependency<A> dependency, DiKey<A>? key, String? debugLabel});
Component<A>        Component<A>.value({required A value, DiKey<A>? key, String? debugLabel}); // existing value
Component<A>        Component<A>.effect({required Dependency<A> dependency, String? debugLabel}); // publishes nothing
Component<A>        Component<A>.into({required DiSetKey<A> key, required Dependency<A> dependency}); // a set contribution
// The key type must equal A. A must not be void, dynamic, or Null: use Component.effect.
// A DiKey of bool, int, String, ... (core value types) needs a name, in the key
// and in every read: DiKey<PoolSize>(name: 'PoolSize') (see the Keys topic).
// ComponentBase: the element type of a list of components of any type.

// Scopes (see the Declaration topic):
final class Module { Module({required Iterable<ComponentBase> components, String? debugLabel});
    Module.all({required Iterable<Module> modules, String? debugLabel});
    Module operator +(Module other);
    List<String?> get origins;                  // the label of the module that listed each member
    Module replacing({required DiKeyBase key, required ComponentBase component});   // a new module
    Module without({required DiKeyBase key});  Module where(bool Function(ComponentBase) test);
    Module overriddenBy(Module overrides);                  // each fake replaces the member of its key
    Module requiring({required Iterable<DiKeyBase> keys, Iterable<DiKeyBase> ancestorKeys});   // the members that require an absent key
    Module withoutRequiring({required Iterable<DiKeyBase> keys, Iterable<DiKeyBase> ancestorKeys});  // the module without them
    Set<DiKeyBase> publishes, requires, reads;                     // derived shape
    Map<DiSetKey<Object?>, int> contributes; }                         // set contributions per key
Scope             Scope({Module? module});              // a root, declared
Scope             child({Module? module});                // a child, declared
Future<Scope>     initialize();                           // creates them; completes with the scope
ComponentNode<T> node<T>({required DiKey<T> key});       // the node of the member that publishes key
List<ComponentNode<Object?>> get nodes;                   // every node, declaration order
Future<void>        dispose();                              // disposes the scope and its children
```

## Values without inputs

`create` runs on each activation, never when you build the component, and may
return a `Future`. A registration list can hold components and drop some of
them before a scope declares them, without constructing them.

```dart
final registrations = <ComponentBase>[
  Component<Database>(
    dependency: Dependency<Database>(
      create: Database.open,
      dispose: (db) => db.close(),
    ),
  ),
  if (debug)
    Component<DebugTools>(
      dependency: Dependency<DebugTools>(create: DebugTools.new),
    ),
];
```

A `dispose` argument is the only way to dispose a value, so every value that
needs a `dispose` is created on activation. A `Dependency` that returns an
existing value with no `dispose` is safe, for example
`Dependency(create: () => config)`. Do not give a `dispose` to one that
returns an existing value: each teardown disposes the same object, and a
later activation publishes the disposed object.

`Component.value(value: value, key: ...)` makes a component of a value that
exists before activation. Use it for configuration and for values that
another owner closes.

## Chaining and arguments

The API has two styles with one boundary, the `dependency:` argument:

- **Values are functional.** A `Dependency` is an immutable value. A
  `DependencyN` class states its reads and its value in one call, and a chain
  adds steps; in both, the type flows from the inputs to the output.
- **Declarations follow Flutter.** `Component<T>`, `Module`, and `Scope`
  state the type argument first and take named arguments, like widgets. The
  output type is written once, on `Component<T>`.

A method chains only for an algebraic step, such as `map`, `mapN`, or
`lazy`. Every constructor and configuration value, including the key, is
a named argument.

Dart infers a type argument from all the arguments of a call, so
`Component(dependency: <a Foo>, key: DiKey<Bar>())` would infer
`Component<Object>`. The constructor rejects it, because the key type must
equal the type argument. A list of components uses the element type
`ComponentBase`, which has no type argument. A generic element type such as
`Component<Object?>` would become the inference context of every component
in the list and fix its type to `Object?`. Provider's `SingleChildWidget`
solves the same problem for `MultiProvider`.

## Dependencies

For the common case, read the keys and create the value in one class, like
Provider's `ProxyProvider2`. `Dependency1<A, R>` to `Dependency8<A, ..., H, R>`
take the input types, then the output type:

```dart
Component<Repository>(
  dependency: Dependency3<Database, Cache, Logger, Repository>(
    create: Repository.new,
  ),
);

extension type const PoolSize(int value) implements int {
  static const key = DiKey<PoolSize>(name: 'PoolSize');
}

Component<Pool>(
  dependency: Dependency2<Database, PoolSize, Pool>(
    key2: PoolSize.key,                            // a named key for one input
    create: (db, size) => Pool(db, size),
    dispose: (pool) => pool.close(),             // only when the value needs it
  ),
);
```

Without `dispose`, `create` is a plain step. With `dispose`, the component
owns the value and disposes it before the values it reads. Each key defaults to
`DiKey<T>()` of its type. A `DependencyN` is a `Dependency`, so it has the
same shape as the matching `requireN` and chains like any `Dependency`.

For more than one step, an optional read, or a lazy value, chain a
`Dependency` instead. `Dependency.require` reads one key, `require2` to
`require8` read several keys and yield a record in key order, and the
component waits until all of them resolve. `mapN` spreads the record into
positional arguments.

| Step | Value | Dispose |
|---|---|---|
| `map(f)` | a new value, for example a constructor tear-off | none; what earlier steps own stays owned |
| `map(f, dispose: d)` | a new value that the component owns | disposed before the earlier steps |
| `lazy()` | a `Lazy` of the value, created on the first `force()` | disposed with the owner only if created |

```dart
Dependency.require<Config>()
    .map((config) => config.url)                  // a plain step
    .map(Database.new, dispose: (db) => db.close())   // an owned step
```

A `dispose` receives the value that its step created. When a `dispose` needs an
input as well, keep the input in the value, or read it in a separate
component.

A record of `Dependency` values has a `zip` getter. `(d1, d2).zip` yields
`(value1, value2)` in record order, and its shape is the union of the shapes.
The `Dependency` values run left to right, and what they own is disposed
right to left. Use it to mix a
required and an optional read:

```dart
Component<Repository>(
  dependency: (Dependency.require<Api>(), Dependency.maybe<Cache>())
      .zip
      .mapN(Repository.new),
);
```

## Values, factories, and lazy values

The type states the lifetime:

| Type | Meaning | Build with |
|---|---|---|
| `A` | constructed during activation | `Component<A>(dependency: Dependency<A>(...))` or a `DependencyN` |
| `A Function()` | a new value per call, owned by the caller | `Component<A Function()>(dependency: Dependency1<B, A Function()>(create: (b) => () => A(b)))` |
| `A Function(P)` | a new value per call from an argument | the same, with the parameter in the type: `DiKey<A Function(P)>()` |
| `Lazy<A>` | created on first `force()`, disposed with the owner only if created | `d.lazy()` for any `Dependency` `d`, held by the service that you publish: `d.lazy().map(Service.new)` |

**Factories.** A factory is a component whose value is a function, and the
function type is the key. The `Dependency` reads the keys when the component
activates, so they stay tracked: a new publisher of a key rebuilds the factory
and the components that read it. A parameter is part of the type, so the
compiler checks it. Name the type with a `typedef`, and give a parameter of the
returned closure its type, because inference does not reach it:

```dart
typedef RowViewFactory = RowView Function(String id);

final rowViewFactory = Component<RowViewFactory>(
  dependency: Dependency1<Database, RowViewFactory>(
    create: (db) => (String id) => RowView(db, id),
  ),
);

// A reader takes the function like any other value.
final screen = Component<Screen>(
  dependency: Dependency1<RowViewFactory, Screen>(create: Screen.new),
);
```

The runtime does not own what a factory returns: no `dispose` runs for those
values, so the caller releases them. Read the keys in the `Dependency`, not
inside the returned function, so they stay part of the shape.
`example/factory.dart` shows a factory with and
without a parameter.

**Cached factories.** A factory that returns one value per argument keeps its
values, so the cache needs an owner. Create the cache in a step with a
`dispose`, and publish its lookup function in a `map` step:

```dart
final rowViewFactory = Component<RowViewFactory>(
  dependency: Dependency1<Database, RowViewCache>(
    create: RowViewCache.new,                  // holds a Map<String, RowView>
    dispose: (cache) => cache.close(),         // releases every cached value
  ).map<RowViewFactory>((cache) => cache.view),
);
```

The cache lives as long as one activation. A new publisher of `Database`
releases the cached values and builds an empty cache, so a reader never gets
a value of the old database. Make the lookup throw after `close`, because a
caller can keep the function of an old activation.
`example/cached_factory.dart` runs this recipe.

`lazy()` reads the keys at activation, so they stay tracked: a change of
their publishers reactivates the owner, which disposes the old `Lazy`. It
defers every step of that `Dependency` to the first `force()`.

**Keep `Lazy` inside the component.** Whether a value is lazy is a choice of
its producer. A key that publishes `Lazy<Repo>` makes that choice part of the
key. A switch between eager and lazy then changes `DiKey<Repo>` to
`DiKey<Lazy<Repo>>`, and every reader must change its read and await
`force()`. A reader that still reads the old key fails at `initialize` with
`UndeclaredKeyError`, not at compile time. Publish the service that uses the
value instead, and call `force()` inside it:

```dart
final class Catalog {
  Catalog(this._repo);

  final Lazy<Repo> _repo;

  Future<List<Item>> items() async => (await _repo.force()).items();
}

Component<Catalog>(
  dependency: Dependency1<Api, Repo>(
    create: Repo.new,
    dispose: (repo) => repo.dispose(),
  ).lazy().map(Catalog.new),
);
```

Only `Catalog` knows that `Repo` is lazy, so the producer can change that
choice without a change to the readers. The `map` after `lazy()` creates no
resource, so the lazy step stays the last step with effects. Readers of
`Catalog` already wait for `items()`; a reader that needs a plain value
awaits it once, at its entry point, and passes the value on.

To keep one step eager and make another lazy in the same component, `zip`
them: `(eager, lazyPart.lazy()).zip`.

Concurrent first calls share one acquisition. A failed acquisition reaches the
caller, is not cached, and does not deactivate the owner. Disposal waits for an
in-flight creation, then disposes it; `force()` after disposal throws
`DisposedLazyException`.

## Cancellation

`dispose()` cancels the setup that is still running in the disposed scope, its
descendants, or the disposed member. The token of each such activation is
canceled inside the `dispose()` call, before the disposal waits in the queue.
The runtime checks the token before each step, so no new step starts; a step
that is running finishes, and the steps that completed are disposed in reverse
order. Nothing is published, and `initialize()` fails with
`ActivationCanceledException`. A setup that had not started never runs. This
is not an activation failure: the runtime does not report it on
`Scope.errors` and does not suppress a later activation, but it reports the
dispose functions that failed during the rollback.

A long step stops sooner when it reads the token:

```dart
final session = Component<Session>(
  dependency: (Dependency.require<Api>(), Dependency.cancellation())
      .zip
      .mapN((api, token) => api.login(cancel: token.whenCanceled),
            dispose: (s) => s.logout()),
);
```

Disposing a member also cancels the activations in flight that read its value,
or the value of a member that its withdrawal deactivates. Such an activation
rolls back, stays inactive until the withdrawal finishes, and then activates
against the new publishers, such as a fallback in an ancestor. An `initialize`
that started it still succeeds.

A failed step cancels the token of its activation before the rollback, so a
`dispose` of an earlier step sees `isCanceled` and a worker it started can
stop. A `Lazy` creation has its own token, a child of the owner's: the owner's
disposal stops it, and its own failure leaves the owner active.

The token lives as long as the activation, so it is also canceled when an
active node deactivates. A value that keeps it, such as a polling loop,
can stop then. Logging out during a login therefore does not expose the old
session, and the next login starts after its rollback.

`whenCanceled` never fails, so it works as an abort trigger. Pass it to
`package:http`, or forward it to a dio `CancelToken`:

```dart
client.send(AbortableRequest('GET', url, abortTrigger: token.whenCanceled));

final cancel = CancelToken();
unawaited(token.whenCanceled.then((_) => cancel.cancel()));
await dio.get(path, cancelToken: cancel);
```

To call a cancelable function outside the runtime, such as in a unit test, pass
`CancellationToken.none`, which is never canceled, or the `token` of a
`CancellationController`, which you cancel:

```dart
final controller = CancellationController();
final result = login(api, controller.token);
controller.cancel();
expect(await result, isA<Aborted>());
```

`example/cancellation.dart` shows a logout
during a login, a value that is disposed while it is read, and a failed step.
