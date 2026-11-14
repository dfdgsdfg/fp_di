A `DiError` is a mistake in the program. Fix the code, and do not catch the
error. Following Dart, a `DiError` is an `Error`, like `ArgumentError` and
`StateError`.

- `initialize` throws `UndeclaredKeyError`, `DuplicateKeyError`, and
  `DependencyCycleError` for a module that it cannot run.
- A lookup of a disposed scope throws `DisposedScopeError`.
- A call in the wrong place throws `OutsideActivationError` or
  `ReentrantMutationError`.
- A key of a `Future` or `FutureOr` type throws `UnreachableKeyError`, because
  no lookup can name it.
