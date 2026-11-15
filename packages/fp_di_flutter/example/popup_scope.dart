// Dialogs, bottom sheets, and snack bars of a route that has a scope.
//
// A popup is not below the widget that opens it. Each kind of popup lives
// at another place of the tree:
//
// - `showDialog`, `showGeneralDialog`, `showCupertinoModalPopup`, and
//   `showDatePicker` push a route on the root `Navigator` by default.
// - `showModalBottomSheet` pushes a route on the nearest `Navigator` by
//   default.
// - `ScaffoldMessenger` builds a snack bar in every root `Scaffold` below it:
//   also in the `Scaffold` of a route below, and in the `Scaffold` of the
//   next route after this route leaves.
//
// `CartShell` publishes the cart scope above a nested `Navigator` with a
// `ScopeBuilder`, as `navigator_scope.dart` does for a session. The cart page
// then opens:
//
// - a dialog on the nested `Navigator` with `useRootNavigator: false`. The
//   dialog is below the cart scope and reads it.
// - a dialog on the root `Navigator`. It republishes the cart scope with
//   `ScopeProvider.fixed`, because the dialog closes before the cart route
//   leaves.
// - a modal bottom sheet. It is a route of the nested `Navigator` by default
//   and reads the cart scope.
// - a snack bar. Its content takes values, not reads: the messenger also
//   builds it in the `Scaffold` of the home page, which reads the app scope.
import 'package:flutter/material.dart';
import 'package:fp_di/fp_di.dart';
import 'package:fp_di_flutter/fp_di_flutter.dart';

// --- App level -------------------------------------------------------------

final class AppInfo {
  const AppInfo(this.name);
  final String name;
}

/// What the whole application shares.
final appModule = Module(
  components: [Component<AppInfo>.value(value: const AppInfo('shop'))],
  debugLabel: 'app',
);

// --- Cart level ------------------------------------------------------------

final class Cart extends ChangeNotifier {
  final List<String> _items = [];
  bool isOpen = true;

  int get count => _items.length;

  void add() {
    _items.add('item ${_items.length + 1}');
    notifyListeners();
  }

  void removeLast() {
    if (_items.isEmpty) return;
    _items.removeLast();
    notifyListeners();
  }

  void clear() {
    _items.clear();
    notifyListeners();
  }

  void close() {
    isOpen = false;
    dispose();
  }
}

/// What one visit of the cart owns.
final cartModule = Module(
  components: [
    Component<Cart>(
      dependency: Dependency<Cart>(
        create: Cart.new,
        dispose: (cart) => cart.close(),
      ),
    ),
  ],
  debugLabel: 'cart',
);

Future<void> main() async {
  final app = await Scope(module: appModule).initialize();
  runApp(PopupScopeApp(scope: app));
}

// --- Widgets ---------------------------------------------------------------

final class PopupScopeApp extends StatelessWidget {
  const PopupScopeApp({required this.scope, super.key});

  final Scope scope;

  @override
  Widget build(BuildContext context) {
    return ScopeProvider.fixed(
      scope: scope,
      child: const MaterialApp(home: HomePage()),
    );
  }
}

/// A route of the root `Navigator`. It reads the app scope only.
final class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final info = context.di<AppInfo>();
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('welcome to ${info.name}'),
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const CartShell()),
              ),
              child: const Text('Open cart'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Publishes the cart scope above a nested `Navigator`.
final class CartShell extends StatelessWidget {
  const CartShell({super.key});

  @override
  Widget build(BuildContext context) {
    return ScopeBuilder(
      create: (parent) => parent.child(module: cartModule),
      builder: (context, snapshot, child) => switch (snapshot) {
        ScopeSnapshot(:final error?) => Text('failed: $error'),
        _ when snapshot.scope.isInitialized => child!,
        _ => const Text('opening'),
      },
      child: Navigator(
        onGenerateRoute: (_) =>
            MaterialPageRoute<void>(builder: (_) => const CartPage()),
      ),
    );
  }
}

final class CartPage extends StatelessWidget {
  const CartPage({super.key});

  @override
  Widget build(BuildContext context) {
    final cart = context.di<Cart>();
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CartCount(),
            TextButton(
              onPressed: () {
                cart.add();
                // Read the values here. The content of a snack bar reads no
                // scope: the messenger also builds it in the `Scaffold` of the
                // home page, and it stays after the cart route leaves.
                final count = cart.count;
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(content: Text('$count in the cart')));
              },
              child: const Text('Add item'),
            ),
            TextButton(
              // The nested `Navigator` keeps the dialog below the cart scope.
              onPressed: () => showDialog<void>(
                context: context,
                useRootNavigator: false,
                builder: (_) => const RemoveItemDialog(),
              ),
              child: const Text('Remove item'),
            ),
            TextButton(
              onPressed: () {
                // A dialog of the root `Navigator` is outside the cart scope.
                // It closes before the cart route leaves, so it can
                // republish the cart scope with the fixed constructor.
                final scope = ScopeProvider.of(context);
                showDialog<void>(
                  context: context,
                  builder: (_) => ScopeProvider.fixed(
                    scope: scope,
                    child: const ClearCartDialog(),
                  ),
                );
              },
              child: const Text('Clear cart'),
            ),
            TextButton(
              // A modal bottom sheet uses the nearest `Navigator` by default.
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                builder: (_) => const ShippingSheet(),
              ),
              child: const Text('Choose shipping'),
            ),
            TextButton(
              // The root `Navigator` removes the whole cart shell.
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
              child: const Text('Close cart'),
            ),
          ],
        ),
      ),
    );
  }
}

final class CartCount extends StatelessWidget {
  const CartCount({super.key});

  @override
  Widget build(BuildContext context) {
    // `watchDi` does not watch the fields of a value. The cart notifies its
    // own listeners when its items change.
    final cart = context.di<Cart>();
    return ListenableBuilder(
      listenable: cart,
      builder: (context, _) => Text('cart: ${cart.count} items'),
    );
  }
}

/// A route of the nested `Navigator`, below the cart scope.
final class RemoveItemDialog extends StatelessWidget {
  const RemoveItemDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final cart = context.di<Cart>();
    return AlertDialog(
      content: Text('remove one of ${cart.count} items'),
      actions: [
        TextButton(
          onPressed: () {
            cart.removeLast();
            Navigator.of(context).pop();
          },
          child: const Text('Remove'),
        ),
      ],
    );
  }
}

/// A route of the root `Navigator`, below the republished cart scope.
final class ClearCartDialog extends StatelessWidget {
  const ClearCartDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final cart = context.di<Cart>();
    return AlertDialog(
      content: Text('clear ${cart.count} items'),
      actions: [
        TextButton(
          onPressed: () {
            cart.clear();
            Navigator.of(context).pop();
          },
          child: const Text('Clear'),
        ),
      ],
    );
  }
}

/// A route of the nested `Navigator`, below the cart scope.
final class ShippingSheet extends StatelessWidget {
  const ShippingSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final cart = context.di<Cart>();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('ship ${cart.count} items'),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
