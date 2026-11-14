// One scope for the whole application.
//
// The application initializes its scope before `runApp` and publishes it with
// `ScopeProvider.fixed`. The scope lives as long as the application, so the
// fixed constructor is safe. A widget reads a value with `context.di<T>()`.
import 'package:flutter/material.dart';
import 'package:fp_di/fp_di.dart';
import 'package:fp_di_flutter/fp_di_flutter.dart';

final class Config {
  const Config(this.userName);
  final String userName;
}

final class Greeter {
  const Greeter(this.config);
  final Config config;
  String greet() => 'Hello, ${config.userName}';
}

final appModule = Module(
  components: [
    Component<Config>.value(value: const Config('fp_di')),
    Component<Greeter>(
      dependency: Dependency1<Config, Greeter>(create: Greeter.new),
    ),
  ],
  debugLabel: 'app',
);

Future<void> main() async {
  final app = await Scope(module: appModule).initialize();
  runApp(ExampleApp(scope: app));
}

final class ExampleApp extends StatelessWidget {
  const ExampleApp({required this.scope, super.key});

  final Scope scope;

  @override
  Widget build(BuildContext context) {
    return ScopeProvider.fixed(
      scope: scope,
      child: const MaterialApp(home: GreetingPage()),
    );
  }
}

final class GreetingPage extends StatelessWidget {
  const GreetingPage({super.key});

  @override
  Widget build(BuildContext context) {
    // A non-listening read. This widget does not rebuild for the scope.
    final greeter = context.di<Greeter>();
    return Scaffold(body: Center(child: Text(greeter.greet())));
  }
}
