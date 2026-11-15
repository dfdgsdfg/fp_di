// Prints whether this run has assertions and the stack trace of a hold, for
// dispose_hold_test.dart (V-T-RT-LC-041).

import 'dart:convert';

import 'package:fp_di/fp_di.dart';

Future<void> main() async {
  var asserts = false;
  assert(asserts = true);
  final scope = await Scope(module: Module(components: const [])).initialize();
  final hold = scope.disposeHold(debugLabel: 'probe');
  final trace = scope.openHolds.single.debugStackTrace;
  hold.close();
  await scope.dispose();
  print(jsonEncode({'asserts': asserts, 'trace': trace?.toString()}));
}
