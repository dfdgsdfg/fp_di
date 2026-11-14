# fp_di_fpdart

> **Experimental.** This package is not published, and its API can change
> or go away without notice. The packages meant for publication are `fp_di`
> and `fp_di_flutter`.

The [fp_di](../fp_di) scope lifecycle, lookups, and `Dependency` steps as
[fpdart](https://pub.dev/packages/fpdart) types.

fp_di owns composition and lifecycle: which values exist, what they read, when
they are created, and when they are disposed. fpdart describes the programs
that use them. This package converts one to the other at the boundary. It
adds no lifecycle behavior.

## A scope

```dart
final result = await Scope(module: appModule)
    .use(
      ReaderTaskEither<Scope, AppError, Receipt>.Do(($) async {
        final scope = await $(ReaderTaskEither.ask());
        return $(ReaderTaskEither.fromTaskEither(scope.get<Checkout>()()));
      }),
    )
    .run(); // Either<ScopeFailure<AppError>, Receipt>
```

`use` initializes the scope, runs the program against it, and disposes the
scope on every path. The result is a `Right` or one `ScopeFailure`:

| `ScopeFailure` | Meaning |
|---|---|
| `InitializeFailed(failure)` | `initialize` failed; the program did not run |
| `UseFailed(error)` | the program returned a `Left` |
| `DisposeFailed(failure, useError)` | `dispose` failed; `useError` keeps the program's own `Left` |

Without the bracket, `initializeTask()` and `disposeTask()` are lazy
`TaskEither` values. Each run calls fp_di once: a second `initializeTask` run
on the same scope is a `Left`, and a `Right` scope stays open until its owner
disposes it.

## Lookups

| Form | Result |
|---|---|
| `scope.getEither<T>()` | `Either<DiFailure, T>` |
| `scope.getOption<T>()` | `Option<T>`; `None` for an absent key and for a bound `null` |
| `node.whenActiveTask()` | `TaskEither<DiFailure, A>`: the value once the node is active, a `Left` if it is disposed first |

A `Right` from `initializeTask` does not mean that every member is active: a
member can wait for a key of an ancestor.

## Dependency steps

A step that runs a `TaskEither` states in its name what a `Left` means:

```dart
// A Left means the component cannot exist: the setup fails and rolls back.
final config = Dependency.require<RawConfig>()
    .mapTaskEither((raw) => TaskEither.fromEither(validate(raw)));

// A Left is ordinary data: it is published like a Right.
final quote = Dependency.require<Api>()
    .mapTaskEitherAsData((api) => api.fetchQuote());
```

`mapTaskEither` throws a `DependencyLeft` with the `Left` inside the step, so
the completed steps are disposed in reverse order and nothing is published.
`mapTask` runs a `Task`, and `Dependency.maybe<T>().toOption()` reads an
optional key as an `Option`.

There is no `flatMap`. fp_di reads the keys of every `Dependency` before it
runs, to check and schedule the graph, so a step cannot choose its reads from a
value.

## Failures

`DiFailure` keeps the error that fp_di threw and its stack trace. `cause`
reads the error behind an `ActivationException`, `disposeFailures` reads the
dispose functions that failed, and `isCanceled` tells a cancellation from a
failure.

## Example

```sh
dart run packages/fp_di_fpdart/example/checkout.dart
```

The [architecture spec](../../specs/architecture/spec.md#fpdart-interoperability)
states the interoperability contract.
