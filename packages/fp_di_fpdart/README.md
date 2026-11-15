# fp_di_fpdart

> **Experimental.** This package is not published, and its API can change
> or go away without notice. The packages meant for publication are `fp_di`
> and `fp_di_flutter`.

A lifecycle-aware dependency-injection runtime built on
[fpdart](https://pub.dev/packages/fpdart). The package does not depend on
`fp_di`. It keeps the names of `fp_di` where they fit, and it follows the
conventions of fpdart.

The scope is small and fixed: one static graph that runs once.

- A `Component` publishes a value under a `DiKey`. A `Scope` takes a plain list
  of components.
- A `Dependency` states the keys that the value reads. The reads are static,
  so the runtime knows the graph before it creates a value. A dependency is an
  applicative, and it is not a monad.
- A `Scope` runs the components once, creates the values in layers, and disposes
  them in reverse order.
- No operation throws. Each failure is a `Left` with a `Cause`.

The design follows [ZIO](https://zio.dev) and the typeclasses of fpdart 1.2.

| ZIO | This package |
|---|---|
| `Cause`, `Exit` | `Cause<E>` with `Empty`, `Fail`, `Die`, `Then`, `Both`; `Exit<E, A>` is `Either<Cause<E>, A>` |
| `ZLayer` | `Component<A>`: a layer with one output key and the inputs that its `Dependency` reads |
| `ZLayer.make` arguments | the list of components that you give to `Scope` |
| `R` and `ZIO.service` reads | `Dependency<A>`: `Functor` and `Applicative`, no `flatMap` |
| `Scope` with finalizers | `Scope`: it holds an immutable stack of dispose functions |
| `ZEnvironment` | an internal immutable environment, stacked with a monoid |
| `ZIO.scoped` | `Scope.use` |
| `ZIO.attempt` | a throw in a create step is a typed `ActivationFailure` |
| a finalizer that throws | a defect: `Die` with a `DisposeFailure` |

`Dependency` is an applicative because Dart has no intersection types to
track `R` in a type. The package states the reads as a set of keys instead.

The package has no layer composition operators, such as `>>>` or `++`. The
scope derives the wiring from the graph of the keys.

The package has no reactive features: no dormant member, no second
activation, no node-level dispose, no listener, no hold, no lazy value, no
collection key, no cancellation token, and no inspector.

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
of its owner: `use` returns a `ScopePhaseFailure` and does not dispose it.

Without the bracket, call `run()` and `dispose()` yourself:

```dart
final scope = Scope(components: appComponents);
final started = await scope.run(); // Exit<DiFailure, Scope>
final value = scope.get<Checkout>(); // Either<DiFailure, Checkout>
final stopped = await scope.dispose(); // Exit<DiFailure, Unit>
```

A scope runs once. A second `run()` is a `Left` with a `ScopePhaseFailure`.
`get` is a `Left` until `run` succeeds and after `dispose` starts.

## Cause and Exit

A `Cause<E>` is a tree. It keeps every failure of an operation and the order
of the failures.

| Case | Meaning |
|---|---|
| `Empty()` | no failure; the identity of `+` and `&` |
| `Fail(error, stackTrace)` | a typed failure |
| `Die(defect, stackTrace)` | a defect, such as a dispose function that threw |
| `Then(first, second)` | one failure after another; made by `+` |
| `Both(left, right)` | two failures at the same time; made by `&` |

A cause has `map` (a `Functor`), `fold`, `failures`, `defects`,
`failureOption`, `isEmpty`, and `prettyPrint()`. `Cause.thenMonoid<E>()` and
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

| Phase | Meaning |
|---|---|
| `declared` | the scope exists; `run` has not started |
| `running` | `run` creates the components |
| `active` | `run` succeeded; `get` works |
| `failed` | `run` failed; nothing is published |
| `disposing`, `disposed` | `dispose` is releasing, or has finished |

`run` checks the components before it creates anything. The check accumulates:
the cause holds every duplicate key and then every undeclared key, each in
declaration order, joined with `Both`. The check for a cycle runs only when
those checks pass. A wrong phase or an inactive parent is a single failure.

Then `run` creates the components in layers. A component is in the layer
after the layers of the components that it reads. The components of one layer
start together, and all of them settle. The next layer starts when every
component of the layer has succeeded.

If components fail, the failures of the layer join with `Both`. Then `run`
disposes every committed value: the layers in reverse order, one after the
other (`Then`), and the members of one layer at the same time (`Both`). The
cause of the run is the failures followed by the dispose defects. `run`
publishes the values only when every component has committed.

`dispose` releases the child scopes first, the most recent child first. Then
it releases the components in reverse layer order, so a dependent is released
before its publishers. Every dispose function runs. The result is `Right`, or
a `Left` with a cause that holds only `Die` values of `DisposeFailure`.
`dispose` is idempotent, and `dispose` during a run waits for the run to
settle.

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

A dependency is a syntax tree: a free applicative with the nodes pure, read,
ap, and step. Building a dependency runs nothing. `requires` and `optional`
come from a fold of the tree. A second interpreter turns the tree into a
`ReaderTaskEither` program that a scope runs.

A step with `dispose` owns its value. Within one component, the scope disposes
the owned values in reverse creation order. A throw in a step is a typed
failure, like `ZIO.attempt`. If a step fails, the scope disposes the owned
values that the component created so far. The cause of the component is
`Fail(ActivationFailure)` followed by one `Die` for each dispose function that
threw.

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
| `overriddenBy(overrides)` | a list in which a component of `overrides` replaces the component with the same key, in place; a new key goes to the end |

A duplicate key in `overrides` stays in the list, so the duplicate check of
the scope reports it.

## Failures

A `DiFailure` is a typed error. It appears in a `Fail` of a `Cause`.

| `DiFailure` | Meaning |
|---|---|
| `DuplicateKeyFailure` | two components of a list publish one key |
| `UndeclaredKeyFailure` | a required key has no publisher in the scope or an ancestor |
| `DependencyCycleFailure` | components read each other in a cycle; `path` lists the keys |
| `ActivationFailure` | a create step threw or returned a `Left`; `error` is the error or the `Left` value |
| `UnavailableKeyFailure` | `get` of a key that the scope and its ancestors do not publish |
| `ScopePhaseFailure` | an operation in a phase where it is not valid |
| `InactiveAncestorFailure` | `run` of a child whose parent is not active |

A `DisposeFailure(owner, error)` is not a `DiFailure`. A dispose function that
threw is a defect, so a `Die` holds the `DisposeFailure`.

## Internals

The package exports no layer type and no composition operator. A `Component`
is the unit of composition, and the graph of the keys is the only wiring
surface. Inside, the pieces are pure values.

- `Plan` is a pure function of the components and of the keys that the
  ancestors publish. It gives the validation cause, or the strata.
- A `Component` is also a function from an environment to a `TaskEither` of
  the made value and its finalizers, like a `ZLayer`. The function is
  internal.
- The internal name of a group of components that start together is a
  stratum. The public documents call the group a layer. A stratum is the
  parallel combination of its components: they read the same environment,
  start together, and all settle.
- The plan is a fold over the strata that adds the outputs of each stratum to
  the environment, like the `>+>` of ZIO. A failed fold releases the
  committed values once, in reverse order.
- A scope holds one immutable state in one fpdart `IORef`. The state is one of
  declared, running, active, failed, disposing, and disposed.

## Child scopes

`scope.child(components:)` creates a child that reads the keys of its parent and
of the ancestors of the parent. The child reads each key from the nearest
scope that publishes it, so a key of the child shadows the key of the parent.
The parent must be active when the child runs. The parent disposes the child
before it disposes its own components.

## Examples

Each file in `example/` runs with `dart run`. Most files port an example of
`fp_di`. The package has no hold, listener, or collection key, so five
examples of `fp_di` have no port.

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
| [`rollback.dart`](example/rollback.dart) | A failed run rolls back in reverse, and the retry is a new scope; a failed program inside `use` disposes the scope |
| [`session_scope.dart`](example/session_scope.dart) | A login child scope, and a logout that disposes it |
| [`drain_scope.dart`](example/drain_scope.dart) | A logout flushes the database after the readers of the database release |
| [`environments.dart`](example/environments.dart) | Platform, flavor, test fakes, and a two-stage boot with plain lists |
| [`factory.dart`](example/factory.dart) | A new value for each call, from the nearest database |
| [`cached_factory.dart`](example/cached_factory.dart) | One value for each id, released with the scope |
| [`diagnostics.dart`](example/diagnostics.dart) | Accumulated validation, a cycle, `prettyPrint()`, `get` failures, and `phase` |

## Not ported

These examples of `fp_di` need a feature that this package does not have.

| Example of `fp_di` | Reason |
|---|---|
| `cancellation.dart` | The package has no cancellation token and no dormant component |
| `lazy.dart` | The package has no lazy value |
| `collections.dart` | The package has no set key and no map key |
| `reactive.dart` | A scope runs once, so a nearer publisher cannot change a reader |
| `shape_export.dart` | The package has no inspector and no shape export |
