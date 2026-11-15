// What a logout must finish, and what it may drop.
//
// Three scopes nest: the app, the database of a session, and the session.
// Their lifetimes differ, so each gets its own scope:
//
// - app: what the whole app shares.
// - session database: the store of one account. Its writes must land before
//   it closes.
// - session: the live parts of one login, such as a socket and a cache. A
//   logout drops them at once; nothing waits for them.
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
import 'dart:async';

import 'package:fp_di/fp_di.dart';

// --- App level -------------------------------------------------------------

final class HttpClient {
  bool isOpen = true;
  void close() {
    isOpen = false;
    print('  http client closed');
  }
}

final appModule = Module(
  components: [
    Component<HttpClient>(
      dependency: Dependency<HttpClient>(
        create: HttpClient.new,
        dispose: (http) => http.close(),
      ),
    ),
  ],
  debugLabel: 'app',
);

// --- Session database level ------------------------------------------------

/// A store that queues its writes and writes them in a flush.
final class SessionDb {
  SessionDb(this.userId);
  final String userId;
  final List<String> _pending = [];
  final List<String> stored = [];
  bool isOpen = true;

  void write(String row) {
    if (!isOpen) throw StateError('write to a closed database: $row');
    _pending.add(row);
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

Module sessionDbModule(String userId) => Module(
  components: [
    Component<SessionDb>(
      dependency: Dependency<SessionDb>(
        create: () => SessionDb(userId),
        dispose: (db) => db.close(),
      ),
    ),
  ],
  debugLabel: 'session database',
);

// --- Session level ---------------------------------------------------------

/// A live connection. Losing it at a logout costs nothing.
final class Socket {
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
    if (draft.isNotEmpty) db.write('draft: $draft');
    print('  composer saved its draft, database open: ${db.isOpen}');
  }
}

final sessionModule = Module(
  components: [
    Component<Socket>(
      dependency: Dependency<Socket>(
        create: Socket.new,
        dispose: (socket) => socket.close(),
      ),
    ),
    Component<Composer>(
      dependency: Dependency1<SessionDb, Composer>(
        create: Composer.new,
        dispose: (composer) => composer.close(),
      ),
    ),
  ],
  debugLabel: 'session',
);

// --- Work outside the graph ------------------------------------------------

/// An upload that a logout does not cancel. It writes its result to the
/// database when it ends, so it holds the scope of the database until then.
Future<void> upload(Scope dbScope, Duration takes) async {
  // Guarantee 3: the hold delays the disposal of the database scope.
  final hold = dbScope.disposeHold(debugLabel: 'upload');
  try {
    final db = dbScope.get<SessionDb>();
    await Future<void>.delayed(takes);
    db.write('upload done');
    print('  upload wrote its result');
  } finally {
    hold.close();
  }
}

// --- Login and logout ------------------------------------------------------

final class Login {
  Login(this.db, this.session);
  final Scope db;
  final Scope session;
}

Future<Login> login(Scope app, String userId) async {
  final db = await app.child(module: sessionDbModule(userId)).initialize();
  final session = await db.child(module: sessionModule).initialize();
  return Login(db, session);
}

/// Drops the session at once, and gives the database [limit] to finish.
Future<void> logout(Login login, {required Duration limit}) async {
  // The live parts go first; nothing holds them.
  await login.session.dispose();
  // The database waits for its holds, but not longer than the limit.
  await login.db.dispose().timeout(
    limit,
    onTimeout: () {
      print('  the wait ended after $limit: ${login.db.openHolds}');
      return login.db.dispose(ignoreHolds: true);
    },
  );
}

Future<void> main() async {
  final app = await Scope(module: appModule).initialize();
  final errors = app.errors.listen((error) => print('  reported: $error'));

  print('login alice, an upload that ends in time');
  final alice = await login(app, 'alice');
  final aliceDb = alice.db.get<SessionDb>();
  alice.session.get<Composer>().draft = 'hello';
  final aliceUpload = upload(alice.db, const Duration(milliseconds: 50));
  print('logout alice');
  await logout(alice, limit: const Duration(seconds: 1));
  await aliceUpload;
  print('  rows of alice: ${aliceDb.stored}');

  print('login bob, an upload that does not end in time');
  final bob = await login(app, 'bob');
  final bobUpload = upload(bob.db, const Duration(milliseconds: 300));
  print('logout bob');
  await logout(bob, limit: const Duration(milliseconds: 100));
  // The upload ends after the database closed, so its write fails. The
  // limit chose to lose it.
  await bobUpload.catchError((Object error) => print('  upload lost: $error'));

  print('shutdown');
  await app.dispose();
  await errors.cancel();
}
