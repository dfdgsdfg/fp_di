## Unreleased

- When several members fail in one `initialize`, the rollback failures of the
  other failed members now follow those of the rethrown member in declaration
  order. Before, they followed the order in which the members failed.
- Internal: the runtime keeps a failure as a cause value until the public
  error is made. The public exceptions and their fields do not change.

## 0.2.1

- Performance: `Scope.initialize`, `Module.requires`, and `Module.reads` find
  the member that publishes a key with an index, and a scope teardown checks
  only the nodes that a finished release read. A chain of 16000 members
  initialized in about 0.6 s and disposed in about 4.9 s (AOT); it now takes
  about 0.1 s and 0.04 s.
- Documentation: the example `drain_scope.dart` separates what a logout must
  finish from what it may drop, with a scope for the database of a session,
  a hold for work outside the graph, and a time limit.

## 0.2.0

- Breaking: `Scope.dispose` waits for the holds of the disposal. A consumer
  outside the runtime takes a hold with `Scope.disposeHold(debugLabel:)` and
  closes it with `DisposeHold.close()`. While a hold of the scope or of a
  descendant is open, the scope stays in `disposeRequested`: the lookups
  answer, no node starts an activation, and the disposal mutation waits
  outside the queue. `dispose(ignoreHolds: true)` does not wait, and reports
  an `IgnoredHoldsException` to `Scope.errors` when it ignores open holds.
  Without a hold, a disposal starts at once, as before.
- Added `Scope.openHolds` and `HoldState`. `describe` and the `SlowMutation`
  of a root with `onSlowMutation` name the holds that a disposal waits for,
  with the operation `Scope.dispose (waiting for holds)` and the new field
  `SlowMutation.holds`.
- Breaking: `Lazy.force()` fails with `DisposedLazyException` once the
  disposal of its owner is requested. A creation in flight continues, and the
  release awaits it.
- Breaking: `Scope.addListener` adds a listener in `disposeRequested`, and
  throws only once the disposal mutation starts.
- The DevTools inspector lists the labels of the open holds of each scope in
  `holds` of the `state` answer.
- Documentation: a guide for readers who know Riverpod,
  `doc/from_riverpod.md`. It maps providers, `Ref`, and `ProviderContainer`
  to `fp_di`, and the API reference shows it as the category Coming from
  Riverpod.
- Documentation: the get_it guide names `ScopeBuilder` of `fp_di_flutter`
  for the scope of a widget subtree.

## 0.1.0

- Initial release.
- Experimental: a debug build serves an inspector to Dart DevTools, with no
  call in the app. The DevTools extension that shows it is not in this
  package; build it from `packages/fp_di_devtools` in the repository.
  The service extensions list the live roots, the state tree of a root, the
  details of a node with the cause of an unavailable key, and the shape graph
  of a scope. After the extension listens, it posts transitions, errors, and
  slow mutations. A build without assertions registers nothing.
