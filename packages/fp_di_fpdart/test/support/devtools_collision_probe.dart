// The subprocess of the name collision test. It registers one service
// extension name of the inspector as another owner would, for example the
// inspector of `fp_di`. Then it creates a root with the real hooks, and
// prints what the inspector owns and what it skipped as one JSON line.
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fp_di_fpdart/src/runtime/inspector_hooks.dart';

Future<void> main() async {
  Scope.debugInspector = true;
  developer.registerExtension(
    'ext.fp_di.state',
    (method, parameters) async => developer.ServiceExtensionResponse.result(
      jsonEncode({'owner': 'another copy'}),
    ),
  );
  var threw = false;
  Scope? root;
  try {
    root = Scope(components: const []);
    await root.run();
  } on Object {
    threw = true;
  }
  final output = <String, Object?>{
    'threw': threw,
    'owned': InspectorHooks.owned,
    'skipped': InspectorHooks.skipped,
    'phase': root?.phase.name,
  };
  await root?.dispose();
  // ignore: avoid_print
  print(jsonEncode(output));
}
