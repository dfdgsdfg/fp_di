# fp_di_flutter

Thin Flutter integration for `fp_di`.

```dart
final di = Scope(module: appModule);
await di.initialize();

runApp(ScopeProvider.fixed(scope: di, child: const App()));
```

Use `context.di<T>()` for a non-listening lookup and `context.watchDi<T>()` to
rebuild on publisher identity or availability changes. `watchDi` does not watch
mutable fields inside `T`.

## Examples

Each file in [`example/`](https://github.com/dfdgsdfg/fp_di/tree/main/packages/fp_di_flutter/example) is one application with its own `main`:

| Example | Shows |
|---|---|
| [`main.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di_flutter/example/main.dart) | One scope for the whole application, published with `ScopeProvider.fixed` and read with `context.di` |
| [`session_scope.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di_flutter/example/session_scope.dart) | A session scope that a login creates and a logout disposes, with one provider at the root and a holder of the current scope |
| [`watch.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di_flutter/example/watch.dart) | The difference between `di`, which reads once, and `watchDi`, which rebuilds when the key changes |
| [`node_state.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di_flutter/example/node_state.dart) | Loading, error, and data from the state of a node, with `watchMaybeDiNode` |
| [`page_scope.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di_flutter/example/page_scope.dart) | A scope that the `State` of one page creates, initializes, and disposes, with a `FutureBuilder` for its loading and error states |
| [`navigator_scope.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di_flutter/example/navigator_scope.dart) | A scope that a route owns: a session scope above a nested `Navigator`, and a page scope in a pushed route, each alive until its route leaves |
| [`popup_scope.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di_flutter/example/popup_scope.dart) | A dialog, a modal bottom sheet, and a snack bar of a route that has a scope: which scope each one reads |

The package has no platform folders, so `flutter run` does not start an
example. Copy a file into the `lib/main.dart` of a Flutter application to run
it. A widget test runs each example:

```sh
flutter test packages/fp_di_flutter/test/example_test.dart
```

## Publishing a scope

`ScopeProvider` publishes a caller-owned `Scope`. It does not create,
initialize, or dispose a scope. It has two constructors:

| Constructor | Scope | Use |
|---|---|---|
| `ScopeProvider.listenable(scope: listenable)` | The value of a `ValueListenable<Scope>`, read at each lookup | A scope that the host replaces, such as a session scope |
| `ScopeProvider.fixed(scope: di)` | One scope | A scope that lives longer than the widget, such as the one scope of an application or of a test |

Use `ScopeProvider.listenable` when a scope can be disposed while the widget is
mounted. A lookup reads the value of the listenable at the moment of the call,
so a change reaches every lookup before the next frame:

```dart
final current = ValueNotifier<Scope>(app);

runApp(ScopeProvider.listenable(scope: current, child: const App()));

// Log in: publish the session scope.
current.value = session;

// Log out: change the value first, then dispose the old scope.
current.value = app;
await session.dispose();
```

Change the value before you call `dispose`. A scope answers no read from the
moment its disposal starts, not even for a key of its parent. With the other
order, a widget that reads before the change gets a `DisposedScopeError`.

The change does not make a key of the old scope available. Remove the widgets
that read a session key in the frame of the change at the latest. A widget
above them that listens to the same listenable does that: it rebuilds first
and removes them before they rebuild. A callback of such a widget that runs
before that frame and reads a session key gets an `UnavailableKeyException`.
To exclude that read too, remove the widgets before you change the value. See
[`session_scope.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di_flutter/example/session_scope.dart).

`ScopeProvider.fixed` replaces its scope only when its parent rebuilds it. A
lookup before that frame still reads the old scope.

You can change the value of the listenable from any callback, also from
`State.dispose` and from a build. Flutter does not allow `setState` at those
moments, so the provider moves to the new scope after the frame. A lookup
reads the new scope at once, and the listening widgets rebuild one frame
later.

`ScopeProvider.of(context)` and the reads of `context` throw a `FlutterError`
when no provider is above. `ScopeProvider.maybeOf(context)` returns null
instead. It takes the arguments of `of`. Use it for a widget that also works
with no provider, for example with a scope that the host keeps outside the
widget tree:

```dart
final scope = ScopeProvider.maybeOf(context) ?? fallback;
```

## Loading and error states

The provider has no loading widget and no error widget. A widget reads the
state and decides what to show. Two states exist:

| State | Where it is | Read it with |
|---|---|---|
| A call of `initialize` runs or failed | The future of that call | A `FutureBuilder` in the code that called `initialize` |
| A node waits, activates, or failed after `initialize` | The node | `context.watchMaybeDiNode<T>()` |

`watchMaybeDiNode` gives the node that publishes `T` and rebuilds the widget
when the state of that node changes:

```dart
final node = context.watchMaybeDiNode<Profile>();
return switch (node?.state.phase) {
  NodePhase.active => ProfileView(node!.value),
  NodePhase.activationFailed =>
    ErrorView(node!.activationException!.cause),
  _ => const Loading(),
};
```

The node reads `activating` and `deactivating` while an activation or a
release runs. Treat every phase except `active` and `activationFailed` as
pending. `maybeDiNode` is the same read
without the rebuild. See [`node_state.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di_flutter/example/node_state.dart).

The failure of `initialize` rolls the members of that scope back, so no node
holds it. It goes to the caller of `initialize` alone.

## A scope for one widget subtree

The package has no widget that creates, initializes, or disposes a scope. The
code that calls `initialize` gets its failure and decides what the user sees
while the call runs, so that code belongs to the host.

For a value that one page owns, create a child scope in the code that owns the
page, and call `initialize` and `dispose` there. Publish the child scope with
`ScopeProvider` below the provider of its parent. A widget below reads the
child scope, and the child scope reads the keys of its parent. See
[`page_scope.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di_flutter/example/page_scope.dart).

## A scope for one route

A route is not below the widget that pushed it. Each route of a `Navigator` is
a sibling below that `Navigator`. A route also stays mounted during its exit
transition. Two rules follow:

- A route that needs a scope publishes that scope with a `ScopeProvider` of
  its own, or it is a route of a `Navigator` that is below the provider.
- A scope that a route owns belongs to a `State` of that route. The `State`
  creates the scope, calls `initialize`, publishes the scope with
  `ScopeProvider.fixed`, and calls `dispose` in `State.dispose`. Flutter calls
  `State.dispose` after the exit transition, so the exiting route reads its
  scope until it leaves.

[`navigator_scope.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di_flutter/example/navigator_scope.dart) shows both rules. Its
session scope is above a nested `Navigator`, so each route of the session
reads the session scope, and a logout needs no order between the route change
and the disposal.

With one provider at the root and a listenable, a replacement reaches a route
that exits too. A widget of that route that reads a key of the old scope with
`watchDi` rebuilds in the frame of the change and throws an
`UnavailableKeyException`. Read such a key with `watchMaybeDi` or `maybeDi`,
or remove the widget in the frame of the change.

## Dialogs, bottom sheets, and snack bars

A popup is not below the widget that opens it, so it does not always read
the scope of that widget:

| Popup | Place in the tree by default | Reads the scope of the page |
|---|---|---|
| `showDialog`, `showGeneralDialog`, `showCupertinoModalPopup`, `showDatePicker` | A route of the root `Navigator` | No |
| `showModalBottomSheet` | A route of the nearest `Navigator` | Only when the scope is above that `Navigator` |
| `ScaffoldMessenger.showSnackBar`, `showMaterialBanner` | Every root `Scaffold` below the messenger | No |

Use one of these forms:

- Open a dialog with `useRootNavigator: false` when the scope is above a
  nested `Navigator`. The dialog is then a route of that `Navigator`.
- Read the scope before you open a dialog of the root `Navigator`, and
  republish it with `ScopeProvider.fixed`. Use this form only when the dialog
  closes before the scope is disposed.
- Give the content of a snack bar or a banner values, not reads. The
  messenger also builds it in the `Scaffold` of a route below, and it stays
  after the route of the scope leaves.

```dart
final scope = ScopeProvider.of(context);
showDialog<void>(
  context: context,
  builder: (_) => ScopeProvider.fixed(scope: scope, child: const ClearCartDialog()),
);

final count = context.di<Cart>().count;
ScaffoldMessenger.of(context).showSnackBar(
  SnackBar(content: Text('$count in the cart')),
);
```

[`popup_scope.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di_flutter/example/popup_scope.dart) shows each form.

Widget-local objects such as `AnimationController`, `FocusNode`, and
`TextEditingController` should remain in ordinary Flutter `State` lifecycles.
