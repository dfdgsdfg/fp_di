// App bootstrap, then a login scope that a logout cleans up.
//
// The root scope holds what the whole app shares. Each login declares a child
// scope with the session module and initializes it. The session components read
// app keys through the parent, and the app never sees session keys. A logout
// disposes the child scope: dependents release first, while the values they
// read are still open, and the app scope stays as it was. A listener on the
// root scope prints each component that activates or deactivates.
import 'package:fp_di/fp_di.dart';

/// Returns a listener that prints each component that activates or
/// deactivates. It compares `scope.state` with the value of its last call.
void Function() trace(Scope scope) {
  var last = scope.state;
  return () {
    final now = scope.state;
    for (final (earlier, later) in now.changedSince(last)) {
      if (later != null && later.commits > (earlier?.commits ?? 0)) {
        print('  + ${later.label}');
      }
      if (earlier != null &&
          earlier.phase == NodePhase.deactivating &&
          later?.phase != NodePhase.deactivating) {
        print('  - ${earlier.label}');
      }
    }
    last = now;
  };
}

// --- App level -------------------------------------------------------------

final class Config {
  const Config(this.baseUrl);
  final String baseUrl;
}

final class HttpClient {
  HttpClient(this.baseUrl);
  final String baseUrl;
  bool isOpen = true;
  void close() => isOpen = false;
}

final class AuthApi {
  AuthApi(this.http);
  final HttpClient http;
}

/// What the whole app shares. It lives as long as the root scope.
final appModule = Module(
  components: [
    Component<Config>.value(value: const Config('https://api.example.com')),
    Component<HttpClient>(
      dependency: Dependency1<Config, HttpClient>(
        create: (config) => HttpClient(config.baseUrl),
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

final class AccountDb {
  AccountDb(this.userId);
  final String userId;
}

final class ProfileRepository {
  ProfileRepository(this.http, this.db);
  final HttpClient http;
  final AccountDb db;
}

final class InboxRepository {
  InboxRepository(this.http, this.db);
  final HttpClient http;
  final AccountDb db;

  /// Stops the sync. The client is still open here.
  void close() =>
      print('  inbox sync of ${db.userId} stops, client open: ${http.isOpen}');
}

final class ProfileViewModel {
  ProfileViewModel(this.profiles, this.inbox);
  final ProfileRepository profiles;
  final InboxRepository inbox;
  String get title => 'profile of ${profiles.db.userId}';
}

/// What one login owns. Each login declares it in a new child scope, so
/// every account gets its own objects.
Module sessionModule(String userId) => Module(
  components: [
    Component<Session>.value(value: Session(userId)),
    Component<AccountDb>(
      dependency: Dependency1<Session, AccountDb>(
        create: (session) => AccountDb(session.userId),
      ),
    ),
    Component<ProfileRepository>(
      dependency: Dependency2<HttpClient, AccountDb, ProfileRepository>(
        create: ProfileRepository.new,
      ),
    ),
    Component<InboxRepository>(
      dependency: Dependency2<HttpClient, AccountDb, InboxRepository>(
        create: InboxRepository.new,
        // The release can still use the database and the client: they
        // release only after this component.
        dispose: (inbox) => inbox.close(),
      ),
    ),
    Component<ProfileViewModel>(
      dependency:
          Dependency2<ProfileRepository, InboxRepository, ProfileViewModel>(
            create: ProfileViewModel.new,
          ),
    ),
  ],
  debugLabel: 'session',
);

/// Logs in: a child scope of [app] that declares the session module.
Future<Scope> login(Scope app, String userId) =>
    app.child(module: sessionModule(userId)).initialize();

Future<void> main() async {
  // A debug run serves the DevTools inspector only after this switch.
  Scope.debugInspector = true;
  print('bootstrap');
  final app = Scope(module: appModule);
  app.addListener(trace(app));
  await app.initialize();

  print('login alice');
  final alice = await login(app, 'alice');
  print('  ${alice.get<ProfileViewModel>().title}');
  // The session reads app keys through its parent; the app does not see
  // session keys.
  print('  session sees the client: ${alice.maybeGet<HttpClient>() != null}');
  print('  app sees the profile: ${app.maybeGet<ProfileViewModel>() != null}');

  print('logout alice');
  await alice.dispose();
  print('  client still open: ${app.get<HttpClient>().isOpen}');

  print('login bob');
  final bob = await login(app, 'bob');
  print('  ${bob.get<ProfileViewModel>().title}');

  print('shutdown');
  // Disposing the root disposes the open session scope first.
  await app.dispose();
}
