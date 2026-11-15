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
