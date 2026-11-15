// A factory: a new value on each call, built from keys that the scope read.
//
// A component publishes a function, and the function type is the key. The
// component reads its keys when the scope runs, and the function keeps the
// values that it read. A parameter is part of the type, so the compiler
// checks `RowView Function(String id)`. The values that a factory returns
// belong to the caller. No `dispose` runs for them.
//
// A child scope reads each key from the nearest scope that publishes it.
// Two feature scopes below read two different databases through the same
// kind of factory.
//
// Differences from the fp_di version:
//
// - The example does not rebuild the factory when a nearer publisher appears.
//   `reactive.dart` shows that rule. Here each feature scope runs after the
//   scopes that publish its database.
// - `Dependency.require<Database>().map(...)` replaces `Dependency1`, and a
//   record `zip` replaces `Dependency2`.
//
// Run: dart run packages/fp_di_fpdart/example/factory.dart
import 'package:fp_di_fpdart/fp_di_fpdart.dart';

final class Database {
  const Database(this.name);

  final String name;
}

final class Dao {
  Dao(this.database) {
    print('  dao on ${database.name}');
  }

  final Database database;
}

final class RowView {
  RowView(this.database, this.id) {
    print('  row $id on ${database.name}');
  }

  final Database database;
  final String id;
}

/// A factory without parameters.
typedef DaoFactory = Dao Function();

/// A factory with a parameter.
typedef RowViewFactory = RowView Function(String id);

Component<Database> database(String name) =>
    Component<Database>.value(value: Database(name));

final daoFactory = Component<DaoFactory>(
  dependency: Dependency.require<Database>().map<DaoFactory>(
    (db) =>
        () => Dao(db),
  ),
);

final rowViewFactory = Component<RowViewFactory>(
  dependency: Dependency.require<Database>().map<RowViewFactory>(
    (db) =>
        (String id) => RowView(db, id),
  ),
);

/// A reader of a factory reads the function like any other value.
final class Screen {
  Screen(DaoFactory newDao, RowViewFactory newRow)
    : first = newDao(),
      second = newDao(),
      row = newRow('42');

  final Dao first;
  final Dao second;
  final RowView row;
}

final screen = Component<Screen>(
  dependency: (
    Dependency.require<DaoFactory>(),
    Dependency.require<RowViewFactory>(),
  ).zip.mapN<Screen>(Screen.new),
);

/// The components of a feature. Each feature scope gets its own copy of the
/// factories, and the factories read the nearest database.
final featureComponents = <Component<Object?>>[
  daoFactory,
  rowViewFactory,
  screen,
];

/// Runs [scope] and prints the cause of a failure.
Future<bool> start(String label, Scope scope) async {
  final started = await scope.run();
  return started.match((cause) {
    print('  $label failed:\n${cause.prettyPrint()}');
    return false;
  }, (_) => true);
}

/// Reads the screen of [scope] and prints what it holds.
void inspect(String label, Scope scope) {
  scope.get<Screen>().match((failure) => print('  $label: $failure'), (value) {
    print(
      '  $label: two calls, two values: '
      '${!identical(value.first, value.second)}',
    );
    print('  $label: the screen reads ${value.row.database.name}');
  });
}

/// A child scope of [parent]. `child` is a `Left` only for a scope that is
/// disposing or disposed, so the example reads it as a bug.
Scope childOf(Scope parent, List<Component<Object?>> components) => parent
    .child(components: components)
    .getOrElse((failure) => throw StateError('$failure'));

Future<void> main() async {
  final app = Scope(components: [database('main')]);
  // A nearer scope that publishes another database.
  final replica = childOf(app, [database('replica')]);
  final onReplica = childOf(replica, featureComponents);
  final onMain = childOf(app, featureComponents);

  print('run');
  if (await start('app', app) &&
      await start('replica', replica) &&
      await start('feature on the replica', onReplica) &&
      await start('feature on the app', onMain)) {
    inspect('replica feature', onReplica);
    inspect('app feature', onMain);
  }

  print('dispose');
  final stopped = await app.dispose();
  stopped.match((cause) => print(cause.prettyPrint()), (_) {});
}
