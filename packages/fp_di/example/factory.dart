// A factory: a new value on each call, built from tracked keys.
//
// A component publishes a function, and the function type is the key. The
// function reads its keys when the component activates, so a new publisher
// of a key rebuilds the factory and its readers. A parameter is part of the
// type, so `RowView Function(String id)` is checked by the compiler. The
// values that a factory returns belong to the caller: no `dispose` runs for
// them.
import 'package:fp_di/fp_di.dart';

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
  dependency: Dependency1<Database, DaoFactory>(
    create: (db) =>
        () => Dao(db),
  ),
);

final rowViewFactory = Component<RowViewFactory>(
  dependency: Dependency1<Database, RowViewFactory>(
    create: (db) =>
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
  dependency: Dependency2<DaoFactory, RowViewFactory, Screen>(
    create: Screen.new,
  ),
);

Future<void> main() async {
  final app = Scope(module: Module(components: [database('main')]));
  // A nearer scope that publishes another database later.
  final replica = app.child(module: Module(components: [database('replica')]));
  final feature = replica.child(
    module: Module(components: [daoFactory, rowViewFactory, screen]),
  );

  print('initialize');
  await app.initialize();
  await feature.initialize();
  final value = feature.get<Screen>();
  print('  two calls, two values: ${!identical(value.first, value.second)}');

  print('a nearer database appears');
  await replica.initialize();
  print('  the screen reads ${feature.get<Screen>().row.database.name}');

  await app.dispose();
}
