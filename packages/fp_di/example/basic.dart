// The smallest application: two components in one scope.
//
// A component states the type it publishes. The type is also its key. Its
// Dependency states how the value is created. The repository needs the
// database, so the runtime creates the database first and releases it last,
// whatever the declaration order.
import 'package:fp_di/fp_di.dart';

final class Database {
  Database(this.url) {
    print('  database opened');
  }

  final String url;

  void close() => print('  database closed');
}

final class UserRepository {
  UserRepository(this.database);

  final Database database;
}

/// No input: created on each activation and closed at teardown.
final database = Component<Database>(
  dependency: Dependency<Database>(
    create: () => Database('postgres://local'),
    dispose: (db) => db.close(),
  ),
);

/// One input: the value needs no dispose.
final repository = Component<UserRepository>(
  dependency: Dependency1<Database, UserRepository>(create: UserRepository.new),
);

Future<void> main() async {
  // Declared in any order. Nothing is created yet.
  final app = Scope(module: Module(components: [repository, database]));

  // Dispose in `finally`, so a failure after `initialize` still releases
  // what the scope created.
  try {
    print('initialize');
    await app.initialize();
    print('  repository reads ${app.get<UserRepository>().database.url}');
  } finally {
    // The repository goes first, while the database is still open.
    print('dispose');
    await app.dispose();
  }
}
