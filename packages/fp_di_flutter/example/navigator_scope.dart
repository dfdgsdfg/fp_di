// A scope that a route owns.
//
// A route is not below the widget that pushed it. Every route of a
// `Navigator` is a sibling below that `Navigator`. A route that needs a scope
// therefore publishes the scope itself, or it lives below a `Navigator` that
// is below the provider.
//
// `ScopeBuilder` creates a child of the ambient scope, calls `initialize`,
// publishes the scope, and disposes the scope when it leaves the tree.
//
// Flutter calls `State.dispose` of the `ScopeBuilder` only after the exit
// transition of the route ends. An exiting route still reads its scope, and
// no widget reads a disposed scope.
//
// `SessionShell` publishes the session scope and holds a nested `Navigator`.
// The routes of the session are below that `Navigator`, so they read the
// session scope. The editor route publishes its own scope, a child of the
// session scope.
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
  components: [Component<AppInfo>.value(value: const AppInfo('fp_di'))],
  debugLabel: 'app',
);

// --- Session level ---------------------------------------------------------

final class Session {
  const Session(this.userId);
  final String userId;
}

final class ProfileRepository {
  ProfileRepository(this.session);
  final Session session;
  bool isOpen = true;
  String get title => 'profile of ${session.userId}';
  void close() => isOpen = false;
}

/// What one login owns.
Module sessionModule(String userId) => Module(
  components: [
    Component<Session>.value(value: Session(userId)),
    Component<ProfileRepository>(
      dependency: Dependency1<Session, ProfileRepository>(
        create: ProfileRepository.new,
        dispose: (profiles) => profiles.close(),
      ),
    ),
  ],
  debugLabel: 'session',
);

// --- Page level ------------------------------------------------------------

final class DraftStore {
  DraftStore(Session session) : owner = session.userId;
  final String owner;
  bool isOpen = true;
  void close() => isOpen = false;
}

/// What one editor route owns. It reads `Session` from the session scope, so
/// the editor scope is a child of the session scope.
final editorModule = Module(
  components: [
    Component<DraftStore>(
      dependency: Dependency1<Session, DraftStore>(
        create: DraftStore.new,
        dispose: (store) => store.close(),
      ),
    ),
  ],
  debugLabel: 'editor',
);

Future<void> main() async {
  final app = await Scope(module: appModule).initialize();
  runApp(NavigatorScopeApp(scope: app));
}

// --- Widgets ---------------------------------------------------------------

final class NavigatorScopeApp extends StatelessWidget {
  const NavigatorScopeApp({required this.scope, super.key});

  final Scope scope;

  @override
  Widget build(BuildContext context) {
    return ScopeProvider.fixed(
      scope: scope,
      child: const MaterialApp(home: LoginPage()),
    );
  }
}

final class LoginPage extends StatelessWidget {
  const LoginPage({super.key});

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
              // The session shell replaces the login page.
              onPressed: () => Navigator.of(context).pushReplacement(
                MaterialPageRoute<void>(
                  builder: (_) => const SessionShell(userId: 'ada'),
                ),
              ),
              child: const Text('Log in'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Publishes the session scope above a nested `Navigator`.
final class SessionShell extends StatelessWidget {
  const SessionShell({required this.userId, super.key});

  final String userId;

  @override
  Widget build(BuildContext context) {
    return ScopeBuilder(
      // `create` runs again only when the scope above is replaced, so a
      // rebuild of the shell does not make another module.
      create: (parent) => parent.child(module: sessionModule(userId)),
      builder: _build,
      // Each route of this `Navigator` is below the session scope.
      child: Navigator(
        onGenerateRoute: (_) =>
            MaterialPageRoute<void>(builder: (_) => const HomePage()),
      ),
    );
  }
}

/// The loading state, the error state, and the ready state of a scope.
Widget _build(BuildContext context, ScopeSnapshot snapshot, Widget? child) {
  return switch (snapshot) {
    ScopeSnapshot(:final error?) => Text('failed: $error'),
    ScopeSnapshot(phase: ScopePhase.initialized) => child!,
    _ => const Text('opening'),
  };
}

final class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final profiles = context.watchDi<ProfileRepository>();
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(profiles.title),
            TextButton(
              // The nested `Navigator` keeps the route below the session scope.
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ScopeBuilder(
                    create: (parent) => parent.child(module: editorModule),
                    builder: _build,
                    child: const EditorPage(),
                  ),
                ),
              ),
              child: const Text('Open editor'),
            ),
            TextButton(
              // The root `Navigator` replaces the whole session shell.
              onPressed: () =>
                  Navigator.of(context, rootNavigator: true).pushReplacement(
                    MaterialPageRoute<void>(builder: (_) => const LoginPage()),
                  ),
              child: const Text('Log out'),
            ),
          ],
        ),
      ),
    );
  }
}

final class EditorPage extends StatelessWidget {
  const EditorPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watchDi<DraftStore>();
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('drafts of ${store.owner}'),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close editor'),
            ),
          ],
        ),
      ),
    );
  }
}
