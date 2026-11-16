// The failure value of the runtime and its projections to the public errors.
import 'dart:async';

import 'package:fp_di/fp_di.dart';
import 'package:fp_di/src/core/core_cause.dart';
import 'package:test/test.dart';

final _trace = StackTrace.fromString('trace');

DisposeFailure _die(String owner) =>
    DisposeFailure(owner, StateError(owner), _trace);

CoreFail _fail(Object error) => CoreFail(error, _trace);

List<String> _owners(Iterable<DisposeFailure> failures) => [
  for (final failure in failures) failure.owner,
];

void main() {
  group('the tree', () {
    test('the empty cause is the identity of then and both', () {
      final leaf = _fail('a');
      expect(CoreCause.empty.isEmpty, isTrue);
      expect(CoreCause.empty.then(leaf), same(leaf));
      expect(leaf.then(CoreCause.empty), same(leaf));
      expect(CoreCause.empty.both(leaf), same(leaf));
      expect(leaf.both(CoreCause.empty), same(leaf));
      expect(CoreCause.empty.then(CoreCause.empty).isEmpty, isTrue);
      expect(CoreCause.all([CoreCause.empty, CoreCause.empty]).isEmpty, isTrue);
      expect(CoreCause.empty.leaves, isEmpty);
    });

    test('then and both list the first operand first', () {
      final a = _fail('a');
      final b = _fail('b');
      final c = _fail('c');
      expect(a.then(b).leaves, [a, b]);
      expect(a.both(b).leaves, [a, b]);
      expect(a.then(b.both(c)).leaves, [a, b, c]);
      expect(a.both(b).then(c).leaves, [a, b, c]);
      expect(CoreCause.all([a, b, c]).leaves, [a, b, c]);
      expect(CoreCause.sequence([a, b, c]).leaves, [a, b, c]);
    });

    test('a leaf keeps the object that it holds', () {
      final error = StateError('x');
      final fail = _fail(error);
      expect((fail.then(CoreCause.empty) as CoreFail).error, same(error));
      final exception = ActivationCanceledException();
      final interrupt = CoreInterrupt(exception, _trace);
      expect(interrupt.exception, same(exception));
      final failure = _die('d');
      expect((CoreDie(failure)).failure, same(failure));
    });

    test('a node built by hand with empty operands is empty', () {
      expect(const CoreThen(CoreEmpty(), CoreEmpty()).isEmpty, isTrue);
      expect(const CoreBoth(CoreEmpty(), CoreEmpty()).isEmpty, isTrue);
    });

    test('a long chain walks without recursion', () {
      var cause = CoreCause.empty;
      for (var i = 0; i < 200000; i++) {
        cause = cause.then(CoreDie(_die('$i')));
      }
      expect(cause.disposeFailures, hasLength(200000));
      expect(cause.disposeFailures.first.owner, '0');
      expect(cause.disposeFailures.last.owner, '199999');
    });

    test('dying lists dispose failures in order', () {
      final cause = CoreCause.dying([_die('a'), _die('b')]);
      expect(_owners(cause.disposeFailures), ['a', 'b']);
      expect(CoreCause.dying(const []).isEmpty, isTrue);
    });
  });

  group('helpers', () {
    test('withDisposeFailures keeps the kind of the error', () {
      final extra = [_die('x')];
      expect(CoreCause.withDisposeFailures('e', _trace, const []), 'e');
      final raw = CoreCause.withDisposeFailures('e', _trace, extra);
      expect(raw, isA<ActivationException>());
      expect((raw as ActivationException).cause, 'e');
      expect(raw.stackTrace, same(_trace));
      expect(raw.rollbackFailures, extra);

      final own = ActivationException('c', StackTrace.empty, [_die('r')]);
      final merged =
          CoreCause.withDisposeFailures(own, _trace, extra)
              as ActivationException;
      expect(merged.cause, 'c');
      expect(merged.stackTrace, same(StackTrace.empty));
      expect(_owners(merged.rollbackFailures), ['r', 'x']);

      final canceled = ActivationCanceledException(
        cause: 'c',
        stackTrace: StackTrace.empty,
        rollbackFailures: [_die('r')],
      );
      final mergedCanceled =
          CoreCause.withDisposeFailures(canceled, _trace, extra)
              as ActivationCanceledException;
      expect(mergedCanceled.cause, 'c');
      expect(_owners(mergedCanceled.rollbackFailures), ['r', 'x']);

      final wiring = DependencyCycleError(['a', 'a']);
      final wrapped =
          CoreCause.withDisposeFailures(wiring, _trace, extra)
              as ActivationException;
      expect(wrapped.cause, same(wiring));
    });

    test('disposeFailuresOf reads the rollback failures of an error', () {
      final failures = [_die('r')];
      expect(
        CoreCause.disposeFailuresOf(ActivationException('c', _trace, failures)),
        failures,
      );
      expect(
        CoreCause.disposeFailuresOf(
          ActivationCanceledException(rollbackFailures: failures),
        ),
        failures,
      );
      expect(CoreCause.disposeFailuresOf(StateError('x')), isEmpty);
    });
  });

  group('activationError', () {
    test('a single raw failure is thrown as it is', () {
      final error = StateError('x');
      final projected = _fail(error).activationError();
      expect(projected.error, same(error));
      expect(projected.stackTrace, same(_trace));
    });

    test('a single DiError is thrown as it is', () {
      final error = DependencyCycleError(['a', 'a']);
      expect(_fail(error).activationError().error, same(error));
    });

    test('the first head in the tree is the error', () {
      final first = StateError('first');
      final second = StateError('second');
      final projected = _fail(first).both(_fail(second)).activationError();
      expect(projected.error, same(first));
    });

    test('rollback failures of other heads follow, then dispose failures', () {
      final head = ActivationException('c', _trace, [_die('h')]);
      final other = ActivationException('o', _trace, [_die('o')]);
      final interrupt = ActivationCanceledException(
        rollbackFailures: [_die('i')],
      );
      final cause = CoreCause.all([
        _fail(head),
        _fail(other),
        CoreInterrupt(interrupt, _trace),
      ]).then(CoreCause.dying([_die('d1'), _die('d2')]));
      final error = cause.activationError().error as ActivationException;
      expect(error.cause, 'c');
      expect(_owners(error.rollbackFailures), ['h', 'o', 'i', 'd1', 'd2']);
    });

    test('an interrupt head gives an ActivationCanceledException', () {
      final exception = ActivationCanceledException(
        cause: 'c',
        stackTrace: StackTrace.empty,
        rollbackFailures: [_die('h')],
      );
      final cause = CoreInterrupt(
        exception,
        _trace,
      ).both(_fail(ActivationException('o', _trace, [_die('o')])));
      final projected = cause.activationError();
      final error = projected.error as ActivationCanceledException;
      expect(projected.stackTrace, same(_trace));
      expect(error.cause, 'c');
      expect(_owners(error.rollbackFailures), ['h', 'o']);
    });

    test('an interrupt alone is thrown as it is', () {
      final exception = ActivationCanceledException();
      expect(
        CoreInterrupt(exception, _trace).activationError().error,
        same(exception),
      );
    });

    test('dispose failures wrap a raw error and a DiError', () {
      final raw = _fail('e').then(CoreCause.dying([_die('d')]));
      final rawError = raw.activationError().error as ActivationException;
      expect(rawError.cause, 'e');
      expect(_owners(rawError.rollbackFailures), ['d']);

      final wiring = DependencyCycleError(['a', 'a']);
      final di = _fail(wiring).then(CoreCause.dying([_die('d')]));
      expect(
        (di.activationError().error as ActivationException).cause,
        same(wiring),
      );
    });

    test('dropOthers drops only the rollback failures of the other heads', () {
      final head = ActivationException('c', _trace, [_die('h')]);
      final other = ActivationException('o', _trace, [_die('o')]);
      final cause = _fail(
        head,
      ).both(_fail(other)).then(CoreCause.dying([_die('d')]));
      final error =
          cause.activationError(dropOthers: true).error as ActivationException;
      expect(_owners(error.rollbackFailures), ['h', 'd']);
    });

    test('a cause without a head is a state error', () {
      expect(
        () => CoreCause.dying([_die('d')]).activationError(),
        throwsStateError,
      );
    });
  });

  group('disposeError', () {
    test('success has no error', () {
      expect(CoreCause.empty.disposeError(), isNull);
    });

    test('dispose failures give one DisposeException in order', () {
      final cause = CoreCause.dying([_die('a'), _die('b')]);
      final error = cause.disposeError()!.error as DisposeException;
      expect(_owners(error.disposeFailures), ['a', 'b']);
    });

    test('a fail leaf wins and keeps its stack trace', () {
      final error = StateError('x');
      final cause = CoreCause.dying([_die('a')]).both(_fail(error));
      final projected = cause.disposeError()!;
      expect(projected.error, same(error));
      expect(projected.stackTrace, same(_trace));
    });
  });

  group('reportedError', () {
    test('success reports nothing', () {
      expect(CoreCause.empty.reportedError(), isNull);
    });

    test('a DiException is reported as it is', () {
      final error = ActivationException('c', _trace, [_die('r')]);
      expect(_fail(error).reportedError(), same(error));
    });

    test('a DiError is reported inside an ActivationException', () {
      final error = DependencyCycleError(['a', 'a']);
      final reported = _fail(error).reportedError() as ActivationException;
      expect(reported.cause, same(error));
      expect(reported.stackTrace, same(_trace));
      expect(reported.rollbackFailures, isEmpty);
    });

    test('an interrupt reports only its dispose failures', () {
      expect(
        CoreInterrupt(ActivationCanceledException(), _trace).reportedError(),
        isNull,
      );
      final interrupt = ActivationCanceledException(
        cause: 'c',
        rollbackFailures: [_die('r')],
      );
      final reported =
          CoreInterrupt(interrupt, _trace).reportedError() as DisposeException;
      expect(_owners(reported.disposeFailures), ['r']);
    });

    test('dispose failures without a head give one DisposeException', () {
      final reported =
          CoreCause.dying([_die('a'), _die('b')]).reportedError()
              as DisposeException;
      expect(_owners(reported.disposeFailures), ['a', 'b']);
    });

    test('a head with dispose failures after it keeps them', () {
      final reported =
          _fail(
                ActivationException('c', _trace, [_die('r')]),
              ).then(CoreCause.dying([_die('d')])).reportedError()
              as ActivationException;
      expect(_owners(reported.rollbackFailures), ['r', 'd']);
    });
  });

  group('initialize', () {
    test('the rollback failures of the other failed members attach in '
        'declaration order, not in completion order', () async {
      // The members fail in the order C, B, A. Each one has one rollback
      // failure.
      Component<void> member(String name, int delayMs) => Component.effect(
        dependency:
            Dependency<int>(
              create: () => 1,
              dispose: (_) => throw StateError('$name rollback'),
            ).map<void>((_) async {
              await Future<void>.delayed(Duration(milliseconds: delayMs));
              throw StateError('$name failed');
            }),
        debugLabel: name,
      );
      final scope = Scope(
        module: Module(
          components: [member('A', 90), member('B', 50), member('C', 10)],
        ),
      );
      await expectLater(
        scope.initialize(),
        throwsA(
          isA<ActivationException>()
              .having((e) => '${e.cause}', 'cause', contains('A failed'))
              .having(
                (e) => [for (final f in e.rollbackFailures) '${f.error}'],
                'rollback failures',
                [
                  'Bad state: A rollback',
                  'Bad state: B rollback',
                  'Bad state: C rollback',
                ],
              ),
        ),
      );
      await scope.dispose();
    });
  });
}
