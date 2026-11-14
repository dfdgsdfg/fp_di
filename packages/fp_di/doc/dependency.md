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

## Pairs and shapes

A `Dependency` is a pair of functions. `create` makes a value from the keys
that it reads, and `dispose` releases that value. A step without `dispose` has
a `dispose` that does nothing. Write a step as `(c, d)`.

Steps combine like functions and their inverses: the `create` functions run
forward, and the `dispose` functions run backward. `map` puts a step after a
`Dependency`, and `zip` runs two of them side by side:

```text
sequence:  (c₂, d₂) · (c₁, d₁)  =  (c₂ ∘ c₁ ,  d₁ ∘ d₂)         dep.map(c₂, dispose: d₂)
product:   (c₁, d₁) ⊗ (c₂, d₂)  =  (c₁ then c₂ ,  d₂ then d₁)    (dep1, dep2).zip
unit:      (id, no-op)                                          dep.map((x) => x)

failure:   c₁ … c_{j-1} completed and c_j throws
           ⇒  d_{j-1} ∘ … ∘ d₁ runs, and nothing is published
```

So a chain of steps behaves as one pair, however you group it. A component
built from a long chain releases in exactly the reverse order of its
creation, and a failure halfway releases exactly what was created.

Every `Dependency` also has a **shape**: `requires(d)`, the keys that must
resolve before it runs, and `optional(d)`, the keys that it reads and that may
be absent. You never write the shape; each combinator computes it from its
parts:

```text
requires(Dependency(create, dispose))   = ∅
requires(Dependency.require<A>())       = {A}
optional(Dependency.maybe<A>())         = {A}
requires(DependencyN<A1, …, An, R>(…))  = {A1, …, An}

shape(d.map(f, dispose)) = shape(d.lazy()) = shape(d)
requires((d1, …, dn).zip) = requires(d1) ∪ … ∪ requires(dn)
optional((d1, …, dn).zip) = optional(d1) ∪ … ∪ optional(dn)
```

A step adds no key, and a combination reads what its parts read. That is why
a scope knows, before anything runs, which keys a component waits for.

Two laws about values hold for the published value of an activation that no
cancellation interrupts:

```text
d.map((x) => x)        ≡  d
d.map(f).map(g)        ≡  d.map((x) => g(f(x)))
((a, b).zip, c).zip    ≡  (a, (b, c).zip).zip        as ((x, y), z) and (x, (y, z))
```

The condition matters: each `map` step is a cancellation checkpoint, so
`d.map((x) => x)` can stop where `d` would have finished. The property tests
in [`laws_test.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/test/laws_test.dart) check these laws with generated values.

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
