Something can go wrong in two ways, and Dart has a type for each.

An **error** (`DiError`) is a mistake in the program, such as a key that no
scope publishes. Fix the code, and do not catch the error. An **exception**
(`DiException`) is a failure while the program runs, such as a `create` that
throws. A caller can catch it and handle it.

## Errors

Following Dart, a `DiError` is an `Error`, like `ArgumentError` and
`StateError`.

The errors of `initialize` are statements about the shape of a module `m`,
so they are found before anything is created:

```text
UndeclaredKeyError   when  requires(m) \ ⋃ publishes(ancestors) ≠ ∅
DuplicateKeyError    when  two members of m publish one key
```

`ShapeGraph` reports the same two sets, `undeclared` and `duplicates`, without
a scope.

- `initialize` throws `UndeclaredKeyError`, `DuplicateKeyError`, and
  `DependencyCycleError` for a module that it cannot run.
- A lookup of a disposed scope throws `DisposedScopeError`.
- A call in the wrong place throws `OutsideActivationError` or
  `ReentrantMutationError`.
- A key of a `Future` or `FutureOr` type throws `UnreachableKeyError`, because
  no lookup can name it.

## Exceptions

Following Dart, a `DiException` is an `Exception`. The
[failure rules](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/doc/lifecycle.md#failures-and-atomicity)
of the Lifecycle guide explain when each one is thrown.

- `initialize` throws `ActivationException` when a member fails, after the
  rollback. `ActivationCanceledException` reports an activation that stopped
  because the disposal of its owner was requested.
- `dispose` throws `DisposeException`, which lists each failed dispose
  function as a `DisposeFailure`.
- `get` throws `UnavailableKeyException` for a key without a value, with the
  failed nodes behind the key. `ComponentNode.value` throws
  `InactiveNodeException`.
- `Scope.errors` reports the exceptions that no caller receives, such as a
  failed automatic activation and a `DiListenerException`.
