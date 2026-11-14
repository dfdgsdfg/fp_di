// Runs each example of `example/` as a widget test, so an example that the
// README names keeps its documented behaviour.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fp_di/fp_di.dart';
import 'package:fp_di_flutter/fp_di_flutter.dart';

import '../example/main.dart' as one_scope;
import '../example/navigator_scope.dart' as navigator_scope;
import '../example/node_state.dart' as node_state;
import '../example/page_scope.dart' as page_scope;
import '../example/popup_scope.dart' as popup_scope;
import '../example/session_scope.dart' as session_scope;
import '../example/watch.dart' as watch;

void main() {
  testWidgets('main.dart reads a value of the one scope', (tester) async {
    final app = await Scope(module: one_scope.appModule).initialize();

    await tester.pumpWidget(one_scope.ExampleApp(scope: app));

    expect(find.text('Hello, fp_di'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await app.dispose();
  });

  testWidgets('session_scope.dart logs in and out with no failed read', (
    tester,
  ) async {
    final app = await Scope(module: session_scope.appModule).initialize();
    final scopes = session_scope.AppScopes(app);

    await tester.pumpWidget(session_scope.SessionApp(scopes: scopes));
    expect(find.text('auth: ready'), findsOneWidget);
    expect(find.text('Log in'), findsOneWidget);

    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();
    expect(find.text('profile of ada'), findsOneWidget);
    expect(find.text('auth: ready'), findsOneWidget);
    final session = scopes.value;
    final profiles = session.get<session_scope.ProfileRepository>();

    // The tap changes the value and starts the disposal in one turn. A read
    // through the holder gets the app scope before any frame.
    await tester.tap(find.text('Log out'));
    expect(identical(scopes.value, app), isTrue);
    expect(scopes.value.get<session_scope.AuthApi>().status, 'ready');

    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Log in'), findsOneWidget);
    expect(find.text('profile of ada'), findsNothing);
    expect(session.isDisposed, isTrue);
    expect(profiles.isOpen, isFalse);
    expect(app.get<session_scope.HttpClient>().isOpen, isTrue);

    // A second login gets a new session scope.
    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();
    expect(find.text('profile of ada'), findsOneWidget);
    expect(identical(scopes.value, session), isFalse);

    await tester.pumpWidget(const SizedBox());
    await scopes.logout();
    scopes.dispose();
    await app.dispose();
  });

  testWidgets('watch.dart rebuilds only the watching widget', (tester) async {
    final app = await Scope(module: watch.appModule).initialize();

    await tester.pumpWidget(watch.WatchApp(scope: app));
    expect(find.text('watch: Free shipping'), findsOneWidget);
    expect(find.text('read once: Free shipping'), findsOneWidget);

    await tester.tap(find.text('End the promotion'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('watch: no promotion'), findsOneWidget);
    expect(find.text('read once: Free shipping'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await app.dispose();
  });

  testWidgets('node_state.dart shows loading, then a value and a failure', (
    tester,
  ) async {
    final backend = Scope(module: node_state.backendModule);
    final page = await backend
        .child(module: node_state.pageModule)
        .initialize();

    await tester.pumpWidget(node_state.NodeStateApp(scope: page));
    expect(find.text('Profile: loading'), findsOneWidget);
    expect(find.text('Recommendations: loading'), findsOneWidget);

    // The session exists after 300 ms.
    final ready = backend.initialize();
    await tester.pump(const Duration(milliseconds: 300));
    await ready;
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('profile of ada'), findsOneWidget);
    expect(
      find.text('Recommendations failed: Bad state: the service is down'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
    await backend.dispose();
  });

  testWidgets('page_scope.dart opens and closes the store with the page', (
    tester,
  ) async {
    final app = await Scope(module: page_scope.appModule).initialize();

    await tester.pumpWidget(page_scope.PageScopeApp(scope: app));
    expect(find.text('Open editor'), findsOneWidget);

    await tester.tap(find.text('Open editor'));
    await tester.pump();
    expect(find.text('opening the drafts'), findsOneWidget);

    // The store opens after 300 ms.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('drafts of ada'), findsOneWidget);
    final store = tester
        .element(find.byType(page_scope.Editor))
        .di<page_scope.DraftStore>();
    expect(store.isOpen, isTrue);
    // The app scope does not see what the page publishes.
    expect(app.maybeGet<page_scope.DraftStore>(), isNull);

    await tester.tap(find.text('Close editor'));
    await tester.pump();
    expect(find.text('drafts of ada'), findsNothing);
    expect(store.isOpen, isTrue);

    // The store closes 100 ms after the unmount.
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    expect(store.isOpen, isFalse);
    await tester.pumpAndSettle();

    // A page that goes away while its store opens leaves nothing behind.
    await tester.tap(find.text('Open editor'));
    await tester.pump();
    expect(find.text('opening the drafts'), findsOneWidget);
    await tester.tap(find.text('Close editor'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('opening the drafts'), findsNothing);
    expect(app.maybeGet<page_scope.DraftStore>(), isNull);

    await tester.pumpWidget(const SizedBox());
    await app.dispose();
  });

  testWidgets('navigator_scope.dart keeps each scope until its route leaves', (
    tester,
  ) async {
    final app = await Scope(module: navigator_scope.appModule).initialize();

    await tester.pumpWidget(navigator_scope.NavigatorScopeApp(scope: app));
    expect(find.text('Log in'), findsOneWidget);

    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();
    expect(find.text('profile of ada'), findsOneWidget);
    final profiles = ScopeProvider.of(
      tester.element(find.text('profile of ada')),
    ).get<navigator_scope.ProfileRepository>();
    expect(profiles.isOpen, isTrue);

    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    expect(find.text('drafts of ada'), findsOneWidget);
    final store = ScopeProvider.of(
      tester.element(find.text('drafts of ada')),
    ).get<navigator_scope.DraftStore>();
    expect(store.isOpen, isTrue);

    // The exit transition of the editor route runs. The route still reads
    // its scope, and the scope is not disposed before the transition ends.
    await tester.tap(find.text('Close editor'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('drafts of ada'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(store.isOpen, isTrue);

    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('drafts of ada'), findsNothing);
    expect(store.isOpen, isFalse);
    expect(profiles.isOpen, isTrue);

    // A logout with two routes of the session mounted.
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    final second = ScopeProvider.of(
      tester.element(find.text('drafts of ada')),
    ).get<navigator_scope.DraftStore>();
    expect(identical(second, store), isFalse);
    expect(second.isOpen, isTrue);

    // The editor route covers the home page, so the button is offstage.
    tester
        .widget<TextButton>(
          find.widgetWithText(TextButton, 'Log out', skipOffstage: false),
        )
        .onPressed!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('drafts of ada'), findsOneWidget);
    expect(find.text('profile of ada', skipOffstage: false), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(profiles.isOpen, isTrue);
    expect(second.isOpen, isTrue);

    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Log in'), findsOneWidget);
    expect(find.text('profile of ada', skipOffstage: false), findsNothing);
    expect(profiles.isOpen, isFalse);
    expect(second.isOpen, isFalse);

    await tester.pumpWidget(const SizedBox());
    await app.dispose();
  });

  testWidgets('popup_scope.dart reads the cart scope from each popup', (
    tester,
  ) async {
    final app = await Scope(module: popup_scope.appModule).initialize();

    await tester.pumpWidget(popup_scope.PopupScopeApp(scope: app));
    await tester.tap(find.text('Open cart'));
    await tester.pumpAndSettle();
    expect(find.text('cart: 0 items'), findsOneWidget);
    final cart = ScopeProvider.of(
      tester.element(find.text('cart: 0 items')),
    ).get<popup_scope.Cart>();
    final rootNavigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );

    // A snack bar takes values. The messenger also builds it in the
    // `Scaffold` of the home page, which is offstage below the cart route.
    await tester.tap(find.text('Add item'));
    await tester.pump();
    expect(find.text('1 in the cart'), findsOneWidget);
    expect(find.text('1 in the cart', skipOffstage: false), findsNWidgets(2));
    expect(find.text('cart: 1 items'), findsOneWidget);

    // A dialog of the nested `Navigator` reads the cart scope.
    await tester.tap(find.text('Remove item'));
    await tester.pumpAndSettle();
    expect(find.text('remove one of 1 items'), findsOneWidget);
    expect(
      identical(
        Navigator.of(tester.element(find.byType(popup_scope.RemoveItemDialog))),
        rootNavigator,
      ),
      isFalse,
    );
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(find.text('cart: 0 items'), findsOneWidget);

    // A dialog of the root `Navigator` reads the cart scope that the page
    // republished.
    await tester.tap(find.text('Add item'));
    await tester.pump();
    await tester.tap(find.text('Clear cart'));
    await tester.pumpAndSettle();
    expect(find.text('clear 1 items'), findsOneWidget);
    expect(
      identical(
        Navigator.of(tester.element(find.byType(popup_scope.ClearCartDialog))),
        rootNavigator,
      ),
      isTrue,
    );
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('cart: 0 items'), findsOneWidget);

    // Without the republication, a dialog of the root `Navigator` reads the
    // app scope.
    Scope? seen;
    unawaited(
      showDialog<void>(
        context: tester.element(find.byType(popup_scope.CartPage)),
        builder: (context) {
          seen = ScopeProvider.of(context);
          return const SizedBox();
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(identical(seen, app), isTrue);
    rootNavigator.pop();
    await tester.pumpAndSettle();

    // A modal bottom sheet is a route of the nested `Navigator`.
    await tester.tap(find.text('Choose shipping'));
    await tester.pumpAndSettle();
    expect(find.text('ship 0 items'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    // The snack bar stays after the cart route leaves, and the cart scope is
    // disposed after the exit transition.
    await tester.tap(find.text('Add item'));
    await tester.pump();
    await tester.tap(find.text('Close cart'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(cart.isOpen, isTrue);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('welcome to shop'), findsOneWidget);
    expect(find.text('1 in the cart'), findsOneWidget);
    expect(cart.isOpen, isFalse);

    // The snack bar closes after its duration.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('1 in the cart'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await app.dispose();
  });
}
