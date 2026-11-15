// A component that needs the effect of another component: a token key.
//
// `run` starts components that share no key at the same time. The keys are
// the only order. Sometimes one component needs the effect of another. A
// crash reporter, for example, hooks into a global logger. Then the logger
// publishes a token key, and the crash reporter reads it. The need is then
// part of the graph. The crash reporter starts after the token, and the
// runtime releases it before the logger. Its release still finds the logger.
//
// Differences from the fp_di version:
//
// - A component always publishes a value. The package has no
//   `Component.effect`. The crash reporter publishes a small object that no
//   component reads.
// - `Dependency.require<LoggingReady>().mapTask(...)` replaces `Dependency1`.
//   `mapTask` waits for the install.
//
// Run: dart run packages/fp_di_fpdart/example/token_key.dart
import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';

/// Global state outside every graph, like the handlers of a logging
/// framework.
final handlers = <String>[];

/// A handler that installs itself into [handlers]. It stands for real I/O,
/// so it prints when it installs and when it is removed.
abstract base class Handler {
  Handler(this.name);

  final String name;

  /// Installs the handler after [ms] milliseconds. It reports whether
  /// [needs] was installed first.
  Future<void> install({required int ms, String? needs}) async {
    await Future<void>.delayed(Duration(milliseconds: ms));
    final ready = needs == null || handlers.contains(needs);
    print('  $name installed${ready ? '' : ', but $needs is missing'}');
    handlers.add(name);
  }

  /// Removes the handler. It reports whether [needs] was still installed.
  void uninstall({String? needs}) {
    final ready = needs == null || handlers.contains(needs);
    print('  $name removed${ready ? '' : ', but $needs is already gone'}');
    handlers.remove(name);
  }
}

final class Logging extends Handler {
  Logging() : super('logging');
}

final class CrashReporting extends Handler {
  CrashReporting() : super('crashReporting');
}

Future<Logging> installLogging() async {
  final logging = Logging();
  await logging.install(ms: 50);
  return logging;
}

/// Without a token: no key connects the two components.
final looseLogging = Component<Logging>(
  debugLabel: 'logging',
  dependency: Dependency<Logging>(
    create: installLogging,
    dispose: (logging) => logging.uninstall(),
  ),
);

Future<CrashReporting> installLooseReporter() async {
  final reporting = CrashReporting();
  await reporting.install(ms: 10, needs: 'logging');
  return reporting;
}

final looseCrashReporting = Component<CrashReporting>(
  debugLabel: 'crashReporting',
  dependency: Dependency<CrashReporting>(
    create: installLooseReporter,
    dispose: (reporting) => reporting.uninstall(),
  ),
);

/// A token that says the logger is installed. It carries no data.
final class LoggingReady {
  const LoggingReady();
}

/// The first step installs and owns the logger. The second step publishes
/// the token.
final logging = Component<LoggingReady>(
  debugLabel: 'logging',
  dependency: Dependency<Logging>(
    create: installLogging,
    dispose: (logging) => logging.uninstall(),
  ).map<LoggingReady>((_) => const LoggingReady()),
);

/// Reads the token, so it starts after the logger. The runtime releases it
/// before the logger.
final crashReporting = Component<CrashReporting>(
  debugLabel: 'crashReporting',
  dependency: Dependency.require<LoggingReady>().mapTask<CrashReporting>(
    (_) => Task(() async {
      final reporting = CrashReporting();
      await reporting.install(ms: 10, needs: 'logging');
      return reporting;
    }),
    dispose: (reporting) => reporting.uninstall(needs: 'logging'),
  ),
);

/// Runs a scope and disposes it. It prints the cause of each failure.
Future<void> runAndDispose(Scope scope) async {
  final started = await scope.run();
  started.match((cause) => print(cause.prettyPrint()), (_) {});
  print('dispose');
  final stopped = await scope.dispose();
  stopped.match((cause) => print(cause.prettyPrint()), (_) {});
}

Future<void> main() async {
  print('no token: both start at once, and the faster one runs first');
  await runAndDispose(Scope(components: [looseLogging, looseCrashReporting]));
  print('  handlers: $handlers');

  print('a token key: the reader waits for the token');
  // Declared in any order: the crash reporter waits for the key it reads.
  await runAndDispose(Scope(components: [crashReporting, logging]));
  print('  handlers: $handlers');
}
