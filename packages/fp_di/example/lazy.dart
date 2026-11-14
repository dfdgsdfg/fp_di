// A lazy value: created on the first force(), released with its owner.
//
// `lazy()` reads the keys at activation, so they stay tracked, and runs the
// steps on the first `force()`. Concurrent first calls share one creation.
// The module publishes the service that holds the `Lazy`, not the `Lazy`
// itself, so only that service knows that the report is lazy. When a nearer
// scope publishes a new database, the owner activates again: the old report
// is released and the new service builds its report from the new value.
import 'package:fp_di/fp_di.dart';

final class Database {
  const Database(this.name);

  final String name;
}

final class Report {
  Report(this.database) {
    print('  report built on ${database.name}');
  }

  final Database database;

  void close() => print('  report released');
}

/// The service that readers read. It forces the report inside, so a
/// reader never sees whether the report is lazy.
final class Reports {
  Reports(this._report);

  final Lazy<Report> _report;

  bool get built => _report.isCreated;

  Future<Report> current() async => await _report.force();
}

Component<Database> database(String name) => Component<Database>(
  dependency: Dependency<Database>(create: () => Database(name)),
);

/// The report is expensive, so it is built only when someone asks for it.
final reports = Component<Reports>(
  dependency: Dependency1<Database, Report>(
    create: Report.new,
    dispose: (report) => report.close(),
  ).lazy().map(Reports.new),
);

Future<void> main() async {
  final app = Scope(module: Module(components: [database('main')]));
  // A nearer scope that publishes another database later.
  final replica = app.child(module: Module(components: [database('replica')]));
  final screen = replica.child(module: Module(components: [reports]));

  print('initialize');
  await app.initialize();
  await screen.initialize();
  final first = screen.get<Reports>();
  print('  built: ${first.built}');

  print('ask twice at once');
  final built = await Future.wait([first.current(), first.current()]);
  print('  same report: ${identical(built[0], built[1])}');

  print('a nearer database appears');
  await replica.initialize();
  try {
    await first.current();
  } on DisposedLazyException {
    print('  the old service is released');
  }
  final second = screen.get<Reports>();
  print('  new service built: ${second.built}');
  await second.current();

  print('dispose');
  await app.dispose();
}
