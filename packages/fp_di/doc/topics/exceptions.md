A `DiException` is a failure while the program runs. A caller can catch it
and handle it. Following Dart, a `DiException` is an `Exception`.

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
