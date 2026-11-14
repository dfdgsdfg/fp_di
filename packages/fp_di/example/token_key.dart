// A member that needs the effect of another member: a token key.
//
// `initialize` starts members that share no key at the same time, because the
// keys are the only order. When one member needs the effect of another, such
// as a crash reporter that hooks into a global logger, the other member
// publishes a token key and the first member requires it. The need is then
// part of the shape: the reader starts after the token, waits when the token
// is missing, and is disposed before it, so its release still finds the
// logger.
import 'package:fp_di/fp_di.dart';

/// Global state outside every shape, like the handlers of a logging framework.
final handlers = <String>[];

/// Installs [name] into [handlers] after [ms] milliseconds and reports
/// whether [needs] was installed first.
Future<void> install(String name, {required int ms, String? needs}) async {
  await Future<void>.delayed(Duration(milliseconds: ms));
  final ready = needs == null || handlers.contains(needs);
  print('  $name installed${ready ? '' : ', but $needs is missing'}');
  handlers.add(name);
}

/// Removes [name] from [handlers] and reports whether [needs] was still
/// installed.
void uninstall(String name, {String? needs}) {
  final ready = needs == null || handlers.contains(needs);
  print('  $name removed${ready ? '' : ', but $needs is already gone'}');
  handlers.remove(name);
}

/// Without a token: no key connects the two members.
final looseLogging = Component.effect(
  debugLabel: 'logging',
  dependency: Dependency<void>(
    create: () => install('logging', ms: 50),
    dispose: (_) => uninstall('logging'),
  ),
);
final looseCrashReporting = Component.effect(
  debugLabel: 'crashReporting',
  dependency: Dependency<void>(
    create: () => install('crashReporting', ms: 10, needs: 'logging'),
    dispose: (_) => uninstall('crashReporting'),
  ),
);

/// A token that says the logger is installed. It carries no data.
final class LoggingReady {
  const LoggingReady();
}

final logging = Component<LoggingReady>(
  dependency: Dependency<LoggingReady>(
    create: () async {
      await install('logging', ms: 50);
      return const LoggingReady();
    },
    dispose: (_) => uninstall('logging'),
  ),
);

/// Requires the token, so it starts after the logger and is disposed first.
/// It publishes nothing, because no member reads the crash reporter.
final crashReporting = Component.effect(
  debugLabel: 'crashReporting',
  dependency: Dependency1<LoggingReady, void>(
    create: (_) => install('crashReporting', ms: 10, needs: 'logging'),
    dispose: (_) => uninstall('crashReporting', needs: 'logging'),
  ),
);

Future<void> main() async {
  print('no token: both start at once, and the faster one runs first');
  var app = Scope(
    module: Module(components: [looseLogging, looseCrashReporting]),
  );
  await app.initialize();
  await app.dispose();
  print('  handlers: $handlers');

  print('a token key: the reader waits for the token');
  // Declared in any order: the crash reporter waits for the key it requires.
  app = Scope(module: Module(components: [crashReporting, logging]));
  await app.initialize();
  print('dispose');
  await app.dispose();
  print('  handlers: $handlers');
}
