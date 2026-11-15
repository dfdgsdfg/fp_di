// The failure of an automatic activation: the node keeps the cause that
// `errors` reported, and the cause keeps the error and its stack trace.
import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

const _base = DiKey<int>(name: 'base');

/// A child scope that reads `base` of its parent and runs [step].
Scope _readerChild(Scope parent, int Function(int) step) => parent.kid(
  components: [
    Component<int>.effect(
      debugLabel: 'reader',
      dependency: Dependency.require<int>(key: _base).map<int>(step),
    ),
  ],
);

StackTrace? _stackOf(Cause<DiFailure> cause) => cause.fold<StackTrace?>(
  empty: () => null,
  fail: (_, stackTrace) => stackTrace,
  die: (_, stackTrace) => stackTrace,
  interrupt: (stackTrace) => stackTrace,
  then: (first, second) => first ?? second,
  both: (left, right) => left ?? right,
);

void main() {
  test(
    'the node keeps the cause and the stack trace of a failure object',
    () async {
      // from: observation_test.dart: keeps the cause and the stack trace of a
      // DiException
      const thrown = UnavailableKeyFailure(DiKey<String>(name: 'text'));
      final di = Scope(
        components: [Component<int>.value(value: 1, key: _base)],
      );
      final errors = <Cause<DiFailure>>[];
      final subscription = di.errors.listen(errors.add);
      final child = _readerChild(di, (_) => throw thrown);
      rightOf(await child.run());
      rightOf(await di.run());

      // `errors` reports the cause, and the node keeps the same object.
      final reported = errors.single;
      final kept = child.nodes.single.activationFailure.toNullable()!;
      expect(kept, same(reported));
      final failure = kept.failures.single as ActivationFailure;
      expect(failure.error, same(thrown));
      expect('${_stackOf(kept)}', contains('activation_failure_test.dart'));
      await subscription.cancel();
      rightOf(await di.dispose());
    },
  );

  test(
    'the node keeps the cause of another failure object as its error',
    () async {
      // from: observation_test.dart: keeps the cause of a DiError in its own
      // object
      const thrown = DisposedScopeFailure('get');
      final di = Scope(
        components: [Component<int>.value(value: 1, key: _base)],
      );
      final errors = <Cause<DiFailure>>[];
      final subscription = di.errors.listen(errors.add);
      final child = _readerChild(di, (_) => throw thrown);
      rightOf(await child.run());
      rightOf(await di.run());

      // A thrown failure is an `ActivationFailure` of its own: the error of the
      // failure is the thrown object, in `errors` and in the node.
      final reported = errors.single.failures.single as ActivationFailure;
      final kept =
          child.nodes.single.activationFailure.toNullable()!.failures.single
              as ActivationFailure;
      expect(reported.error, same(thrown));
      expect(kept.error, same(thrown));
      expect(kept, same(reported));
      await subscription.cancel();
      rightOf(await di.dispose());
    },
  );
}
