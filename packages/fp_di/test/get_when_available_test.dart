// Scope.getWhenAvailable (V-T-RT-LC-038): the value of a key once it has one,
// a failure when it can never have one, and no wait inside the runtime.

import 'dart:async';

import 'package:fp_di/fp_di.dart';
import 'package:test/test.dart';

const _a = DiKey<String>(name: 'a');
const _b = DiKey<String>(name: 'b');
const _gone = DiKey<String>(name: 'gone');

/// Publishes [value] under [key].
Component<String> _value(DiKey<String> key, String value) =>
    Component<String>.value(value: value, key: key);

/// Reads [read] and publishes its value with [suffix] under [key].
Component<String> _reader(
  DiKey<String> key,
  DiKey<String> read, {
  String suffix = '!',
  FutureOr<void> Function()? before,
  FutureOr<void> Function(String value)? dispose,
}) => Component<String>(
  dependency: Dependency.require<String>(key: read).map((value) async {
    await before?.call();
    return '$value$suffix';
  }, dispose: dispose),
  key: key,
);

/// Lets pending microtasks and timers run.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

/// Records the outcome of [future] without an unhandled error.
Future<Object?> _outcome(Future<String> future) =>
    future.then<Object?>((value) => value, onError: (Object error) => error);

void main() {
  group('Scope.getWhenAvailable (V-T-RT-LC-038)', () {
    test('completes at once with a value that get returns', () async {
      final scope = Scope(module: Module(components: [_value(_a, 'x')]));
      await scope.initialize();
      expect(await scope.getWhenAvailable<String>(key: _a), 'x');
      await scope.dispose();
    });

    test('waits for the initialize of its own scope', () async {
      final scope = Scope(module: Module(components: [_value(_a, 'x')]));
      final result = _outcome(scope.getWhenAvailable<String>(key: _a));
      await _settle();
      await scope.initialize();
      expect(await result, 'x');
      await scope.dispose();
    });

    test('waits in a child for a parent that is not initialized yet', () async {
      final parent = Scope(module: Module(components: [_value(_a, 'x')]));
      final child = parent.child(module: Module(components: [_reader(_b, _a)]));
      await child.initialize();
      final fromParent = _outcome(child.getWhenAvailable<String>(key: _a));
      final fromChild = _outcome(child.getWhenAvailable<String>(key: _b));
      await _settle();
      expect(child.maybeGet<String>(key: _b), isNull);

      await parent.initialize();
      expect(await fromParent, 'x');
      expect(await fromChild, 'x!');
      await parent.dispose();
    });

    test(
      'fails at once for a key that no scope of the chain declares',
      () async {
        final scope = Scope(module: Module(components: [_value(_a, 'x')]));
        await scope.initialize();
        final error = await _outcome(
          scope.getWhenAvailable<String>(key: _gone),
        );
        expect(
          error,
          isA<UnavailableKeyException>()
              .having((e) => e.key, 'key', _gone)
              .having((e) => e.failedNodeStates, 'failedNodeStates', isEmpty),
        );
        await scope.dispose();
      },
    );

    test('fails with the cause when an automatic activation fails', () async {
      final parent = Scope(module: Module(components: [_value(_a, 'x')]));
      final child = parent.child(
        module: Module(
          components: [
            _reader(_b, _a, before: () => throw StateError('broken')),
          ],
        ),
      );
      final errors = <DiException>[];
      final subscription = parent.errors.listen(errors.add);
      await child.initialize();
      final result = _outcome(child.getWhenAvailable<String>(key: _b));
      await _settle();

      await parent.initialize();
      final error = await result;
      expect(error, isA<UnavailableKeyException>());
      final failed = (error! as UnavailableKeyException).failedNodeStates;
      expect(failed, hasLength(1));
      expect(failed.single.key, _b);
      expect(failed.single.activationException?.cause, isA<StateError>());
      await subscription.cancel();
      await parent.dispose();
    });

    test('keeps waiting through a failed initialize, and completes on a '
        'retry', () async {
      var attempt = 0;
      final scope = Scope(
        module: Module(
          components: [
            _value(_a, 'x'),
            _reader(
              _b,
              _a,
              before: () {
                if (attempt++ == 0) throw StateError('first');
              },
            ),
          ],
        ),
      );
      final result = _outcome(scope.getWhenAvailable<String>(key: _b));
      await expectLater(
        scope.initialize(),
        throwsA(isA<ActivationException>()),
      );
      await _settle();
      var done = false;
      unawaited(result.then((_) => done = true));
      await _settle();
      expect(done, isFalse);

      await scope.initialize();
      expect(await result, 'x!');
      await scope.dispose();
    });

    test('fails when the disposal of the scope is requested first', () async {
      final parent = Scope(module: Module(components: [_value(_a, 'x')]));
      final child = parent.child();
      final result = _outcome(child.getWhenAvailable<String>(key: _a));
      await _settle();
      await child.dispose();
      expect(await result, isA<DisposedScopeError>());

      final late = await _outcome(child.getWhenAvailable<String>(key: _a));
      expect(late, isA<DisposedScopeError>());
      await parent.dispose();
    });

    test('fails when the node of the key is disposed alone', () async {
      final declares = Scope(module: Module(components: [_value(_gone, 'g')]));
      final inner = declares.child(
        module: Module(components: [_reader(_b, _gone)]),
      );
      await inner.initialize();
      final result = _outcome(inner.getWhenAvailable<String>(key: _b));
      await _settle();
      await inner.node(key: _b).dispose();
      expect(
        await result,
        isA<UnavailableKeyException>().having((e) => e.key, 'key', _b),
      );
      await declares.dispose();
    });

    test('fails when the node of the key is in disposeFailed', () async {
      final parent = Scope(
        module: Module(components: [_value(_a, 'x'), _value(_gone, 'g')]),
      );
      final child = parent.child(
        module: Module(
          components: [
            _reader(_b, _gone, dispose: (_) => throw StateError('stuck')),
          ],
        ),
      );
      final errors = <DiException>[];
      final subscription = parent.errors.listen(errors.add);
      await parent.initialize();
      await child.initialize();
      expect(child.get<String>(key: _b), 'g!');

      // Withdraw the key that the node reads: its release fails.
      await parent.node(key: _gone).dispose().catchError((Object _) {});
      await _settle();
      expect(
        child.findNode<String>(key: _b)?.state.phase,
        NodePhase.disposeFailed,
      );
      final error = await _outcome(child.getWhenAvailable<String>(key: _b));
      expect(error, isA<UnavailableKeyException>());
      await subscription.cancel();
      await parent.dispose().catchError((Object _) {});
    });
  });
}
