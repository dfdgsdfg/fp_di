// Seeing what a scope holds and what it waits for.
//
// `describe()` prints the nodes of a scope and its children. A node reports
// the keys it still misses, and `whenActive` waits until it activates. A key
// that no declaration can publish is an error at `initialize`, so a forgotten
// type argument does not leave a reader waiting forever.
import 'package:fp_di/fp_di.dart';

class Database {}

final class PgDatabase extends Database {}

final class UserRepository {
  UserRepository(this.database);

  final Database database;
}

final database = Component<Database>(
  dependency: Dependency<Database>(create: Database.new),
);

final repository = Component<UserRepository>(
  dependency: Dependency1<Database, UserRepository>(create: UserRepository.new),
);

Future<void> main() async {
  final app = Scope(module: Module(components: [database]));
  final feature = app.child(module: Module(components: [repository]));

  print('before initialize');
  print(feature.describe());

  // The child initializes first, so the repository waits for the app.
  await feature.initialize();
  final node = feature.node(key: DiKey<UserRepository>());
  print('waiting');
  print('  missing: ${node.missing}');
  print(feature.describe());

  final ready = node.whenActive;
  await app.initialize();
  print('active');
  print('  ${(await ready).runtimeType}');
  print(app.describe());
  await app.dispose();

  print('a forgotten type argument');
  final broken = Scope(
    module: Module(
      components: [
        // Without <Database>, Dart infers PgDatabase, and the component
        // publishes DiKey<PgDatabase>.
        Component(dependency: Dependency(create: PgDatabase.new)),
        repository,
      ],
    ),
  );
  try {
    await broken.initialize();
  } on UndeclaredKeyError catch (error) {
    print('  $error');
  }
  await broken.dispose();
}
