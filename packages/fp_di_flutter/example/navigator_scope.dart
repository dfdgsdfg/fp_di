// A scope that a route owns.
//
// A route is not below the widget that pushed it. Every route of a
// `Navigator` is a sibling below that `Navigator`. A route that needs a scope
// therefore publishes the scope itself, or it lives below a `Navigator` that
// is below the provider.
//
// The package has no widget that creates a scope, so `ScopeHost` is part of
// this example. Its `State` creates a child of the ambient scope, calls
// `initialize`, publishes the scope with `ScopeProvider.fixed`, and disposes
// the scope in `State.dispose`.
//
// Flutter calls `State.dispose` only after the exit transition of the route
// ends. Every read of an exiting route still gets a value, and no widget
// reads a disposed scope.
//
// `SessionShell` hosts the session scope and holds a nested `Navigator`. The
// routes of the session are below that `Navigator`, so they read the session
// scope. The editor route hosts its own scope, a child of the session scope.
import 'dart:async';

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

// --- The host of a scope ---------------------------------------------------

/// Creates a child of the ambient scope and publishes it to [child].
final class ScopeHost extends StatefulWidget {
  const ScopeHost({required this.module, required this.child, super.key});

  final Module module;
  final Widget child;

  @override
  State<ScopeHost> createState() => _ScopeHostState();
}

final class _ScopeHostState extends State<ScopeHost> {
  Scope? _parent;
  Scope? _scope;
  Future<Scope>? _ready;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final parent = ScopeProvider.of(context, listenToScope: true);
    if (identical(parent, _parent)) return;
    _parent = parent;
    _close();
    final scope = parent.child(module: widget.module);
    _scope = scope;
    // `ignore` keeps a failure that nothing listens to from becoming an
    // uncaught error. The FutureBuilder still receives the failure.
    _ready = scope.initialize()..ignore();
  }

  /// Disposes the scope. A disposal during `initialize` cancels it.
  void _close() {
    final scope = _scope;
    if (scope == null) return;
    _scope = null;
    unawaited(
      scope.dispose().catchError((Object error, StackTrace stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            context: ErrorDescription('while disposing a hosted scope'),
          ),
        );
      }),
    );
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Scope>(
      future: _ready,
      builder: (context, snapshot) {
        // A FutureBuilder keeps the data of its last future while a new one
        // runs, so check the connection state first.
        if (snapshot.connectionState != ConnectionState.done) {
          return const Text('opening');
        }
        if (snapshot.hasError) return Text('failed: ${snapshot.error}');
        return ScopeProvider.fixed(
          scope: snapshot.requireData,
          child: widget.child,
        );
      },
    );
  }
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

/// Hosts the session scope above a nested `Navigator`.
final class SessionShell extends StatefulWidget {
  const SessionShell({required this.userId, super.key});

  final String userId;

  @override
  State<SessionShell> createState() => _SessionShellState();
}

final class _SessionShellState extends State<SessionShell> {
  // One module object for the life of the shell. A rebuild does not make
  // another one.
  late final Module _module = sessionModule(widget.userId);

  @override
  Widget build(BuildContext context) {
    return ScopeHost(
      module: _module,
      // Each route of this `Navigator` is below the host of the session scope.
      child: Navigator(
        onGenerateRoute: (_) =>
            MaterialPageRoute<void>(builder: (_) => const HomePage()),
      ),
    );
  }
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
                  builder: (_) => ScopeHost(
                    module: editorModule,
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
