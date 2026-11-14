## 0.1.0

- Initial release.
- Experimental: a debug build serves an inspector to Dart DevTools, with no
  call in the app. The DevTools extension that shows it is not in this
  package; build it from `packages/fp_di_devtools` in the repository.
  The service extensions list the live roots, the state tree of a root, the
  details of a node with the cause of an unavailable key, and the shape graph
  of a scope. After the extension listens, it posts transitions, errors, and
  slow mutations. A build without assertions registers nothing.
