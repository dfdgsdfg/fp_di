## 0.2.0

- Added `ScopeBoundary(scope:, builder:, child:, debugLabel:)`. It holds the
  disposal of a caller-owned scope while it is mounted, publishes the scope,
  and builds from a `ScopeSnapshot`, so an exiting route reads live values
  until it leaves. It requires `fp_di` 0.2.0.
- Breaking: `ScopeBuilder.value` is removed; use `ScopeBoundary`.
- Breaking: `ScopeBuilder` runs its builder in `disposeRequested`, where the
  lookups answer, and keeps no widget below it once the disposal starts.
- `ScopeProvider` listens to and compares the watched keys until the disposal
  mutation of the published scope starts, also while a hold keeps it waiting.

## 0.1.1

- Added `ScopeBuilder`. Its unnamed constructor creates a child of the scope
  of the closest `ScopeProvider`, calls `initialize`, publishes the child,
  builds from a `ScopeSnapshot`, and disposes the child when it is
  unmounted. `ScopeBuilder.value` builds from the state of a caller-owned
  scope.
- Documentation: a guide for readers who know flutter_riverpod,
  `doc/from_riverpod.md`, shown as the API category Coming from Riverpod.
- Documentation: the examples `page_scope.dart`, `navigator_scope.dart`, and
  `popup_scope.dart` use `ScopeBuilder`.

## 0.1.0

- Initial release.
