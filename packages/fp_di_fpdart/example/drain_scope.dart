// What a logout must finish, and what it may drop.
//
// Three scopes nest: the app, the database of a session, and the session.
// Their lifetimes differ, so each gets its own scope:
//
// - app: what the whole app shares.
// - session database: the store of one account. Its writes must land before
//   it closes.
// - session: the live parts of one login, such as a socket and a composer. A
//   logout drops them at once. Nothing waits for them.
//
// Two guarantees come from the graph:
//
// 1. The dispose function of the database flushes before it closes. The
//    runtime awaits it, and the values that the database reads stay open.
// 2. A component that reads the database releases before it. The composer of
//    the session saves its last draft in its own dispose function, and the
//    database is still open then, also across scopes.
//
// This package has no hold. The fp_di version has a third guarantee: work
// outside the graph holds a scope with `disposeHold`, and a logout bounds the
// wait with a time limit. This example drops that part. Here a disposal never
// waits for work that the graph does not know.
//
// Differences from the fp_di version:
//
// - The dispose of a parent scope disposes the child scopes first. The
//   logout of Bob disposes only the database scope, and the session scope
//   still goes first.
// - `run()` and `dispose()` return an `Exit`. The example handles each one
//   with `match` or `switch`.
//
// Run: dart run packages/fp_di_fpdart/example/drain_scope.dart
import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';

// --- App level -------------------------------------------------------------

final class HttpClient {
  HttpClient() {
    print('  http client opened');
  }

  bool isOpen = true;

  void close() {
    isOpen = false;
    print('  http client closed');
  }
}

final appComponents = <Component<Object?>>[
  Component<HttpClient>(
    dependency: Dependency<HttpClient>(
      create: HttpClient.new,
      dispose: (http) => http.close(),
    ),
  ),
];

// --- Session database level ------------------------------------------------

/// A store that queues its writes and writes them in a flush.
final class SessionDb {
  SessionDb(this.userId) {
    print('  database of $userId opened');
  }

  final String userId;
  final List<String> _pending = [];
  final List<String> stored = [];
  bool isOpen = true;

  /// Queues a row. A closed database rejects the row.
  Either<String, Unit> write(String row) {
    if (!isOpen) return Either.left('write to a closed database: $row');
    _pending.add(row);
    return Either.right(unit);
  }

  Future<void> flush() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    stored.addAll(_pending);
    print('  database of $userId flushed ${_pending.length} rows');
    _pending.clear();
  }

  Future<void> close() async {
    // Guarantee 1: the queued writes land before the store closes.
    await flush();
    isOpen = false;
    print('  database of $userId closed with ${stored.length} rows');
  }
}

List<Component<Object?>> sessionDbComponents(String userId) => [
  Component<SessionDb>(
    dependency: Dependency<SessionDb>(
      create: () => SessionDb(userId),
      dispose: (db) => db.close(),
    ),
  ),
];

// --- Session level ---------------------------------------------------------

/// A live connection. Losing it at a logout costs nothing.
final class Socket {
  Socket() {
    print('  socket opened');
  }

  void close() => print('  socket closed');
}

/// Writes drafts to the database.
final class Composer {
  Composer(this.db);

  final SessionDb db;
  String draft = '';

  /// Guarantee 2: the database releases after its readers, so it is open
  /// here.
  void close() {
    if (draft.isNotEmpty) {
      db.write('draft: $draft').match((error) => print('  $error'), (_) {});
    }
    print('  composer saved its draft, database open: ${db.isOpen}');
  }
}

final sessionComponents = <Component<Object?>>[
  Component<Socket>(
    dependency: Dependency<Socket>(
      create: Socket.new,
      dispose: (socket) => socket.close(),
    ),
  ),
  Component<Composer>(
    dependency: Dependency.require<SessionDb>().map<Composer>(
      Composer.new,
      dispose: (composer) => composer.close(),
    ),
  ),
];

// --- Login and logout ------------------------------------------------------

final class Login {
  Login(this.db, this.session);

  final Scope db;
  final Scope session;
}

/// Runs the database scope, and then the session scope inside it.
Future<Option<Login>> login(Scope app, String userId) async {
  final scopes = app
      .child(components: sessionDbComponents(userId))
      .flatMap(
        (db) => db
            .child(components: sessionComponents)
            .map((session) => (db, session)),
      );
  switch (scopes) {
    case Left(value: final failure):
      print('  login failed: $failure');
      return const None();
    case Right(value: (final db, final session)):
      final started = await TaskEither<Cause<DiFailure>, Scope>(
        db.run,
      ).flatMap((_) => TaskEither<Cause<DiFailure>, Scope>(session.run)).run();
      switch (started) {
        case Left(value: final cause):
          print('  login failed:\n${cause.prettyPrint()}');
          await close(db);
          return const None();
        case Right():
          return Some(Login(db, session));
      }
  }
}

/// Disposes a scope and prints the cause of a failure.
Future<void> close(Scope scope) async {
  final stopped = await scope.dispose();
  stopped.match((cause) => print(cause.prettyPrint()), (_) {});
}

/// Drops the session at once, and then lets the database finish its flush.
Future<void> logout(Login login) async {
  await close(login.session);
  await close(login.db);
}

/// Writes a draft through the composer of a session.
void draft(Login login, String text) {
  if (login.session.getOption<Composer>() case Some(value: final composer)) {
    composer.draft = text;
  }
}

Future<void> main() async {
  final app = Scope(components: appComponents);
  switch (await app.run()) {
    case Left(value: final cause):
      print(cause.prettyPrint());
      return;
    case Right():
      break;
  }

  print('login alice');
  if (await login(app, 'alice') case Some(value: final alice)) {
    final db = alice.db.getOption<SessionDb>();
    draft(alice, 'hello');
    print('logout alice: the session goes first, then the database');
    await logout(alice);
    print('  rows of alice: ${db.map((db) => db.stored)}');
  }

  print('login bob');
  if (await login(app, 'bob') case Some(value: final bob)) {
    final db = bob.db.getOption<SessionDb>();
    draft(bob, 'see you');
    print('logout bob: dispose only the database scope');
    // The database scope disposes its child scope first.
    await close(bob.db);
    print('  session phase: ${bob.session.phase.name}');
    print('  rows of bob: ${db.map((db) => db.stored)}');
  }

  print('shutdown');
  await close(app);
}
