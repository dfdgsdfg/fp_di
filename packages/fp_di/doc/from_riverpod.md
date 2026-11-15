This guide is for readers who know [Riverpod](https://riverpod.dev). It maps
the Dart part of Riverpod to `fp_di`: providers, `Ref`, and
`ProviderContainer`. The Flutter part, `ProviderScope`, the consumer widgets,
and `WidgetRef`, is in the
[guide of `fp_di_flutter`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di_flutter/doc/from_riverpod.md).
The Riverpod names are those of `riverpod` 3.5.

## Two models

Riverpod does two jobs. It gives values to code that needs them, and it holds
state that changes. A provider is a global declaration. A
`ProviderContainer` calls the function of a provider when the provider is
first read, and caches the result
([providers](https://riverpod.dev/docs/concepts2/providers)). The container
learns what a provider reads when its function calls `ref.watch`. A
`Notifier` holds state, and the container notifies the readers when that
state changes.

`fp_di` does only the first job. You describe every component as a value:
what it reads, what it publishes, and how its value is created and released.
A `Module` lists the components, and a `Scope` runs a module. `initialize`
creates every component that can start, in the order of its reads, and a
failure undoes all of it. A read creates nothing. A value that changes is an
object that notifies its own listeners, such as a `Stream`.

| Riverpod | `fp_di` |
|---|---|
| `ProviderContainer` | A `Scope` |
| A provider in a global `final` | A `Component` in a `Module`, published under a key |
| `ref.watch(other)` in the function of a provider | A read of the `Dependency`, such as `Dependency1<Other, T>` |
| `ref.onDispose(...)` | `dispose:` of the `Dependency` |
| Created at the first read | Created at `initialize`; `lazy()` defers the work to the first use |
| `isAutoDispose`, `@riverpod` | No release by listener count; a child scope for a shorter life |
| `family` | No family; a child scope for each argument, or a component of a function |
| `FutureProvider` | A `create` that returns a `Future` |
| `AsyncValue` | The future of `initialize`, and the `NodeState` of a node |
| `Notifier`, `AsyncNotifier` | No equivalent; a component whose value notifies |
| `ref.invalidate`, `ref.refresh` | No equivalent; a new child scope |
| `overrides` of a container | `overriddenBy` of a module |
| Automatic retry | No retry; a second `initialize` |

The sections below follow the life of a value: its declaration, its start,
its life, its release, and the tests.

## Declaration

### Providers and components

```dart
// Riverpod: a function for each provider.
final httpProvider = Provider<Http>((ref) {
  final http = Http();
  ref.onDispose(http.close);
  return http;
});

final apiProvider = Provider<Api>((ref) => Api(ref.watch(httpProvider)));

final dbProvider = FutureProvider<Db>((ref) async {
  final db = await Db.open();
  ref.onDispose(db.close);
  return db;
});

// fp_di: a component for each provider.
final http = Component<Http>(
  dependency: Dependency<Http>(
    create: Http.new,
    dispose: (http) => http.close(),
  ),
);

final api = Component<Api>(
  dependency: Dependency1<Http, Api>(create: Api.new),
);

final db = Component<Db>(
  dependency: Dependency<Db>(
    create: Db.open, // may return a Future
    dispose: (db) => db.close(),
  ),
);

final app = await Scope(
  module: Module(components: [api, db, http]), // any order
).initialize();
```

Three differences follow from the declaration:

- **The reads are part of the value.** Riverpod learns that `apiProvider`
  reads `httpProvider` when the function runs. `fp_di` knows it from the type
  arguments of `Dependency1<Http, Api>`, before anything runs. `initialize`
  therefore reports a key that no member publishes, and a key that two members
  publish, before it creates anything.
- **An async value is async only once.** A reader of a `FutureProvider` reads
  an `AsyncValue`, or awaits `ref.watch(dbProvider.future)`. A reader of
  `Db` in `fp_di` reads a `Db`. The runtime starts the reader after `Db`
  is created.
- **The key is the type.** `Component<Api>` publishes `DiKey<Api>()`. Two
  values of one type need names: `DiKey<Duration>(name: 'timeout')`.

### The time of creation

A Riverpod provider is created at its first read. An `fp_di` component is
created at `initialize`, as soon as the keys that it reads have values.
Members that do not read each other start at the same time, and startup takes
as long as the slowest chain of reads.

To defer the work to the first use, keep the value behind a `Lazy` inside the
service that uses it: `dependency.lazy().map(Service.new)`. The service calls
`force()` when it needs the value, and the scope releases the value only if it
was created. The Dependency topic shows the recipe.

## Life

### Release: autoDispose and the scope

A Riverpod provider with auto dispose counts its listeners. When the count
reaches zero, the container waits one frame and then destroys the state
([auto dispose](https://riverpod.dev/docs/concepts2/auto_dispose)). Code
generation turns auto dispose on by default; `keepAlive` keeps the state.

`fp_di` has no count of listeners, because a read creates nothing. A value
lives as long as its scope, unless a value that it reads goes away. For a
shorter life, put the components in a child scope, and dispose the child when
its work ends:

```dart
final checkout = await app.child(module: checkoutModule).initialize();
// ...
await checkout.dispose(); // releases the checkout; the app scope stays
```

The disposal releases each member after the members that read it, while the
values that it read are still alive. In Flutter, `ScopeBuilder` creates and
disposes such a child scope with a widget subtree.

### A value that another value reads

When a provider that another provider reads with `ref.watch` changes,
Riverpod recomputes the dependent: it disposes the previous state and creates
a new one
([auto dispose](https://riverpod.dev/docs/concepts2/auto_dispose)).

In `fp_di` the value of a key changes only when its publisher changes. A node
of the key is withdrawn with `ComponentNode.dispose`, or a nearer scope
publishes the key. Each member that read the old value is released first, and
it activates again when the key has a value again. A change inside a value
notifies nobody, so a value that must follow another value listens to it.

### family

A Riverpod `family` keeps one state for each argument. The argument must have
a consistent `==` and `hashCode`
([family](https://riverpod.dev/docs/concepts2/family)).

`fp_di` keys are fixed when the module is declared, so there is no family.
Choose by the life of each value:

- **One value for each screen or session.** Build the module from the
  argument, and run it in a child scope: `app.child(module: userModule(id))`.
  The child scope releases the values of that argument.
- **Many values at one time.** Publish a service that keeps them, such as a
  repository with a cache by id, or a component whose value is a function:
  `Component<User Function(String)>`.
- **A fixed set of variants.** Use named keys:
  `DiKey<Api>(name: 'public')` and `DiKey<Api>(name: 'private')`.

### State that changes

`fp_di` does not manage state. A `Notifier` has no equivalent. Keep the state
in an object that notifies, and publish that object as a component, which
owns its release:

```dart
// Riverpod
final class Counter extends Notifier<int> {
  @override
  int build() => 0;

  void increment() => state++;
}

final counterProvider = NotifierProvider<Counter, int>(Counter.new);

// fp_di: the object notifies its own listeners.
final class Counter {
  final _changes = StreamController<int>.broadcast();
  int _value = 0;

  int get value => _value;
  Stream<int> get changes => _changes.stream;

  void increment() => _changes.add(++_value);
  Future<void> close() => _changes.close();
}

final counter = Component<Counter>(
  dependency: Dependency<Counter>(
    create: Counter.new,
    dispose: (counter) => counter.close(),
  ),
);
```

You can also keep Riverpod for state and use `fp_di` for services. A
`Notifier` can take a service from the scope.

### Async values and failures

| Riverpod | `fp_di` |
|---|---|
| An `AsyncValue` that is loading | An `initialize` that runs, or a node in `NodePhase.waiting` or `NodePhase.activating` |
| `AsyncError` | The `ActivationException` of `initialize`, or `NodePhase.activationFailed` with `activationException` |
| `AsyncData` | `NodePhase.active`, and `scope.get<T>()` |
| `await ref.read(p.future)` | `await scope.getWhenAvailable<T>()`, or `await node.whenActive` |

A failed `initialize` releases every node that it created, in reverse order,
and the scope returns to `declared`. A second `initialize` is the retry.
Riverpod 3 retries a provider that fails to start, up to 10 times by default
([what's new](https://riverpod.dev/docs/whats_new)). `fp_di` retries nothing.

A member of a child scope can wait for a key of its parent. When that key
arrives later, the member starts outside `initialize`, and a failure goes to
`scope.errors` and to the `NodeState` of the node. The Observation topic shows
how to read both.

### Invalidate, refresh, and listen

- `ref.invalidate` and `ref.refresh` have no equivalent. For a fresh value,
  dispose the child scope that owns it and create another.
- `ref.listen` on a value has no equivalent. A value that changes notifies its
  own listeners. `scope.addListener` notifies each transition of the state of
  a scope, such as a node that becomes active, fails, or is released.

## Test

```dart
// Riverpod
final container = ProviderContainer.test(
  overrides: [apiProvider.overrideWithValue(FakeApi())],
);

// fp_di: edit the module before the scope exists.
final scope = await Scope(
  module: appModule.overriddenBy(
    Module(components: [Component<Api>.value(value: FakeApi())]),
  ),
).initialize();
addTearDown(scope.dispose);
```

`overriddenBy` must replace exactly one member that publishes the key, and it
throws otherwise. A fake for a key that was renamed therefore fails the test.
`withoutRequiring` removes each member that requires a key that the test does
not provide. The Declaration topic explains both edits.

A child scope can also publish a key of its parent. Its members then read the
nearer value, and the parent keeps its own. Riverpod lets a provider be
scoped only when it lists `dependencies`
([scoping](https://riverpod.dev/docs/concepts2/scoping)). In `fp_di` any key
can be published again in a child scope.

## Where the guarantees stop

The runtime runs each `dispose` function in the right order, but it cannot
prove that the function undoes its `create`. Members without a key between
them may run at the same time, so they must not share state outside the keys;
a token key orders them. The
[algebra](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/README.md#the-algebra)
section of the README lists the laws and their conditions.

## Moving an application

1. **Move the services first.** A `Provider` that holds no state becomes a
   component. Each `ref.watch` in its function becomes a read of the
   `Dependency`, and each `ref.onDispose` becomes its `dispose`.
2. **Write the type argument of every component.** `Component<Api>` publishes
   `DiKey<Api>()`. Without it, Dart infers the implementation type, and a
   reader of the interface does not find the value.
3. **Turn each `FutureProvider` into an async `create`.** Its readers then
   read the value, not an `AsyncValue`.
4. **Decide where each family lives.** Use a child scope for each argument, or
   a service that keeps the values.
5. **Keep or move the state.** Keep `Notifier` classes in Riverpod, or turn
   them into objects that notify and publish them as components.
6. **Check in a test.** Run `initialize` on the composed module. It reports
   every key that no member publishes and every key that two members publish,
   before anything is created.
