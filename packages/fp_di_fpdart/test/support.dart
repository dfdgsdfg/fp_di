import 'dart:async';

import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

const intKey = DiKey<int>(name: 'int');
const textKey = DiKey<String>(name: 'text');
const flagKey = DiKey<bool>(name: 'flag');

/// The `Left` value, or a test failure.
L leftOf<L, R>(Either<L, R> either) => either.match(
  (left) => left,
  (right) => throw TestFailure('Expected a Left, got Right($right)'),
);

/// The `Right` value, or a test failure.
R rightOf<L, R>(Either<L, R> either) => either.match(
  (left) => throw TestFailure('Expected a Right, got Left($left)'),
  (right) => right,
);

/// A component of [value] that logs its creation and its disposal.
Component<T> logged<T>(
  String name,
  T value,
  List<String> log, {
  DiKey<T>? key,
  Object? failDispose,
}) => Component<T>(
  key: key,
  debugLabel: name,
  dependency: Dependency<T>(
    create: () {
      log.add('create $name');
      return value;
    },
    dispose: (_) {
      log.add('dispose $name');
      if (failDispose != null) throw failDispose;
    },
  ),
);

/// A dependency that reads [read] and logs its creation and its disposal.
Component<T> loggedReading<T>(
  String name,
  Dependency<Object?> read,
  T value,
  List<String> log, {
  DiKey<T>? key,
  Object? failDispose,
}) => Component<T>(
  key: key,
  debugLabel: name,
  dependency: read.map<T>(
    (_) {
      log.add('create $name');
      return value;
    },
    dispose: (_) {
      log.add('dispose $name');
      if (failDispose != null) throw failDispose;
    },
  ),
);

/// The only typed error of a cause, or a test failure.
extension CauseTest<E> on Cause<E> {
  /// The single typed error of the cause.
  E get only => failures.single;
}

/// Runs a scope that must fail, and returns the cause.
Future<Cause<DiFailure>> causeOfRun(Scope scope) async =>
    leftOf(await scope.run());

/// Runs a scope that must fail, and returns the first typed failure.
Future<DiFailure> failureOfRun(Scope scope) async =>
    (await causeOfRun(scope)).failures.first;

/// The text of the dispose failures in a cause, such as `a: failed`.
List<String> disposeFailuresOf(Cause<Object?> cause) => [
  for (final defect in cause.defects) '$defect',
];

/// A short pause that lets other futures run.
Future<void> pause([int milliseconds = 5]) =>
    Future<void>.delayed(Duration(milliseconds: milliseconds));
