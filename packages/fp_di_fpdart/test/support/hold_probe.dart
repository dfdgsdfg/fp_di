// Prints whether this run has assertions and the stack trace of a hold, for
// hold_test.dart.
import 'dart:convert';

import 'package:fp_di_fpdart/fp_di_fpdart.dart';

Future<void> main() async {
  var asserts = false;
  assert(asserts = true);
  final scope = Scope(components: []);
  await scope.run();
  final hold = scope
      .disposeHold(debugLabel: 'probe')
      .getOrElse((_) => throw StateError('no hold'));
  final trace = scope.openHolds.single.debugStackTrace;
  hold.close();
  await scope.dispose();
  print(jsonEncode({'asserts': asserts, 'trace': trace?.toString()}));
}
