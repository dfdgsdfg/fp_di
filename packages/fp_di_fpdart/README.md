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
| `ZEnvironment` | an internal immutable environment, stacked with a monoid; a node reads the values of the publishers that its scope resolves |
| `Fiber.interrupt` | `Interrupt`: a canceled activation is never a `Fail` |
| `Ref` | `IORef`: the runtime keeps its state in one cell for each root |
| `ZIO.scoped` | `Scope.use` |
| `ZIO.attempt` | a throw in a create step is a typed `ActivationFailure` |
| a finalizer that throws | a defect: `Die` with a `DisposeFailure` |

`Dependency` is an applicative because Dart has no intersection types to
track `R` in a type. The package states the reads as a set of keys instead.

The package has no layer composition operators, such as `>>>` or `++`. The
scope derives the wiring from the graph of the keys.

The package has no hold, no lazy value, no collection key, no public
cancellation token, no `describe`, and no inspector yet.

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
the cause holds every duplicate key and then every undeclared key, each in
declaration order, joined with `Both`. A key counts as declared when another
component of the scope or any ancestor declares it. The ancestor can be
`declared` still. A failed check changes nothing.

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

## Observation

- `scope.state` is a `ScopeState`: the phase, the `NodeState` of each node
  (`id`, `label`, `key`, `phase`, `missing`, `activationFailure`, `commits`),
  and the states of the children. `scope.revision` counts the observable
  changes of the whole tree. A read changes nothing.
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
  ancestor, and fails when no scope can publish it any more.

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
| `map`, `mapTask`, `mapTaskEither` | the next step; a throw or a `Left` fails the activation |
| `ap` | applies a function dependency; runs this dependency first, then the function |
| `map2`, `map3`, `zip`, `mapN` | the union of the reads; the steps run left to right |
| `Dependency.traverseList`, `Dependency.sequenceList` | a list of values from a list of dependencies |

A dependency is a syntax tree: a free applicative with the nodes pure, require,
optional, ap, and step. Building a dependency runs nothing. An interpreter is
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

## Typeclass instances

The types of the package have the fpdart typeclass instances that fit them.

| Type | Instances |
|---|---|
| `Cause<E>` | `Functor` (`map`), `Foldable` over the typed failures from left to right (`foldLeft`, `foldRight`, `length`, `any`, `all`, and the others); `Cause.eq<E>()` (structural, ignores stack traces); `Cause.thenMonoid<E>()` and `Cause.bothMonoid<E>()` |
| `Exit<E, A>` | an fpdart `Either`, so it has all the instances of `Either` |
| `Dependency<A>` | `Functor` and `Applicative`, and not `Monad` |
| `DiKey` | `DiKey.eq` (`Eq`) and `DiKey.hash` (`Hash`), both built on `==` and `hashCode` |
| `Finalizers` (internal) | `Finalizers.monoid`: the empty stack and `then` |
| `Environment` (internal) | `Environment.monoid`: right-biased stacking |

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

The extension `ComponentsOps` on `Iterable<Component<Object?>>` has three
members:

| Member | Meaning |
|---|---|
| `publishes` | the keys that the components publish |
| `requires` | the required keys that no component of the list publishes |
| `overriddenBy(overrides)` | an `Exit` with a list in which each override replaces the one component that publishes its key, in place |

`overriddenBy` rejects instead of appending. The cause accumulates every
problem in the order of the overrides, joined with `Both`:

- An override whose key no component publishes, or an override that is an
  effect, is an `UnmatchedOverrideFailure`.
- A key that more than one component of the list publishes is a
  `DuplicateKeyFailure`.
- Two overrides with the same key are a `DuplicateKeyFailure`.

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
| `UnavailableKeyFailure` | `get` of a key that no scope of the chain resolves, or a read inside an activation of a key without publisher |
| `ScopePhaseFailure` | an operation in a phase where it is not valid, such as `run` of an initialized scope |
| `DisposedScopeFailure` | an operation of a scope that is disposing or disposed |
| `ReentrantMutationFailure` | a lifecycle operation that started inside a lifecycle operation |
| `InactiveNodeFailure` | `value` of a node that is not active, and `whenActive` of a removed node |
| `ListenerFailure` | a listener threw |
| `UnsettledFailure` | the reconciliation did not settle |

A `DisposeFailure(owner, error)` is not a `DiFailure`. A dispose function that
threw is a defect, so a `Die` holds the `DisposeFailure`.

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
`fp_di`. The package has no hold, lazy value, collection key, or public
cancellation token yet, so four examples of `fp_di` have no port.

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
| [`reactive.dart`](example/reactive.dart) | A nearer publisher and a withdrawn publisher reach only the readers; a listener traces the nodes |
| [`session_scope.dart`](example/session_scope.dart) | A login child scope, and a logout that disposes it |
| [`drain_scope.dart`](example/drain_scope.dart) | A logout flushes the database after the readers of the database release |
| [`environments.dart`](example/environments.dart) | Platform, flavor, test fakes, and a two-stage boot with plain lists |
| [`factory.dart`](example/factory.dart) | A new value for each call, from the nearest database |
| [`cached_factory.dart`](example/cached_factory.dart) | One value for each id, released with the scope |
| [`diagnostics.dart`](example/diagnostics.dart) | Accumulated validation, a cycle that waits, `prettyPrint()`, `get` failures, a waiting child, and `phase` |

## Not ported

These examples of `fp_di` need a feature that this package does not have.

| Example of `fp_di` | Reason |
|---|---|
| `cancellation.dart` | The package has no public cancellation token yet |
| `lazy.dart` | The package has no lazy value |
| `collections.dart` | The package has no set key and no map key |
| `shape_export.dart` | The package has no inspector and no shape export |
