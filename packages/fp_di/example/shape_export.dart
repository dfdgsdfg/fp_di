// A tool script that exports the shape of every variant as JSON and as a
// Mermaid chart.
//
// An application keeps a script like this under `tool/`. It imports the
// application modules and `package:fp_di/tooling.dart`, builds the module of
// each variant, and writes one JSON file and one Mermaid file per variant.
// Nothing is created and no `create` runs. A review diffs the JSON files;
// `jq` or a graph tool reads them. A Markdown host draws the Mermaid text.
//
//   dart run packages/fp_di/example/shape_export.dart            # summary
//   dart run packages/fp_di/example/shape_export.dart build/shape # the files
import 'dart:io';

import 'package:fp_di/fp_di.dart';
import 'package:fp_di/tooling.dart';

// --- Application modules (in an application, imported from lib/) ----------

enum Flavor { dev, prod }

enum Platform { mobile, web }

final class Config {}

final class Http {}

final class Db {}

final class Repo {}

final class Feed {}

final class Debug {}

abstract interface class Startup {}

final class Sync implements Startup {}

final class Push implements Startup {}

const startups = DiSetKey<Startup>(name: 'startup');

/// The boot scope publishes the configuration.
final bootModule = Module(
  components: [Component<Config>.value(value: Config())],
  debugLabel: 'boot',
);

Module appModule(Flavor flavor, Platform platform) => Module(
  components: [
    Component<Http>(
      dependency: Dependency1<Config, Http>(create: (_) => Http()),
    ),
    Component<Db>(dependency: Dependency1<Config, Db>(create: (_) => Db())),
    Component<Repo>(
      dependency: Dependency2<Http, Db, Repo>(create: (_, _) => Repo()),
    ),
    Component<Feed>(dependency: Dependency1<Repo, Feed>(create: (_) => Feed())),
    Component<Startup>.into(
      key: startups,
      dependency: Dependency1<Repo, Startup>(create: (_) => Sync()),
    ),
    if (platform == Platform.mobile)
      Component<Startup>.into(
        key: startups,
        dependency: Dependency<Startup>(create: Push.new),
      ),
    Component<List<Startup>>(
      dependency: Dependency.requireSet(
        key: startups,
      ).map((set) => set.toList()),
    ),
    if (flavor != Flavor.prod)
      Component<Debug>(
        dependency: Dependency.maybe<Feed>().map((_) => Debug()),
      ),
  ],
  debugLabel: '${flavor.name}.${platform.name}',
);

// --- The script ------------------------------------------------------------

void main(List<String> args) {
  final out = args.isEmpty ? null : Directory(args.first);
  out?.createSync(recursive: true);
  var problems = 0;
  for (final flavor in Flavor.values) {
    for (final platform in Platform.values) {
      final module = appModule(flavor, platform);
      final graph = ShapeGraph.of(module, ancestorModules: [bootModule]);
      final name = module.debugLabel!;
      if (out != null) {
        File('${out.path}/$name.json').writeAsStringSync('${graph.toJson()}\n');
        File(
          '${out.path}/$name.mmd',
        ).writeAsStringSync('${graph.toMermaid()}\n');
      }
      final chain = [
        for (final i in graph.longestChain) module.components[i].label,
      ];
      print(
        '$name: ${module.components.length} members, '
        'depth ${graph.depths.fold(0, (a, b) => a > b ? a : b)}, '
        'longest chain ${chain.join(' -> ')}',
      );
      if (graph.undeclared.isNotEmpty || graph.duplicates.isNotEmpty) {
        problems++;
        print(
          '  undeclared ${graph.undeclared}, duplicates ${graph.duplicates}',
        );
      }
    }
  }
  if (out != null) print('wrote ${out.path}/');
  // A check script fails the build on a wiring problem.
  if (problems > 0) exitCode = 1;
}
