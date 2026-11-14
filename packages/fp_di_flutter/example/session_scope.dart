// A session scope that a login creates and a logout disposes.
//
// Every route is below one `Navigator`, so no widget subtree is the session.
// One `ScopeProvider` at the root publishes the current scope instead: the
// session scope while a user is logged in, and the app scope otherwise.
//
// `AppScopes` holds the current scope as a `ValueListenable<Scope>`. A
// lookup reads its value at the moment of the call. A logout therefore
// changes the value first and disposes the session scope after that. No
// widget reads the disposed scope, also before the next frame.
//
// The change does not make a session key available. `Shell` listens to the
// same holder and removes the home page in the frame of the change, before
// the home page rebuilds. No build therefore reads a session key after the
// logout. A callback of the home page that runs before that frame and reads
// a session key still gets an `UnavailableKeyException`.
import 'package:flutter/material.dart';
import 'package:fp_di/fp_di.dart';
import 'package:fp_di_flutter/fp_di_flutter.dart';

// --- App level -------------------------------------------------------------

final class HttpClient {
  bool isOpen = true;
  void close() => isOpen = false;
}

final class AuthApi {
  const AuthApi(this.http);
  final HttpClient http;
  String get status => http.isOpen ? 'ready' : 'closed';
}

/// What the whole application shares.
final appModule = Module(
  components: [
    Component<HttpClient>(
      dependency: Dependency<HttpClient>(
        create: HttpClient.new,
        dispose: (http) => http.close(),
      ),
    ),
    Component<AuthApi>(
      dependency: Dependency1<HttpClient, AuthApi>(create: AuthApi.new),
    ),
  ],
  debugLabel: 'app',
);

// --- Session level ---------------------------------------------------------

final class Session {
  const Session(this.userId);
  final String userId;
}

final class ProfileRepository {
  ProfileRepository(this.http, this.session);
  final HttpClient http;
  final Session session;
  bool isOpen = true;
  String get title => 'profile of ${session.userId}';
  void close() => isOpen = false;
}

/// What one login owns. It reads `HttpClient` from the app scope.
Module sessionModule(String userId) => Module(
  components: [
    Component<Session>.value(value: Session(userId)),
    Component<ProfileRepository>(
      dependency: Dependency2<HttpClient, Session, ProfileRepository>(
        create: ProfileRepository.new,
        dispose: (profiles) => profiles.close(),
      ),
    ),
  ],
  debugLabel: 'session',
);

// --- The holder of the current scope ---------------------------------------

/// Holds the scope that the widgets read: the session scope while a user is
/// logged in, and the app scope otherwise.
///
/// Code outside the widget tree reads the same scope with `scopes.value`.
final class AppScopes extends ValueNotifier<Scope> {
  AppScopes(this.app) : super(app);

  final Scope app;
  Scope? _session;
  bool _loggingIn = false;

  bool get hasSession => _session != null;

  Future<void> login(String userId) async {
    // A second call during the first one would create a second session scope.
    if (_session != null || _loggingIn) return;
    _loggingIn = true;
    try {
      final session = app.child(module: sessionModule(userId));
      await session.initialize();
      _session = session;
      value = session;
    } finally {
      _loggingIn = false;
    }
  }

  Future<void> logout() async {
    final session = _session;
    if (session == null) return;
    _session = null;
    // Change the value first. A scope answers no read from the moment its
    // disposal starts, not even for a key of the app scope.
    value = app;
    await session.dispose();
  }
}

Future<void> main() async {
  final app = await Scope(module: appModule).initialize();
  runApp(SessionApp(scopes: AppScopes(app)));
}

// --- Widgets ---------------------------------------------------------------

final class SessionApp extends StatelessWidget {
  const SessionApp({required this.scopes, super.key});

  final AppScopes scopes;

  @override
  Widget build(BuildContext context) {
    return ScopeProvider.listenable(
      scope: scopes,
      child: MaterialApp(home: Shell(scopes: scopes)),
    );
  }
}

/// Shows the home page only while a session exists.
final class Shell extends StatelessWidget {
  const Shell({required this.scopes, super.key});

  final AppScopes scopes;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Scope>(
      valueListenable: scopes,
      builder: (context, _, _) => scopes.hasSession
          ? HomePage(onLogout: scopes.logout)
          : LoginPage(onLogin: () => scopes.login('ada')),
    );
  }
}

final class LoginPage extends StatelessWidget {
  const LoginPage({required this.onLogin, super.key});

  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) {
    // An app key. The app scope answers it with or without a session.
    final auth = context.di<AuthApi>();
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('auth: ${auth.status}'),
            TextButton(onPressed: onLogin, child: const Text('Log in')),
          ],
        ),
      ),
    );
  }
}

final class HomePage extends StatelessWidget {
  const HomePage({required this.onLogout, super.key});

  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    // A session key and an app key, both through the session scope. The
    // watching read makes the logout mark this widget for a rebuild. `Shell`
    // is above it and removes it first, so that rebuild never runs.
    final profiles = context.watchDi<ProfileRepository>();
    final auth = context.di<AuthApi>();
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(profiles.title),
            Text('auth: ${auth.status}'),
            TextButton(onPressed: onLogout, child: const Text('Log out')),
          ],
        ),
      ),
    );
  }
}
