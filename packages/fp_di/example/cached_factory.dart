// A cached factory: one value per id, released with the factory.
//
// A plain factory returns a new value on each call, and the caller owns it.
// A cached factory keeps its values, so the cache must have an owner. Here a
// component owns the cache and publishes only its lookup function. The cache
// lives as long as one activation: a new publisher of a key that the cache
// reads releases the cached values and builds a new, empty cache.
import 'package:fp_di/fp_di.dart';

final class Database {
  const Database(this.name);

  final String name;
}

final class RowView {
  RowView(this.database, this.id) {
    print('  row $id on ${database.name}');
  }

  final Database database;
  final String id;

  void close() => print('  row $id on ${database.name} released');
}

/// The values of one activation, by id.
final class RowViewCache {
  RowViewCache(this._database);

  final Database _database;
  final _views = <String, RowView>{};
  var _closed = false;

  /// The view of [id]: the cached one, or a new one on the first call.
  RowView view(String id) {
    // A reader that kept the function of an old activation must not fill a
    // cache that nothing releases.
    if (_closed) throw StateError('The cache is released.');
    return _views.putIfAbsent(id, () => RowView(_database, id));
  }

  void close() {
    _closed = true;
    for (final view in _views.values) {
      view.close();
    }
    _views.clear();
  }
}

/// The published type states a factory, not a cache.
typedef RowViewFactory = RowView Function(String id);

Component<Database> database(String name) =>
    Component<Database>.value(value: Database(name));

/// The first step owns the cache. The second step publishes its lookup.
final rowViewFactory = Component<RowViewFactory>(
  dependency: Dependency1<Database, RowViewCache>(
    create: RowViewCache.new,
    dispose: (cache) => cache.close(),
  ).map<RowViewFactory>((cache) => cache.view),
);

Future<void> main() async {
  final app = Scope(module: Module(components: [database('main')]));
  // A nearer scope that publishes another database later.
  final replica = app.child(module: Module(components: [database('replica')]));
  final feature = replica.child(module: Module(components: [rowViewFactory]));

  print('initialize');
  await app.initialize();
  await feature.initialize();
  final view = feature.get<RowViewFactory>();
  final first = view('42');
  print('  same id, same value: ${identical(first, view('42'))}');
  print('  other id, other value: ${!identical(first, view('7'))}');

  print('a nearer database appears');
  await replica.initialize();
  try {
    view('42');
  } on StateError {
    print('  the old factory is released');
  }
  final next = feature.get<RowViewFactory>();
  print('  a new cache: ${!identical(first, next('42'))}');

  print('dispose');
  await app.dispose();
}
