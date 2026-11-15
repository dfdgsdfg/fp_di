## Unreleased

- Added `ScopeBuilder`. Its unnamed constructor creates a child of the scope
  of the closest `ScopeProvider`, calls `initialize`, publishes the child,
  builds from a `ScopeSnapshot`, and disposes the child when it is
  unmounted. `ScopeBuilder.value` builds from the state of a caller-owned
  scope.

## 0.1.0

- Initial release.
