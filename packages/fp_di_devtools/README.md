# fp_di_devtools

> **Experimental.** A release of `fp_di` does not ship this extension. Build
> it locally to use it, and expect the protocol to change.

The DevTools extension app of `fp_di`. It is a Flutter web app that DevTools
loads in its `fp_di` tab. The app reads a running app through the inspector of
the core package and changes nothing. The package is not published.

Contract: [DevTools extension](../../specs/tooling/devtools/spec.md).

## Build and check

Run each command from the workspace root unless the command changes the
folder. Run `flutter pub get` once before them.

```sh
flutter test packages/fp_di_devtools/test
(cd packages/fp_di_devtools && \
  dart run devtools_extensions build_and_copy --source=. --dest=../fp_di/extension/devtools)
cp packages/fp_di_devtools/config.yaml packages/fp_di/extension/devtools/
dart run devtools_extensions validate --package=packages/fp_di
```

The root `.gitignore` excludes `packages/fp_di/extension/`, so the build stays
local and a release of `fp_di` does not contain it. DevTools finds the
extension when the app depends on `fp_di` by a path to this workspace.

The tests read the answers that the inspector gave in
`packages/fp_di/test/support/devtools_fixtures/`. After a change to the
protocol, record them again:

```sh
dart run --enable-asserts packages/fp_di/test/support/dump_devtools_fixtures.dart
```

## Manual check (V-Q-TL-DT-001)

1. Build the extension as stated above.
2. Run `dart run --enable-asserts --observe packages/fp_di/example/session_scope.dart`.
   The example sets `Scope.debugInspector = true`. An app must set the switch
   before its first root scope. Open DevTools from the printed address.
3. Enable the `fp_di` extension in DevTools, and open the `fp_di` tab.
4. Check that the scope tree, the nodes, the details, the timeline, and the
   graph show the state of the app during startup, a logout, and a failed
   activation.
5. Run the Flutter example `packages/fp_di_flutter/example/session_scope.dart`
   in debug mode, and repeat step 4.
6. Run the same Flutter example in release mode. Check that DevTools lists no
   `ext.fp_di` service extension.
