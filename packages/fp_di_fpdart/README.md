# fp_di_fpdart

> **Experimental.** This package is not published, and its API can change
> or go away without notice. The packages meant for publication are `fp_di`
> and `fp_di_flutter`.

A lifecycle-aware dependency-injection runtime built on
[fpdart](https://pub.dev/packages/fpdart). The package does not depend on
`fp_di`. It keeps the names of `fp_di` where they fit, and it follows the
conventions of fpdart.

The runtime is reactive and has the lifecycle of `fp_di`: one static graph of
keys, and nodes that activate, release, and activate again when a publisher
changes.

- A `Component` publishes a value under a `DiKey`. A `Scope` takes a plain list
  of components.
- A `Dependency` states the keys that the value reads. The reads are static,
  so the runtime knows the graph before it creates a value. A dependency is an
  applicative, and it is not a monad.
- `Scope.run` creates one node for each component. A node activates when each
  required key resolves, and it waits when a key has no publisher yet. A
  nearer publisher, a withdrawn publisher, or a node that you dispose makes
  the readers release their values and create them again.
- A `Scope` disposes the nodes in reverse order of their reads: a reader
  before the publisher that it reads.
- A scope is a tree. A child scope reads the keys of its ancestors, and it can
  run before its parent.
- No operation throws. Each failure is a `Left` with a `Cause`, or a value of
  `DiFailure` in an `Either`.

The design follows [ZIO](https://zio.dev) and the typeclasses of fpdart 1.2.

| ZIO | This package |
|---|---|
| `Cause`, `Exit` | `Cause<E>` with `Empty`, `Fail`, `Die`, `Interrupt`, `Then`, `Both`; `Exit<E, A>` is `Either<Cause<E>, A>` |
| `ZLayer` | `Component<A>`: a layer with one output key and the inputs that its `Dependency` reads |
| `ZLayer.make` arguments | the list of components that you give to `Scope` |
| `R` and `ZIO.service` reads | `Dependency<A>`: `Functor` and `Applicative`, no `flatMap` |
| `Scope` with finalizers | `Scope`: it holds an immutable stack of dispose functions |
| `ZEnvironment` | no environment value: a node reads the values of the publishers that its scope resolves, at the moment that a step runs |
| `Fiber.interrupt` | `Interrupt`: a canceled activation is never a `Fail` |
| `Ref` | `IORef`: the runtime keeps its state in one cell for each root |
| `ZIO.scoped` | `Scope.use` |
| `ZIO.attempt` | a throw in a create step is a typed `ActivationFailure` |
| a finalizer that throws | a defect: `Die` with a `DisposeFailure` |

`Dependency` is an applicative because Dart has no intersection types to
track `R` in a type. The package states the reads as a set of keys instead.

The package has no layer composition operators, such as `>>>` or `++`. The
scope derives the wiring from the graph of the keys.

## Structure

The runtime has a pure core and an effectful shell.

- The core (`lib/src/core/`) is one immutable `RuntimeState` value for each
  root. Every rule is a pure query or a pure transition on that value. The
  core has no `Future`, no `IORef`, and no zone.
- The shell (`lib/src/runtime/`) holds the `IORef` cells of one root: the
  state, the queue of mutations, the listeners, the reports of `errors`, the
  running activations, the callers of `whenActive`, and the disposals. Each
  program of the shell is a `Task`: it reads the state, runs the steps of a
  component, and applies the transitions of the core.

## A scope

```dart
// `read<T>()` lifts `scope.get<T>()` into a `ReaderTaskEither`; the example
// defines it.
final result = await Scope(components: appComponents)
    .use(
      ReaderTaskEither<Scope, AppError, Receipt>.Do(($) async {
        final checkout = await $(read<Checkout>());
        return $(ReaderTaskEither.fromTaskEither(checkout()));
      }),
    )
    .run(); // Either<Cause<Either<DiFailure, AppError>>, Receipt>
```

`use` runs the scope, runs the program against it, and disposes the scope on
every path. The result is a `Right`, or a `Left` with a `Cause`. Each typed
failure in the cause is an `Either`: a `Left` is a `DiFailure` of the scope,
and a `Right` is an error of the program.

| Case | Cause |
|---|---|
| `run` failed | the cause of the run, then the cause of the disposal |
| the program returned `Left(e)` | `Fail(Right(e))`, then the cause of the disposal |
| the program threw | `Die(error)`, then the cause of the disposal |
| the disposal failed after a success | the cause of the disposal |

`use` never throws. A throw of the program is a `Die`, and the scope is
disposed. A scope that is not in the phase `declared` stays under the control
of its owner: `use` returns a `ScopePhaseFailure` or a `DisposedScopeFailure`
and does not dispose it.

Without the bracket, call `run()` and `dispose()` yourself:

```dart
final scope = Scope(components: appComponents);
final started = await scope.run(); // Exit<DiFailure, Scope>
final value = scope.get<Checkout>(); // Either<DiFailure, Checkout>
final stopped = await scope.dispose(); // Exit<DiFailure, Unit>
```

A scope that succeeded does not run again: a second `run()` is a `Left` with a
`ScopePhaseFailure`. A failed `run` rolls back, and the scope is `declared`
again, so a second `run()` retries. `get` answers in every phase except
`disposing` and `disposed`. It is a `Left` while no publisher resolves.

## Cause and Exit

A `Cause<E>` is a tree. It keeps every failure of an operation and the order
of the failures.

| Case | Meaning |
|---|---|
| `Empty()` | no failure; the identity of `+` and `&` |
| `Fail(error, stackTrace)` | a typed failure |
| `Die(defect, stackTrace)` | a defect, such as a dispose function that threw |
| `Interrupt(stackTrace)` | an operation that a caller canceled, such as an activation that a disposal canceled |
| `Then(first, second)` | one failure after another; made by `+` |
| `Both(left, right)` | two failures at the same time; made by `&` |

A cause has `map` (a `Functor`), `fold`, `failures`, `defects`,
`interruptions`, `isInterrupted`, `onlyDefects`, `failureOption`, `isEmpty`,
and `prettyPrint()`. `Cause.thenMonoid<E>()` and
`Cause.bothMonoid<E>()` are fpdart `Monoid` instances. The `==` of a case
compares the structure and ignores the stack traces. `Then` and `Both` are
associative for `failures` and `defects`, but not for `==`.

`Exit<E, A>` is `Either<Cause<E>, A>`. `run` and `dispose` return an `Exit`.

```dart
final exit = await Scope(components: invalidComponents).run();
exit.match((cause) => print(cause.prettyPrint()), (scope) {});
// Both
//   Fail: DuplicateKeyFailure: DiKey<C> is provided by x, y
//   Fail: UndeclaredKeyFailure: DiKey<A> requires DiKey<B>, which no component publishes
```

## Lifecycle

| Phase of a scope | Meaning |
|---|---|
| `declared` | the scope exists, or a `run` failed and rolled back |
| `initializing` | `run` creates and activates the nodes |
| `initialized` | `run` succeeded |
| `disposeRequested` | the scope or an ancestor accepted `dispose`, which waits for the earlier operations |
| `disposing` | `dispose` releases the nodes; lookups are a `Left` |
| `disposed` | `dispose` finished; the parent does not hold the scope |

| Phase of a node | Meaning |
|---|---|
| `active` | the node has a value and publishes its key |
| `activating` | an activation runs, or a failed activation of a `run` waits for the rollback |
| `deactivating` | the release runs: the key is withdrawn, the readers release first |
| `waiting` | a required key has no publisher; `missing` lists the keys |
| `inactive` | no narrower phase applies |
| `activationFailed` | the last automatic activation failed; `activationFailure` has the cause |
| `disposeFailed` | an own dispose function failed in a release that is not final; the node never activates again |
| `disposed` | the runtime removed the node |

`run` checks the components before it creates anything. The check accumulates:
the cause holds the problems of each declaration, then every duplicate key,
and then every undeclared key, each group in declaration order, joined with
`Both`. The problems of a declaration are the checks of [Key checks](#key-checks).
A key counts as declared when another component of the scope or any ancestor
declares it. The ancestor can be `declared` still. A failed check changes
nothing.

Then `run` creates one node for each component. A node starts when the nodes
of the same scope that publish its keys have settled. Independent nodes start
together, and each node commits on its own: its keys resolve at its commit. A
node with an unmet required key waits and is not a failure.

When a node fails, no further node starts, and the nodes in flight settle. Then
`run` releases the nodes of the scope in reverse order, one after the other,
the scope is `declared` again, and the cause is the failure of the node with
the lowest id, followed by the dispose defects. A failure of a node that the
`run` woke in its last reconciliation fails the `run` in the same way. A
failure of a node of another scope goes to `errors`.

After `run`, the runtime reconciles. An active node whose resolved publisher
changed releases (dependents first), and each node that is not active and whose
required keys resolve activates. A nearer scope that runs later, a withdrawn
publisher, and a node that you dispose change the publishers. The
reconciliation repeats while an active node is stale, and gives an
`UnsettledFailure` when optional reads feed back and never settle.

`ComponentNode.dispose()` removes one node. The nodes that read it release
first. An activation in flight that reads one of those values is canceled: it
rolls back, waits for the withdrawal to end, and activates again against another
publisher if one resolves.

`dispose` is a lifecycle operation. The call accepts the disposal at once and
cancels the activations in flight in the subtree: they end with an `Interrupt`.
The mutation then releases the nodes along their reads. Nodes that do not
read each other release at the same time, and the dispose failures follow
descending node id. Every dispose function runs. The result is `Right`, or a
`Left` with a cause that holds only `Die` values of `DisposeFailure`. A second
call joins the first, a call of a descendant joins the disposal of an ancestor,
and a call after the end is `Right`. `dispose` does not reconcile.

`run`, `dispose`, and `ComponentNode.dispose` of one root run one after the
other, in the order of the calls. A call from inside one of them, such as a
dispose function that calls `run`, is a `ReentrantMutationFailure`. A callback
that outlives the operation can start one.

## Holds

A consumer from outside the runtime, such as a page of a widget tree, can read
a scope after a caller requested its disposal. A hold keeps the disposal back
until the consumer leaves.

```dart
switch (scope.disposeHold(debugLabel: 'upload')) {
  case Right(value: final hold):
    try {
      // Work that reads the scope.
    } finally {
      hold.close();
    }
  case Left(value: final failure):
    // The scope is disposing. Skip the work.
}
```

- `disposeHold` is a `Left` with a `DisposedScopeFailure` when the scope or an
  ancestor accepted a disposal. The call is valid inside a lifecycle
  operation.
- `DisposeHold.close()` never throws. A second call does nothing, and a call
  after the disposal started changes nothing. The last `close` of a subtree
  queues the waiting disposal. A `close` inside a lifecycle operation, such as
  a listener, queues the disposal after that operation.
- `openHolds` lists the open holds of the scope and of its descendants as
  `HoldState` values: `debugLabel`, `scopePath` (such as `child scope 1.2`),
  `elapsed`, and `debugStackTrace`, which the runtime records only inside an
  `assert`.

A `dispose` call that meets an open hold in its subtree accepts the disposal at
once, and the scope is `disposeRequested`. The disposal then waits outside the
queue of the lifecycle operations. In that time the lookups answer, no
node starts an activation, `Lazy.force` is a `DisposedLazyFailure`, and `run`
is a `DisposedScopeFailure`. A hold does not stop a node that must release
because an ancestor withdrew a publisher. `describe` ends the heading of a
waiting scope with `(disposal waits for 2 holds: page, hold)`.

A call of a descendant joins the disposal of an ancestor, and the holds of the
whole subtree count. Do not wait for the result of `dispose` before you close
the holds of the scope: the disposal waits for them.

`dispose(ignoreHolds: true)` queues the disposal at once, also when an earlier
call waits. The earlier call completes with the result of this disposal. The
root reports an `IgnoredHoldsFailure(holds)` to `errors` after the transition
that starts the disposal, when the call ignored an open hold. A caller that
bounds the wait uses `timeout`, as `example/drain_scope.dart` shows.

## Slow operations

`Scope(onSlowMutation: listener, slowMutationThreshold: duration)` reports an
operation that runs longer than the threshold. The default threshold is two
seconds. The listener gets a `SlowMutation` at the threshold, and again after
each further threshold, until the operation ends. Without a listener, the
runtime starts no timer.

| Field | Meaning |
|---|---|
| `operation` | `run`, `Scope.dispose`, `ComponentNode.dispose`, or `Scope.dispose (waiting for holds)` |
| `elapsed` | how long the operation has run |
| `running` | the labels of the activations in flight |
| `ignoringCancellation` | the labels of the activations whose token is canceled and whose step did not return |
| `disposing` | the owners whose dispose functions run, such as `<label> activation rollback` |
| `queued` | the operations that wait behind this one |
| `holds` | the open holds of a disposal that waits for holds |

The timer runs outside the operation, so the listener can request an
operation, which queues. A listener that throws leaves a `ListenerFailure` in
`errors`.

## Observation

- `scope.state` is a `ScopeState`: the phase, the `NodeState` of each node
  (`id`, `label`, `key`, `phase`, `missing`, `activationFailure`, `commits`),
  and the states of the children. `scope.revision` counts the observable
  changes of the whole tree. A read changes nothing.
- The runtime keeps the object of what a change did not touch. Two reads with
  no change between them give the same object, an unchanged `NodeState` stays
  the same object, and an unchanged scope keeps its `ScopeState`. So
  `identical` tells that nothing in a scope and its descendants changed.
  `ScopeState.changedSince(earlier)` lists the pairs of the earlier and the
  later `NodeState` of each node that differs: a created node has no earlier
  state, and a node that left has no later state.
- `scope.states` is a `Stream<ScopeState>`. A subscription listens to the scope
  and emits the state after each round of listener calls that changed the
  scope or a descendant. It does not emit the state at the time of the
  subscription. It emits the state with the phase `disposed`, and then closes.
- `scope.describe()` is an `Either` with a text for people. It lists each
  node with its state and its missing keys, and `(not initialized)` in the
  heading of a scope that did not run. The format can change.
- A `get` that fails with an `UnavailableKeyFailure` says why. The message
  names the node that waits or failed. `failedNodeStates` lists the nodes with
  a failed automatic activation behind the key, found by a depth-first search
  through the missing keys.
- `addListener` calls a function after each change, with the new state
  already in place. Listeners run in rounds, one round after the other. A
  listener that throws leaves, and `errors` reports a `ListenerFailure` after
  the round. A scope hears its own disposal, and then its listeners leave.
- `errors` is a broadcast `Stream<Cause<DiFailure>>` for the failures that no
  caller receives: a failed automatic activation, the dispose failures of a
  reconciliation, an `UnsettledFailure`, and a `ListenerFailure`. The root
  closes the stream.
- `ComponentNode.whenActive` is a `TaskEither` that completes at the next
  commit. `Scope.getWhenAvailable` waits for a key of the scope or an
  ancestor, and fails when an activation failed behind the key or when no
  scope can publish it any more.

## Dependency

A `Dependency` is an applicative description. It is deliberately not a
monad. A `flatMap` would let a step choose a read from a value, and then the
runtime could not know the graph before it creates a value.

```dart
// `validation.dart` shows this host policy next to its alternative.
final config = Dependency.require<RawConfig>()
    .mapTaskEither((raw) => TaskEither.fromEither(validate(raw)));

final checkout = (
  Dependency.require<Config>(),
  Dependency.require<Cart>(),
  Dependency.option<Analytics>(), // None when no scope publishes the key
).zip.mapN(Checkout.new);
```

| Member | Meaning |
|---|---|
| `Dependency(create:, dispose:)` | a value from a function; `dispose` makes the step own the value |
| `Dependency.of(value)`, `pure` | a value that exists already |
| `Dependency.task`, `Dependency.taskEither` | a value from a `Task` or a `TaskEither`; a `Left` fails the activation |
| `Dependency.require<T>()`, `Dependency.option<T>()` | a read of a key, required or optional |
| `Dependency.require2` to `Dependency.require8` | a record of the values of two to eight keys (`key1` to `key8`); the same reads as a `zip` of `require` |
| `Dependency.requireSet`, `optionSet`, `requireMap`, `optionMap` | a read of a collection key; see [Collections](#collections) |
| `Dependency.cancellation()` | the cancellation token of the activation; see [Cancellation](#cancellation) |
| `lazy()` | a `Lazy` that runs the steps on its first use; see [Lazy values](#lazy-values) |
| `map`, `mapTask`, `mapTaskEither` | the next step; a throw or a `Left` fails the activation |
| `ap` | applies a function dependency; runs this dependency first, then the function |
| `map2`, `map3`, `zip`, `mapN` | the union of the reads; the steps run left to right |
| `Dependency.traverseList`, `Dependency.sequenceList` | a list of values from a list of dependencies |

A dependency is a syntax tree: a free applicative with the nodes pure, require,
optional, set, map, cancellation, lazy, ap, and step. Building a dependency runs nothing. An interpreter is
an algebra: one method for each node, and a node only dispatches to the method
(a catamorphism). The result type of a method is an fpdart `HKT<G, A>`, so the
result can depend on the value type `A`. Two algebras exist. The reads algebra
gives `requires` and `optional`. The runner algebra gives a
`ReaderTaskEither` program that a scope runs. A new interpreter needs a new
algebra and no change to the nodes.

A step with `dispose` owns its value. Within one component, the scope disposes
the owned values in reverse creation order. A throw in a step is a typed
failure, like `ZIO.attempt`. If a step fails, the scope disposes the owned
values that the component created so far. The cause of the component is
`Fail(ActivationFailure)` followed by one `Die` for each dispose function that
threw.

## Collections

A collection key names many contributions. The key decides the membership, not
the type: two collections of one interface stay apart, and a component that
implements the interface is not an element unless it contributes.

- `DiSetKey<T>(name:)` collects anonymous contributions. A contribution is
  `Component<T>.into(key:, dependency:)`. It publishes no plain key and is not
  an effect, so nothing reads it by a key, and an override cannot replace it.
  Each declaration is one contribution. Equal values give one element.
- `DiMapKey<T>(name:)` collects entries. An entry is a component that
  publishes `map.entryKey(id)`. The entry key is a `DiKey`, so another
  component can read one entry with `Dependency.require`, and an override can
  replace it.

A reader sees the contributions of its scope and of its ancestors, the
ancestors first and each scope in the order of the declarations. Its own
declaration does not count. A parent never sees a contribution of a child. A
map id that two scopes declare appears once, at the position of its first
declaration. The nearest entry that is active gives the value, and a dormant
nearer entry leaves the entry of the ancestor selected.

| Read | Result | Waits |
|---|---|---|
| `Dependency.requireSet` | `Set<T>` | for every contribution to resolve |
| `Dependency.optionSet` | `Set<T>` of the contributions that resolve | never |
| `Dependency.requireMap` | `Map<String, T>` by entry id | for every declared id to resolve |
| `Dependency.optionMap` | the entries that resolve | never |

An empty collection is an empty value, and a collection read is never an
`UndeclaredKeyFailure`. The members of a collection come from the
declarations, so a contribution of a scope that did not run counts: a strict
reader waits, and `missing` names the collection key. The reader releases and
activates again when a contributor joins or leaves, or when the publisher of a
contribution changes. A contributor that you dispose leaves the membership. Two
entries of one id in one scope are a `DuplicateKeyFailure` at `run`. A reader
starts after the contributors of its own scope settle, and it releases before
them. `ComponentsOps.contributes` counts the contributions of a group, and
`publishes` holds the entry keys.

## Lazy values

`dependency.lazy()` gives a `Dependency<Lazy<A>>` with the same reads. When the
owner activates, it reads each key and keeps the values, so the keys stay
tracked. The steps of the source run on the first `force()`, in a region of
their own, against those values.

`Lazy.force()` is a lazy `TaskEither<Cause<DiFailure>, A>`. The left is a
`Cause`, so the failure of a step and the dispose failures of its rollback stay
together.

- Concurrent first forces share one creation, and later forces give the same
  value. `isCreated` tells whether the value exists.
- A failed creation is not cached, and the owner stays active. The region
  cancels its token before it releases its steps.
- The owner owns the holder at the position of the `lazy` step: it releases the
  value before the steps to its left.
- A `force` after the disposal of the owner was requested, and after the
  release, is a `Fail(DisposedLazyFailure)`. A creation that settles after the
  release began gives that failure to its caller, and releases its value once.
- A key that the lazy step reads changes: the owner releases the old holder and
  activates again with a new holder. The old holder fails with a
  `DisposedLazyFailure`.

## Cancellation

A `CancellationToken` tells whether an activation is canceled: `isCanceled`, and
`whenCanceled`, a lazy `Task<Unit>` that completes once when the token cancels
and never fails. `Dependency.cancellation()` reads the token of the activation.

The runtime cancels the token:

| Trigger | Moment |
|---|---|
| `Scope.dispose` of the scope or an ancestor | at the call, for each activation in flight in the subtree |
| `ComponentNode.dispose` | at the call, for the activation in flight of the node |
| a withdrawal that the activation reads | at the call of the node dispose, for each activation in flight that reads a node of the reach, and at a later read of such a node |
| an active activation starts to release | before its first dispose function: a rebuild, a withdrawal, and a disposal |
| a step of the activation fails | before the first dispose function of the rollback |

The runtime checks the token before each step and before the commit, so a
canceled activation never commits, and the completed steps release in reverse
order. The cause of a canceled activation holds an `Interrupt`, and it is never
a `Fail`. A step that ignores the token only delays its own settlement.

`CancellationToken.none` is never canceled. A `CancellationController` has a
`token` and a `cancel()`, for code that calls a cancelable function outside the
runtime, such as a test. A `Lazy` creation has a token of its own, a child of
the token of its owner.

## Typeclass instances

The types of the package have the fpdart typeclass instances that fit them.

| Type | Instances |
|---|---|
| `Cause<E>` | `Functor` (`map`), `Foldable` over the typed failures from left to right (`foldLeft`, `foldRight`, `length`, `any`, `all`, and the others); `Cause.eq<E>()` (structural, ignores stack traces); `Cause.thenMonoid<E>()` and `Cause.bothMonoid<E>()` |
| `Exit<E, A>` | an fpdart `Either`, so it has all the instances of `Either` |
| `Dependency<A>` | `Functor` and `Applicative`, and not `Monad` |
| `DiKey` | `DiKey.eq` (`Eq`) and `DiKey.hash` (`Hash`), both built on `==` and `hashCode` |
| `Finalizers` (internal) | `Finalizers.monoid`: the empty stack and `then` |

The effects of the interpreters are fpdart values. A step is a
`ReaderTaskEither` that uses `TaskEither.tryCatch`, `flatMap`, and
`chainEither`. The registration of a finalizer is an `IO` that the step
composes. A program of the shell is a `Task` that runs when a lifecycle call
starts it: `Scope.run`, `Scope.dispose`, `ComponentNode.dispose`, and the
program that `Scope.use` receives. The shell uses `async` loops and `Future`
values for the pumps and the queue of mutations, and its mutable cells are
`IORef` values, `Completer` values, and one stream controller.

## Components

A group of components is a plain `List<Component<Object?>>`. Join groups with
the list operations:

```dart
final app = [...coreComponents, ...featureComponents];
```

The extension `ComponentsOps` on `Iterable<Component<Object?>>` has these
members:

| Member | Meaning |
|---|---|
| `publishes` | the keys that the components publish, with the entry keys of maps, and without effects and contributions |
| `contributes` | the number of contributions to each set key |
| `requires` | the required keys that no other component of the list publishes; a component does not satisfy its own requirement |
| `reads` | every key and collection key that a component reads, without the keys that another component publishes; a collection key stays |
| `overriddenBy(overrides)` | an `Exit` with a list in which each override replaces the one component that publishes its key, in place |
| `replacing(key:, component:)` | an `Exit` with a list in which `component` replaces the one component that publishes `key`, in place |
| `requiring(keys:, ancestorKeys:)` | the components that require a key of `keys`, directly or through another component of the result |
| `withoutRequiring(keys:, ancestorKeys:)` | the components that `requiring` does not return |

`where` and the list operations select and join components. `without(key)` has
no member: `where` removes a component by its key.

`overriddenBy` rejects instead of appending. The cause accumulates every
problem in the order of the overrides, joined with `Both`:

- An override whose key no component publishes, or an override that is an
  effect or a contribution, is an `UnmatchedOverrideFailure`.
- A key that more than one component of the list publishes is a
  `DuplicateKeyFailure`.
- Two overrides with the same key are a `DuplicateKeyFailure`.

`requiring` names the components that a variant cannot start, because they
require a key that the variant does not publish. A component is in the result
when its `requires` holds a key of `keys`, or the key that another component of
the result publishes. The reads of an effect count. An optional read and a
collection read do not put a component in the result. A component that
publishes a key of `keys` is not in the result for that reason, and each
component that requires that key is. `ancestorKeys` holds the keys that an
ancestor scope also publishes: a component of the result that publishes such a
key does not take its readers with it. `ancestorKeys` does not take a key out
of `keys`. The operations never fail, and their time is near-linear in the
components and their required keys.

```dart
final removed = all.requiring(keys: absent);
final session = sessionComponents.withoutRequiring(
  keys: {...absent, ...removed.publishes},
  ancestorKeys: all.withoutRequiring(keys: absent).publishes,
);
```

`replacing` is an `Exit`. It is an `InvalidComponentFailure` when the
component does not publish the key, an `UnmatchedOverrideFailure` when no
component publishes the key, and a `DuplicateKeyFailure` when more than one
does.

## Key checks

The constructors of a component never throw. A declaration that does not fit is
a value that `run` reports with the other checks, in the cause of the `Left`.

| Failure | Meaning |
|---|---|
| `UnnamedKeyFailure(key, owner)` | a published key or a read key has no name, and its type is a core value type: `bool`, `int`, `double`, `num`, `String`, `BigInt`, `DateTime`, `Duration`, `Uri`, `Symbol`, `Object`, or the nullable form of one |
| `UnreachableKeyFailure(key)` | a published key has the type `Future<X>` or `FutureOr<X>`; no read can produce such a type |
| `InvalidComponentFailure(owner, reason)` | the type argument is `void`, `dynamic`, or `Null`, or the type of the key is not the type argument |

An extension type over `int` erases to `int` at run time, so a key of such a
type needs a name: `DiKey<int>(name: 'port')`, or an extension type with a
key of its own. An effect, a contribution, and a collection key are not
checked, because they have no plain key or they always have a name.

fp_di raises the check of the `Future` key when a component publishes, and it
raises the other checks at construction. This package raises all of them in
`run`, before any node exists. A list of components that Dart types as
`List<Component<Object?>>` makes Dart infer `Object?` for a component without a
type argument. Then the type of the key is not the type argument, and `run`
fails with an `InvalidComponentFailure`. State the type argument of each
component.

## Effects

`Component.effect(dependency:)` is a component that publishes no key. It runs
for its effect. It reads the keys of its dependency, so it starts after the
components that publish them. It owns its values like any component, and the
scope releases it before the components that it reads. Nobody can read its
value, and an override cannot replace it. Two effects of one type can exist
in one list. `isEffect` tells an effect from a component with a key.
`publishes` leaves out the effects, and `requires` counts their reads.

## Failures

A `DiFailure` is a typed error. It appears in a `Fail` of a `Cause`.

| `DiFailure` | Meaning |
|---|---|
| `DuplicateKeyFailure` | two components of a list publish one key |
| `UndeclaredKeyFailure` | a required key has no publisher in the scope or an ancestor |
| `DependencyCycleFailure` | a read inside an activation would close a cycle of committed reads; `path` lists the keys. Components that require each other wait, and the check of a scope raises no cycle |
| `ActivationFailure` | a create step threw or returned a `Left`; `error` is the error or the `Left` value |
| `UnmatchedOverrideFailure` | an override has no single component to replace |
| `UnavailableKeyFailure` | `get` of a key that no scope of the chain resolves, or a read inside an activation of a key without publisher; `failedNodeStates` lists the failed nodes behind the key |
| `ScopePhaseFailure` | an operation in a phase where it is not valid, such as `run` of an initialized scope |
| `DisposedLazyFailure` | `Lazy.force` after the disposal of the owner was requested or after the release |
| `DisposedScopeFailure` | an operation of a scope that is disposing or disposed |
| `ReentrantMutationFailure` | a lifecycle operation that started inside a lifecycle operation |
| `InactiveNodeFailure` | `value` of a node that is not active, and `whenActive` of a removed node |
| `ListenerFailure` | a listener threw |
| `UnsettledFailure` | the reconciliation did not settle |
| `IgnoredHoldsFailure` | a disposal ignored open holds; the root reports it to `errors` |
| `UnnamedKeyFailure` | a key without a name has a core value type |
| `UnreachableKeyFailure` | a published key has a `Future` or `FutureOr` type |
| `InvalidComponentFailure` | a component does not fit its type argument |

A `DisposeFailure(owner, error)` is not a `DiFailure`. A dispose function that
threw is a defect, so a `Die` holds the `DisposeFailure`.

## Shape graph

`package:fp_di_fpdart/tooling.dart` reads components without a runtime, for a
script or a test. An application does not import it.

```dart
import 'package:fp_di_fpdart/tooling.dart';

final graph = ShapeGraph.of(appComponents(), label: 'app');
print(graph.toJson());
print(graph.toMermaid());
```

`ShapeGraph` lists each component with its reads, each wait of one component
for another (`edges`, with the kind of the read), the `depths`, the `cycles`,
one `longestChain`, the `undeclared` keys, and the `duplicates`. Nothing is
created and no `create` runs. `toJson` and `toMermaid` have the schema and the
text of `ShapeGraph` of `fp_di`: `format` is `fp_di.shape` and `version` is 1.
`toMermaid(collapsed: true)` draws one node for each origin.

A list of components has no label and no origin, so `ShapeGraph.of` takes them
as named arguments: `label` for the scope, `origins` with one origin for each
component, and `ancestors`, a list of records `(label:, components:, origins:)`
for the ancestor scopes, root first. The ancestors decide which required keys
are `undeclared`, and the chart draws the reads that cross a scope. The
arguments are only for the tools: a `Scope` ignores them. A `Scope` takes the
same label as `debugLabel`. The names of the JSON fields, such as `label` and
`ancestors`, are the names of the schema of `fp_di`, where a module has them.

The time of the build and of each export is linear in the number of components
and reads. The sets `publishes`, `requires`, `reads`, and `contributes` of the
graph are the sets of `ComponentsOps`.

[`example/shape_export.dart`](example/shape_export.dart) writes the JSON and the
chart of each variant of an application.

## DevTools inspector

A debug build serves an inspector to Dart DevTools. The inspector is the
inspector of `fp_di` over the reactive runtime of this package. It has the same
protocol: the service extensions `ext.fp_di.roots`, `ext.fp_di.state`,
`ext.fp_di.node`, `ext.fp_di.shape`, and `ext.fp_di.listen`, the events
`fp_di:transition`, `fp_di:error`, and `fp_di:slowMutation`, the format
`fp_di.devtools`, and the version 1. The tests compare the answers and the events
of a scenario with the answers that `fp_di` recorded for the extension app
`packages/fp_di_devtools`. The comparison is equal but for the fields in the
table below. A run of the app against this package was not made.

- The inspector exists only when Dart assertions are enabled. The factory of
  `Scope` registers it inside an `assert`, so a release build carries no
  inspector work. This is the rule of `fp_di`. A root without
  `onSlowMutation` starts no timer for the inspector.
- The inspector changes no state. A query reads the same snapshots as
  `Scope.state`. `listen` with `enabled: true` adds one listener for each root,
  and the first transition of an event-loop turn schedules one
  `fp_di:transition` event for the turn. The values of the nodes are in an
  answer or an event only when the caller asks for them with `values: true`.
  Every text is cut at 4 KiB, and an event lists 500 changed nodes at most.
- A root has the label of its `debugLabel`, or `root <id>`. The `module` of a
  scope in `state` is its `debugLabel`, and the `origin` of each node is the
  label of its scope.

Differences in the content of the protocol:

| Field | Value here |
|---|---|
| `failure.type` and `failure.message` of a node | the type and the text of the error that a step threw, or of the `Left` value that a step returned |
| `type` of `fp_di:error` | the type of the first failure of the reported cause, such as `ActivationFailure`, where `fp_di` has `ActivationException` |
| `message` of `fp_di:error` | the `message` of that failure |
| `operation` of `fp_di:slowMutation` | `run` where `fp_di` has `initialize` |
| `stackTrace` | the stack trace of the first `Fail` or `Die` in the cause |

The extension app shows these values as text. The test file
`devtools_inspector_test.dart` states the differences: the other answers and
events of the scenario are equal to the recorded ones, but for the `revision`.

### Two copies of the inspector in one isolate

A service extension name can be registered one time in an isolate, and a name
cannot be unregistered. An app that loads `fp_di` and this package has two
inspectors under the same names. The copy that creates a root first owns the
names. The other copy detects that the name is taken, skips it, and goes on: no
root fails. Then only the first owner answers the queries, and the roots of the
other copy are not visible in DevTools. `fp_di` and this package give one
inspector to each isolate, so an app that wants to inspect its scopes uses one
of the two runtimes.

### Use the extension app

The package ships no built extension, and this package did not run DevTools
with the extension app. DevTools loads the extension of a package that the
connected app depends on from the folder `extension/devtools/` of that package.
The `name` in the `config.yaml` of the folder should be the name of the package
that holds the folder (`devtools_shared` states this rule). The `config.yaml`
of `fp_di_devtools` has the name `fp_di`, so the copy needs a new name. The
`validate` command checks the characters of the name only.

For a local build, from `packages/fp_di_devtools`:

```sh
dart run devtools_extensions build_and_copy --source=. --dest=../fp_di_fpdart/extension/devtools
cp config.yaml ../fp_di_fpdart/extension/devtools/config.yaml
```

Then set `name: fp_di_fpdart` in the copied `config.yaml`, and check the folder
from the workspace root:

```sh
dart run devtools_extensions validate --package=packages/fp_di_fpdart
```

Run the app with assertions (a debug build) and open DevTools. The folder
`packages/fp_di_fpdart/extension/` is local build output. Do not commit it.

## Internals

The package exports no layer type and no composition operator. A `Component`
is the unit of composition, and the graph of the keys is the only wiring
surface. Inside, the pieces are pure values.

- `RuntimeState` holds `ScopeRecord` and `NodeRecord` values. The queries
  (`resolve`, `target`, `satisfied`, `nodePhase`, `scopePhase`, `dormantCandidates`,
  `dependentsOf`, `withdrawalReach`, `preCheck`) and the transitions
  (`createNodes`, `beginActivation`, `commit`, `beginRelease`, `endRelease`,
  `requestScopeDisposal`, and the others) are functions of that value. A
  transition raises `revision` exactly when an observer can see the change.
- A node resolves a key to the nearest scope, from its own scope to the root,
  that has a committed publisher that is not releasing. A node never resolves
  its own publication. The runtime compares the identity of each commit, so a
  node that commits again is a new publisher for its readers.
- The program of a component runs as a `ReaderTaskEither` over a context that
  reads the state when a step runs. The context records each read, checks the
  cancellation token before each step, and holds the finalizers.
- A `Component` has no layer. The runtime has no stratum: the order of
  activation comes from the reads of the nodes of one scope.
- The maps of `RuntimeState` are persistent hash tries (`PMap`), so a
  transition copies a path and shares the rest. The state keeps an index of the
  readers of each node and each key, so a query touches only the affected nodes.
  The snapshots of the observers update only the changed nodes. A scope of 4000
  components runs and disposes in less than one second.
- The runtime has debug self-checks and deliberate defects for the tests
  (`src/faults.dart`). The runtime reads the switches only inside `assert`, so a
  release build carries no cost and no switch. `test/lifecycle_fuzz_test.dart`
  runs random histories against these checks, and
  `test/lifecycle_fuzz_defect_test.dart` turns on each defect and checks that
  the matching check reports it.

## Child scopes

`scope.child(components:)` gives an `Either`: a `Left` when the scope is
disposing or disposed. The child reads the keys of its parent and of the
ancestors of the parent. The child reads each key from the nearest scope that
publishes it, so a key of the child shadows the key of the parent. A child can
run before its parent, and its nodes wait for the keys that the parent
declares. The parent disposes the child before it releases the nodes that the
child reads.

## Examples

Each file in `example/` runs with `dart run`. Most files port an example of
`fp_di`.

```sh
dart run packages/fp_di_fpdart/example/checkout.dart
```

| File | What it shows |
|---|---|
| [`checkout.dart`](example/checkout.dart) | A checkout workflow: a `ReaderTaskEither` over a narrow environment that a `Dependency` builds, and business failures as `Left` data |
| [`state.dart`](example/state.dart) | A cart as a pure `State` machine, run by a store that a component owns; a run on a closed store is a `Left` |
| [`validation.dart`](example/validation.dart) | A validator that keeps every problem, and two host policies: `mapTaskEither` fails the activation, and `map` publishes the `Either` |
| [`basic.dart`](example/basic.dart) | Two components in one scope, and `use` |
| [`chaining.dart`](example/chaining.dart) | Several owned steps in one component, and a `zip` with an optional read |
| [`parallel.dart`](example/parallel.dart) | Independent components start and release at the same time |
| [`token_key.dart`](example/token_key.dart) | A token key orders one component after the effect of another |
| [`rollback.dart`](example/rollback.dart) | A failed run rolls back in reverse, and the retry is a second `run`; a failed program inside `use` disposes the scope |
| [`reactive.dart`](example/reactive.dart) | A nearer publisher and a withdrawn publisher reach only the readers; a listener traces the nodes with `changedSince` |
| [`session_scope.dart`](example/session_scope.dart) | A login child scope, and a logout that disposes it |
| [`drain_scope.dart`](example/drain_scope.dart) | A logout flushes the database after the readers of the database release; an upload holds the scope, and a time limit ends the wait with `ignoreHolds` |
| [`environments.dart`](example/environments.dart) | Platform, flavor, test fakes, and a two-stage boot with plain lists |
| [`factory.dart`](example/factory.dart) | A new value for each call, from the nearest database |
| [`cached_factory.dart`](example/cached_factory.dart) | One value for each id, released with the scope |
| [`cancellation.dart`](example/cancellation.dart) | A logout during a login, a withdrawal during a read, a failed step, and a token outside the runtime |
| [`lazy.dart`](example/lazy.dart) | A report that is built on the first `force()`, shared by concurrent calls, and released with its owner |
| [`collections.dart`](example/collections.dart) | Set and map keys: features contribute, one reader starts them, a fake replaces one entry |
| [`diagnostics.dart`](example/diagnostics.dart) | Accumulated validation, a cycle that waits, `prettyPrint()`, `get` failures, a waiting child, and `phase` |
| [`shape_export.dart`](example/shape_export.dart) | A tool script that writes the shape of each variant as JSON and as a Mermaid chart, with the output of `fp_di` |

## Known differences

The package does not reproduce these behaviors of `fp_di`.

- A slow report names the operation `run`, where `fp_di` names it
  `initialize`.
- The rollback of the creation of a `Lazy` value does not appear in
  `SlowMutation.disposing`.
- A slow listener that throws leaves a `ListenerFailure` in `errors`. `fp_di`
  leaves the error to the zone of the timer.
- The inspector gives the failure of a node by the error that a step threw,
  and the type of a reported cause by the first failure (see the table in
  [DevTools inspector](#devtools-inspector)).
- `ShapeGraph` takes a list of components with the named arguments `label`,
  `origins`, and `ancestors`, where `fp_di` takes a `Module`. A component
  without a debug label and without a key has the label `effect<T>#id` in a
  scope and `effect<T>` in a shape, where `fp_di` says `Component<T>`.
- A `Scope` has an optional `debugLabel`, which `fp_di` has as the label of
  its module.
- A `Component` constructor never throws. The checks of `fp_di` that throw at
  construction are failures of `run` here.
