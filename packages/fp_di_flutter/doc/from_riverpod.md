This guide is for readers who know
[flutter_riverpod](https://pub.dev/packages/flutter_riverpod). It maps the
widget part of Riverpod to `fp_di_flutter`: `ProviderScope`, the consumer
widgets, and `WidgetRef`. The Dart part, providers, `Ref`, families, and
state, is in the
[guide of `fp_di`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/doc/from_riverpod.md).
Read that guide first. The Riverpod names are those of `flutter_riverpod` 3.5.

## Two models in the widget tree

A `ProviderScope` at the root of the app creates a `ProviderContainer` and
gives it to the widget tree
([containers](https://riverpod.dev/docs/concepts2/containers)). A consumer
widget reads a provider through a `WidgetRef`. A read creates the state of
the provider when it has none, and a widget that reads a provider with
`ref.watch` keeps a provider with auto dispose alive.

`fp_di_flutter` publishes a scope that already ran `initialize`. A widget
reads it through the `BuildContext`. A read creates nothing, and a widget
does not keep a value alive. The scope decides when a value is released.

| flutter_riverpod | `fp_di_flutter` |
|---|---|
| `ProviderScope` at the root | `ScopeProvider.fixed(scope: app)` above `MaterialApp` |
| `ConsumerWidget`, `Consumer`, `ConsumerStatefulWidget` | Any widget |
| `ref.watch(p)` in `build` | `context.watchDi<T>()` |
| `ref.read(p)` in a callback | `context.di<T>()` |
| `ref.watch(p.select(...))` | No equivalent; the value notifies, and a `ListenableBuilder` or a `StreamBuilder` listens |
| A switch on an `AsyncValue` in `build` | A switch on `context.watchMaybeDiNode<T>()`, or on a `ScopeSnapshot` |
| A provider with auto dispose that one page reads with `ref.watch` | A `ScopeBuilder` in that page |
| A nested `ProviderScope` with `overrides` | A `ScopeBuilder`, or a `ScopeProvider` of a child scope |
| `ref.listen` in `build` | The widget that starts the change shows the result |
| Listeners paused while `TickerMode` is off | No pause |

## Publishing the root

```dart
// flutter_riverpod
void main() => runApp(const ProviderScope(child: App()));

// fp_di_flutter: create and initialize the scope first.
Future<void> main() async {
  final app = await Scope(module: appModule).initialize();
  runApp(ScopeProvider.fixed(scope: app, child: const App()));
}
```

The failures of startup reach `main`, before the first frame. Put the
provider above `MaterialApp`, so that every route, dialog, and snack bar is
below it. For a scope that the app replaces, such as a login session, use
`ScopeProvider.listenable`. The
[README](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di_flutter/README.md#publishing-a-scope)
explains the order of a replacement and a disposal.

## Reading in a widget

```dart
// flutter_riverpod
final class Profile extends ConsumerWidget {
  const Profile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(profileRepoProvider);
    return TextButton(
      onPressed: () => ref.read(analyticsProvider).log('tap'),
      child: Text(repo.title),
    );
  }
}

// fp_di_flutter: any widget.
final class Profile extends StatelessWidget {
  const Profile({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = context.watchDi<ProfileRepo>();
    return TextButton(
      onPressed: () => context.di<Analytics>().log('tap'),
      child: Text(repo.title),
    );
  }
}
```

`context.watchDi<T>()` rebuilds the widget when another node publishes the
key, or when the value appears or leaves. It does not rebuild when a field of
the value changes, because `fp_di` holds no state. A value that changes
notifies its own listeners, and the widget listens to it:

```dart
final cart = context.di<Cart>(); // a ChangeNotifier
return ListenableBuilder(
  listenable: cart,
  builder: (context, _) => Text('${cart.count} items'),
);
```

`select` has no equivalent for the same reason. A `ValueListenableBuilder`
on a field that is a `ValueNotifier` rebuilds for that field only.

## Loading and errors

A switch on an `AsyncValue` maps to a switch on the state of a node:

```dart
// flutter_riverpod
return switch (ref.watch(profileProvider)) {
  AsyncData(:final value) => ProfileView(value),
  AsyncError(:final error) => ErrorView(error),
  _ => const Loading(),
};

// fp_di_flutter
final node = context.watchMaybeDiNode<Profile>();
return switch (node?.state.phase) {
  NodePhase.active => ProfileView(node!.value),
  NodePhase.activationFailed => ErrorView(node!.activationException!.cause),
  _ => const Loading(),
};
```

The state of a node shows what happens after `initialize`, such as a member
that waits for a key of its parent. The failure of `initialize` itself goes
to the code that called `initialize`. A `ScopeBuilder` keeps it in its
snapshot.

## A scope for a page

A provider with auto dispose often holds the values of one page: the page
reads it with `ref.watch`, and the state goes when the page leaves. A
`family` adds the argument of the page. In `fp_di_flutter` the page owns a child scope through
a `ScopeBuilder`:

```dart
// flutter_riverpod
final orderProvider = FutureProvider.autoDispose.family<Order, String>(
  (ref, id) => ref.watch(apiProvider).order(id),
);

// fp_di_flutter: the module of the page is built from the argument.
Module orderModule(String id) => Module(
  components: [
    Component<Order>(
      dependency: Dependency1<Api, Order>(create: (api) => api.order(id)),
    ),
  ],
);

final class OrderPage extends StatelessWidget {
  const OrderPage({required this.id, super.key});

  final String id;

  @override
  Widget build(BuildContext context) {
    return ScopeBuilder(
      create: (parent) => parent.child(module: orderModule(id)),
      builder: (context, snapshot, child) => switch (snapshot) {
        ScopeSnapshot(:final error?) => ErrorView(error),
        _ when snapshot.scope.isInitialized => child!,
        _ => const Loading(),
      },
      child: const OrderView(),
    );
  }
}
```

- The scope starts when the page mounts. `ScopeBuilder` calls `create` again
  only when the scope above is replaced. A page for another id needs another
  `key`.
- The scope is released when the page unmounts. For a route, that is after
  its exit transition, so the exiting page still reads its values.
- Riverpod releases a state one frame after its last listener leaves
  ([auto dispose](https://riverpod.dev/docs/concepts2/auto_dispose)). A
  `ScopeBuilder` releases its scope in `State.dispose`.

## A value for a subtree

Riverpod overrides a provider for a subtree with a nested `ProviderScope`.
The provider must opt in with `dependencies`, and each provider that reads it
must list it too ([scoping](https://riverpod.dev/docs/concepts2/scoping)).

In `fp_di` a child scope can publish any key of its parent again. The
widgets below the child scope, and the members of the child scope, read the
nearer value:

```dart
// flutter_riverpod
ProviderScope(
  overrides: [currentItemIdProvider.overrideWithValue('123')],
  child: const DetailPageView(),
);

// fp_di_flutter
const currentItemId = DiKey<String>(name: 'currentItemId');

ScopeBuilder(
  create: (parent) => parent.child(
    module: Module(
      components: [
        Component<String>.value(value: '123', key: currentItemId),
      ],
    ),
  ),
  builder: (context, snapshot, child) =>
      snapshot.scope.isInitialized ? child! : const Loading(),
  child: const DetailPageView(),
);
```

A member of the parent scope does not see the value of the child scope.

## Side effects of a change

Riverpod shows a dialog or a snack bar for a change with `ref.listen` in
`build` ([refs](https://riverpod.dev/docs/concepts2/refs)). `fp_di` has no
listener on a value. Two forms remain:

- The widget that starts the change awaits it and shows the result. Read the
  values at the call site, and pass values, not reads, to the content of the
  snack bar. The
  [README](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di_flutter/README.md#dialogs-bottom-sheets-and-snack-bars)
  explains which scope a dialog, a bottom sheet, and a snack bar read.
- A `State` listens to the value that changes, such as a `Stream` or a
  `ChangeNotifier`, from `initState` to `dispose`.

## Routes that are not visible

Riverpod 3 pauses the listeners of a consumer while its `TickerMode` is off,
for example on a route below another route
([what's new](https://riverpod.dev/docs/whats_new)). `fp_di_flutter` pauses
nothing. A route below another route keeps its scope and its values, and its
watchers rebuild when a key changes.

## Logout

A session that ends must not leave widgets that read its values. With
`ScopeProvider.listenable`, change the value to the app scope first, and
dispose the session scope after that. A route of the session can also live
below a nested `Navigator` inside a `ScopeBuilder` of the session, so the
session ends with that route. The examples `session_scope.dart` and
`navigator_scope.dart` show both forms. A route of a flat `Navigator` that
reads the session goes below a `ScopeBoundary`: the disposal then waits until
the route has left, and the route reads live values during its exit
transition.

## Widget tests

```dart
// flutter_riverpod
await tester.pumpWidget(
  ProviderScope(
    overrides: [apiProvider.overrideWithValue(FakeApi())],
    child: const App(),
  ),
);

// fp_di_flutter
final scope = await Scope(
  module: appModule.overriddenBy(
    Module(components: [Component<Api>.value(value: FakeApi())]),
  ),
).initialize();
addTearDown(scope.dispose);
await tester.pumpWidget(ScopeProvider.fixed(scope: scope, child: const App()));
```

## Both at one time

The two libraries can share an app while it moves. Put `ProviderScope` and
`ScopeProvider` above `MaterialApp`, and move one feature at a time. A
provider can read a service from the scope that `main` created, and a
widget can read both.
