// Configuration validation, with two host policies side by side.
//
// One domain: a configuration check. The validator is an
// `Either<List<ConfigError>, Config>`. It keeps every problem, not only the
// first one. The validator is data. It decides nothing about the lifecycle.
// The host decides what a `Left` means:
//
// a. `mapTaskEither` makes the `Left` an activation failure. The run gives
//    `Fail(ActivationFailure(owner, errors))`. The scope publishes nothing,
//    and the owned steps before the check roll back.
// b. `map` keeps the `Either` as the published value. The scope runs fine. A
//    settings screen reads the value and shows the problems.
//
// Both components own a `ConfigSource` before the check. The source shows
// the rollback of policy a, and the release of policy b.
//
// Run: dart run packages/fp_di_fpdart/example/validation.dart
import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';

const valid = RawConfig(currency: 'EUR', creditLimit: 5000, region: 'eu');
const invalid = RawConfig(currency: 'EURO', creditLimit: 0, region: '');

Future<void> main() async {
  print('a. the Left fails the activation');
  await strictRun('invalid configuration', invalid);
  await strictRun('valid configuration', valid);
  print('b. the Left is the published value');
  await lenientRun('invalid configuration', invalid);
  await lenientRun('valid configuration', valid);
}

String indent(String text) =>
    text.split('\n').map((line) => '      $line').join('\n');

/// Runs a scope with the strict component.
Future<void> strictRun(String label, RawConfig raw) async {
  print('  $label:');
  final scope = Scope(
    components: [
      Component<RawConfig>.value(value: raw),
      strict,
    ],
  );
  final started = await scope.run();
  await started.match(
    (cause) async {
      print('    run fails, phase ${scope.phase.name}:');
      print(indent(cause.prettyPrint()));
      for (final failure in cause.failures) {
        switch (failure) {
          case ActivationFailure(
            :final owner,
            error: final List<ConfigError> errors,
          ):
            print('    $owner reports ${errors.length} problems:');
            for (final error in errors) {
              print('      $error');
            }
          case final other:
            print('    unexpected: ${other.message}');
        }
      }
      print('    published: ${scope.getOption<Config>()}');
    },
    (_) async {
      print('    run succeeds, phase ${scope.phase.name}');
      print('    published: ${scope.getOption<Config>()}');
      await stop(scope);
    },
  );
}

/// Runs a scope with the lenient component, and shows a settings screen.
Future<void> lenientRun(String label, RawConfig raw) async {
  print('  $label:');
  final scope = Scope(
    components: [
      Component<RawConfig>.value(value: raw),
      lenient,
    ],
  );
  final started = await scope.run();
  await started.match(
    (cause) async => print('    run fails: ${cause.prettyPrint()}'),
    (_) async {
      print('    run succeeds, phase ${scope.phase.name}');
      scope.get<Either<List<ConfigError>, Config>>().match(
        (failure) => print('    screen: no settings, ${failure.message}'),
        settingsScreen,
      );
      await stop(scope);
    },
  );
}

/// A settings screen. It shows the problems, or the settings.
void settingsScreen(Either<List<ConfigError>, Config> settings) {
  settings.match((errors) {
    print('    screen: ${errors.length} problems to fix');
    for (final error in errors) {
      print('      $error');
    }
  }, (config) => print('    screen: $config'));
}

/// Disposes a scope and prints a failure, if any.
Future<void> stop(Scope scope) async {
  final stopped = await scope.dispose();
  stopped.match(
    (cause) => print('    dispose fails: ${cause.prettyPrint()}'),
    (_) {},
  );
}

// ---------------------------------------------------------------------------
// The configuration and its validator.
// ---------------------------------------------------------------------------

/// The configuration as it arrives, unchecked.
final class RawConfig {
  const RawConfig({
    required this.currency,
    required this.creditLimit,
    required this.region,
  });

  final String currency;
  final int creditLimit;
  final String region;
}

/// A checked configuration.
final class Config {
  const Config._(this.currency, this.creditLimit, this.region);

  final String currency;
  final int creditLimit;
  final String region;

  @override
  String toString() => 'Config($currency, $creditLimit, $region)';
}

/// One problem of a raw configuration.
final class ConfigError {
  const ConfigError(this.field, this.reason);

  final String field;
  final String reason;

  @override
  String toString() => 'ConfigError($field: $reason)';
}

/// One check of a raw configuration: `Some` problem, or `None`.
typedef ConfigCheck = Option<ConfigError> Function(RawConfig raw);

final List<ConfigCheck> configChecks = [
  (raw) => raw.currency.length == 3
      ? const None()
      : Some(ConfigError('currency', '"${raw.currency}" is not 3 letters')),
  (raw) => raw.creditLimit > 0
      ? const None()
      : Some(ConfigError('creditLimit', '${raw.creditLimit} is not positive')),
  (raw) => raw.region.isNotEmpty
      ? const None()
      : const Some(ConfigError('region', 'is empty')),
];

/// Checks a raw configuration and keeps every problem, so one report shows all
/// that is wrong.
Either<List<ConfigError>, Config> validate(RawConfig raw) {
  final problems = [for (final check in configChecks) ?check(raw).toNullable()];
  return problems.isEmpty
      ? Either.right(Config._(raw.currency, raw.creditLimit, raw.region))
      : Either.left(problems);
}

/// A handle on the source of the configuration. The fake resource prints from
/// its constructor and its `close`.
final class ConfigSource {
  ConfigSource(this.raw) {
    print('    + config source');
  }

  final RawConfig raw;

  void close() => print('    - config source');
}

// ---------------------------------------------------------------------------
// The two host policies.
// ---------------------------------------------------------------------------

/// Policy a: a `Left` of `mapTaskEither` fails the activation. The `Left`
/// value is the `error` of the `ActivationFailure`. The runtime closes the
/// source before the run ends.
final strict = Component<Config>(
  debugLabel: 'config',
  dependency: Dependency.require<RawConfig>()
      .map<ConfigSource>(ConfigSource.new, dispose: (source) => source.close())
      .mapTaskEither<List<ConfigError>, Config>(
        (source) => TaskEither.fromEither(validate(source.raw)),
      ),
);

/// Policy b: `map` keeps the `Either` as the value. The activation succeeds.
/// The scope closes the source at dispose.
final lenient = Component<Either<List<ConfigError>, Config>>(
  debugLabel: 'settings',
  dependency: Dependency.require<RawConfig>()
      .map<ConfigSource>(ConfigSource.new, dispose: (source) => source.close())
      .map<Either<List<ConfigError>, Config>>((source) => validate(source.raw)),
);
