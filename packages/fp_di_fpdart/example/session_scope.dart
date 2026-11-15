// App bootstrap, then a login scope that a logout cleans up.
//
// The root scope holds what the whole app shares. Each login creates a child
// scope with the session components and runs it. The session components read
// app keys through the parent. The app never sees session keys. A logout
// disposes the child scope. Dependents release first, while the values that
// they read are still open. The app scope stays as it was.
//
// Differences from the fp_di version:
//
// - The fake resources print from their own constructors and methods, so the
//   output shows the order of the events without a listener.
// - `child(components: ...)` gives an `Either`: a `Left` for a scope that is
//   disposing. `run()` returns an `Exit`, and `login` returns an
//   `Option<Scope>`.
// - A scope that succeeded does not run again. The second login is a new child
//   scope.
// - `get` is an `Either`. A disposed scope gives a `DisposedScopeFailure`.
//
// Run: dart run packages/fp_di_fpdart/example/session_scope.dart
import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';

// --- App level -------------------------------------------------------------

final class Config {
  const Config(this.baseUrl);
  final String baseUrl;
}

final class HttpClient {
  HttpClient(this.baseUrl) {
    print('  + http client for $baseUrl');
  }

  final String baseUrl;
  bool isOpen = true;

  void close() {
    isOpen = false;
    print('  - http client');
  }
}

final class AuthApi {
  AuthApi(this.http) {
    print('  + auth api');
  }

  final HttpClient http;
}

/// What the whole app shares. It lives as long as the root scope.
final appComponents = <Component<Object?>>[
  Component<Config>.value(value: const Config('https://api.example.com')),
  Component<HttpClient>(
    dependency: Dependency.require<Config>().map<HttpClient>(
      (config) => HttpClient(config.baseUrl),
      dispose: (http) => http.close(),
    ),
  ),
  Component<AuthApi>(
    dependency: Dependency.require<HttpClient>().map<AuthApi>(AuthApi.new),
  ),
];

// --- Session level ---------------------------------------------------------

final class Session {
  const Session(this.userId);
  final String userId;
}

final class AccountDb {
  AccountDb(this.userId) {
    print('  + account db of $userId');
  }

  final String userId;

  void close() => print('  - account db of $userId');
}

final class ProfileRepository {
  ProfileRepository(this.http, this.db) {
    print('  + profile repository of ${db.userId}');
  }

  final HttpClient http;
  final AccountDb db;
}

final class InboxRepository {
  InboxRepository(this.http, this.db) {
    print('  + inbox sync of ${db.userId}');
  }

  final HttpClient http;
  final AccountDb db;

  /// Stops the sync. The client and the database are still open here.
  void close() => print(
    '  - inbox sync of ${db.userId}, '
    'client open: ${http.isOpen}',
  );
}

final class ProfileViewModel {
  ProfileViewModel(this.profiles, this.inbox) {
    print('  + profile view model');
  }

  final ProfileRepository profiles;
  final InboxRepository inbox;

  String get title => 'profile of ${profiles.db.userId}';
}

/// What one login owns. Each login creates a new child scope from this list,
/// so every account gets its own objects.
List<Component<Object?>> sessionComponents(String userId) => [
  Component<Session>.value(value: Session(userId)),
  Component<AccountDb>(
    dependency: Dependency.require<Session>().map<AccountDb>(
      (session) => AccountDb(session.userId),
      dispose: (db) => db.close(),
    ),
  ),
  Component<ProfileRepository>(
    dependency: (
      Dependency.require<HttpClient>(),
      Dependency.require<AccountDb>(),
    ).zip.mapN<ProfileRepository>(ProfileRepository.new),
  ),
  Component<InboxRepository>(
    dependency:
        (
          Dependency.require<HttpClient>(),
          Dependency.require<AccountDb>(),
        ).zip.mapN<InboxRepository>(
          InboxRepository.new,
          // The release can still use the database and the client. They
          // release only after this component.
          dispose: (inbox) => inbox.close(),
        ),
  ),
  Component<ProfileViewModel>(
    dependency: (
      Dependency.require<ProfileRepository>(),
      Dependency.require<InboxRepository>(),
    ).zip.mapN<ProfileViewModel>(ProfileViewModel.new),
  ),
];

/// Logs in: runs a child scope of [app] with the session components.
Future<Option<Scope>> login(Scope app, String userId) async {
  switch (app.child(components: sessionComponents(userId))) {
    case Left(value: final failure):
      print('  login failed: $failure');
      return const None();
    case Right(value: final session):
      final started = await session.run();
      return started.match((cause) {
        print('  login failed:\n${cause.prettyPrint()}');
        return const None();
      }, Some.new);
  }
}

/// Prints how far a scope reads and what it hides.
void inspect(Scope app, Scope session) {
  final title = session.getOption<ProfileViewModel>().map((vm) => vm.title);
  print('  ${title.getOrElse(() => 'no profile')}');
  // The session reads app keys through its parent. The app does not see
  // session keys.
  print(
    '  session sees the client: ${session.getOption<HttpClient>().isSome()}',
  );
  print(
    '  app sees the profile: ${app.getOption<ProfileViewModel>().isSome()}',
  );
}

/// Disposes a scope and prints the cause of a failure.
Future<void> close(Scope scope) async {
  final stopped = await scope.dispose();
  stopped.match((cause) => print(cause.prettyPrint()), (_) {});
}

Future<void> main() async {
  print('bootstrap');
  final app = Scope(components: appComponents);
  switch (await app.run()) {
    case Left(value: final cause):
      print(cause.prettyPrint());
      return;
    case Right():
      break;
  }

  print('login alice');
  switch (await login(app, 'alice')) {
    case Some(value: final alice):
      inspect(app, alice);
      print('logout alice');
      await close(alice);
      print('  session phase: ${alice.phase.name}');
      print('  session reads: ${alice.get<ProfileViewModel>()}');
      print(
        '  client still open: '
        '${app.getOption<HttpClient>().map((http) => http.isOpen)}',
      );
    case None():
      break;
  }

  print('login bob');
  switch (await login(app, 'bob')) {
    case Some(value: final bob):
      inspect(app, bob);
    case None():
      break;
  }

  print('shutdown');
  // Disposing the root disposes the open session scope first.
  await close(app);
}
