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
// The guarantees come from three places:
//
// 1. The dispose function of the database flushes before it closes. The
//    runtime awaits it, and the values that the database reads stay open.
// 2. A component that reads the database releases before it. The composer of
//    the session saves its last draft in its own dispose function, and the
//    database is still open then, also across scopes.
// 3. Work outside the graph, here an upload that a logout does not cancel,
//    holds the scope of the database with `disposeHold`. The disposal of
//    that scope waits for the hold. The session scope has no hold, so it
//    goes at once.
//
// A logout bounds the wait: after a time limit it disposes the database with
// `ignoreHolds`, and `Scope.errors` reports the holds that it ignored.
//
// Differences from the fp_di version:
//
// - The dispose of a parent scope disposes the child scopes first. The
//   logout of Bob disposes only the database scope, and the session scope
//   still goes first.
// - `run()` and `dispose()` return an `Exit`, and `disposeHold` returns an
//   `Either`. The example handles each one with `match` or `switch`.
// - `Scope.errors` gives a `Cause`. The report of the ignored holds is an
//   `IgnoredHoldsFailure` in that cause.
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

// --- Work outside the graph ------------------------------------------------

/// An upload that a logout does not cancel. It writes its result to the
/// database when it ends, so it holds the scope of the database until then.
Future<void> upload(Scope dbScope, Duration takes) async {
  // Guarantee 3: the hold delays the disposal of the database scope.
  switch (dbScope.disposeHold(debugLabel: 'upload')) {
    case Left(value: final failure):
      print('  upload refused: $failure');
    case Right(value: final hold):
      try {
        final db = dbScope.getOption<SessionDb>();
        await Future<void>.delayed(takes);
        db.match(
          () => print('  upload found no database'),
          (db) => db
              .write('upload done')
              .match(
                (error) => print('  upload lost: $error'),
                (_) => print('  upload wrote its result'),
              ),
        );
      } finally {
        hold.close();
      }
  }
}

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

/// Drops the session at once, and gives the database [limit] to finish.
Future<void> logout(Login login, {required Duration limit}) async {
  // The live parts go first. Nothing holds them.
  await close(login.session);
  // The database waits for its holds, but not longer than the limit.
  final stopped = await login.db.dispose().timeout(
    limit,
    onTimeout: () {
      print('  the wait ended after $limit: ${login.db.openHolds}');
      return login.db.dispose(ignoreHolds: true);
    },
  );
  stopped.match((cause) => print(cause.prettyPrint()), (_) {});
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
  final errors = app.errors.listen(
    (cause) => print('  reported: ${cause.failures.join(', ')}'),
  );

  print('login alice, an upload that ends in time');
  if (await login(app, 'alice') case Some(value: final alice)) {
    final db = alice.db.getOption<SessionDb>();
    draft(alice, 'hello');
    final aliceUpload = upload(alice.db, const Duration(milliseconds: 50));
    print('logout alice');
    await logout(alice, limit: const Duration(seconds: 1));
    await aliceUpload;
    print('  rows of alice: ${db.map((db) => db.stored)}');
  }

  print('login bob, an upload that does not end in time');
  if (await login(app, 'bob') case Some(value: final bob)) {
    final db = bob.db.getOption<SessionDb>();
    draft(bob, 'see you');
    final bobUpload = upload(bob.db, const Duration(milliseconds: 300));
    print('logout bob');
    await logout(bob, limit: const Duration(milliseconds: 100));
    // The upload ends after the database closed, so its write fails. The
    // limit chose to lose it.
    await bobUpload;
    print('  rows of bob: ${db.map((db) => db.stored)}');
  }

  print('shutdown');
  await close(app);
  await errors.cancel();
}
