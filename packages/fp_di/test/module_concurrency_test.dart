import 'dart:async';
import 'dart:math';

import 'package:fp_di/fp_di.dart';
import 'package:test/test.dart';

DiKey<int> _k(String name) => DiKey<int>(name: name);

/// Collects the node changes that a listener of [scope] sees. Each call of the
/// listener compares `scope.state` with the value that the last call kept.
final class _Changes {
  _Changes(this.scope) : _last = scope.state {
    scope.addListener(_onChange);
  }

  final Scope scope;
  ScopeState _last;

  /// The (earlier, later) pairs of every changed node, in call order.
  final pairs = <(NodeState?, NodeState?)>[];

  void _onChange() {
    final now = scope.state;
    pairs.addAll(now.changedSince(_last));
    _last = now;
  }

  /// The states in which a node committed an activation.
  List<NodeState> get commits => [
    for (final (earlier, later) in pairs)
      if (later != null && later.commits > (earlier?.commits ?? 0)) later,
  ];
}

/// Lets every ready microtask and zero-delay timer run.
Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// An asynchronous member. It logs `start`, waits for [gate] or [delay],
/// and publishes [name] built from [deps], then logs `end`. Its release logs
/// `down`.
Component<int> _member(
  String name,
  List<String> log, {
  List<String> deps = const [],
  Future<void>? gate,
  Duration delay = Duration.zero,
  Object? fail,
}) {
  Future<int> up(int sum) async {
    log.add('start $name');
    await (gate ?? Future<void>.delayed(delay));
    if (fail != null) {
      log.add('fail $name');
      throw fail;
    }
    log.add('end $name');
    return sum + 1;
  }

  void down(int _) => log.add('down $name');
  if (deps.isEmpty) {
    return Component<int>(
      dependency: Dependency<int>(create: () => up(0), dispose: down),
      debugLabel: name,
      key: _k(name),
    );
  }
  final sum = deps
      .map((dep) => Dependency.require<int>(key: _k(dep)))
      .reduce((left, right) => (left, right).zip.map((v) => v.$1 + v.$2));
  return Component<int>(
    dependency: sum.map(up, dispose: down),
    debugLabel: name,
    key: _k(name),
  );
}

/// An activation failure whose cause is a `StateError` with [message].
Matcher _failedWith(String message) => isA<ActivationException>().having(
  (e) => e.cause,
  'cause',
  isA<StateError>().having((e) => e.message, 'message', message),
);

void main() {
  group('concurrent activation', () {
    test('independent members overlap instead of adding up', () async {
      final log = <String>[];
      const delay = Duration(milliseconds: 100);
      final di = Scope(
        module: Module(
          components: [
            for (var i = 0; i < 5; i++) _member('m$i', log, delay: delay),
          ],
        ),
      );
      final watch = Stopwatch()..start();
      await di.initialize();
      watch.stop();
      // Five sequential members would take 500 ms or more.
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(95));
      expect(watch.elapsedMilliseconds, lessThan(350));
      // ignore: avoid_print
      print(
        '5 x 100 ms members initialized in ${watch.elapsedMilliseconds} ms',
      );
      expect(log.take(5), [for (var i = 0; i < 5; i++) 'start m$i']);
      expect([for (final m in di.nodes) m.isActive], everyElement(true));
      await di.dispose();
    });

    test('every independent member starts before any finishes', () async {
      final log = <String>[];
      final gate = Completer<void>();
      final di = Scope(
        module: Module(
          components: [
            for (var i = 0; i < 4; i++) _member('m$i', log, gate: gate.future),
          ],
        ),
      );
      final pending = di.initialize();
      await _settle();
      expect(log, ['start m0', 'start m1', 'start m2', 'start m3']);
      expect(di.maybeGet(key: _k('m0')), isNull, reason: 'not ready yet');
      gate.complete();
      await pending;
      expect(di.get(key: _k('m3')), 1);
      await di.dispose();
    });

    test(
      'a chain activates in dependency order for any declaration order',
      () async {
        final orders = <List<String>>[
          ['a', 'b', 'c'],
          ['a', 'c', 'b'],
          ['b', 'a', 'c'],
          ['b', 'c', 'a'],
          ['c', 'a', 'b'],
          ['c', 'b', 'a'],
        ];
        const deps = {
          'a': <String>[],
          'b': ['a'],
          'c': ['b'],
        };
        for (final order in orders) {
          final log = <String>[];
          final di = Scope(
            module: Module(
              components: [
                for (final name in order)
                  _member(
                    name,
                    log,
                    deps: deps[name]!,
                    delay: const Duration(milliseconds: 5),
                  ),
              ],
            ),
          );
          await di.initialize();
          expect(log, [
            'start a',
            'end a',
            'start b',
            'end b',
            'start c',
            'end c',
          ], reason: '$order');
          expect(di.get(key: _k('c')), 3);
          await di.dispose();
        }
      },
    );

    test('a diamond runs its two middle members together', () async {
      final log = <String>[];
      final gateB = Completer<void>();
      final gateC = Completer<void>();
      final di = Scope(
        module: Module(
          components: [
            _member('d', log, deps: ['b', 'c']),
            _member('b', log, deps: ['a'], gate: gateB.future),
            _member('c', log, deps: ['a'], gate: gateC.future),
            _member('a', log),
          ],
        ),
      );
      final pending = di.initialize();
      await _settle();
      expect(log, ['start a', 'end a', 'start b', 'start c']);
      gateC.complete();
      await _settle();
      expect(log.last, 'end c');
      expect(log, isNot(contains('start d')), reason: 'b has not committed');
      gateB.complete();
      await pending;
      expect(log.sublist(log.indexOf('end c')), [
        'end c',
        'end b',
        'start d',
        'end d',
      ]);
      expect(di.get(key: _k('d')), 5);
      await di.dispose();
    });

    test(
      'a member is visible once it is ready, before slow siblings',
      () async {
        final log = <String>[];
        final slow = Completer<void>();
        final di = Scope(
          module: Module(
            components: [
              _member('slow', log, gate: slow.future),
              _member('dependent', log, deps: ['fast']),
              _member('fast', log),
            ],
          ),
        );
        final changes = _Changes(di);
        List<String> available() => [
          for (final node in changes.commits)
            if (node.key != null) node.key.toString(),
        ];
        final pending = di.initialize();
        await _settle();
        // `fast` and then `dependent` committed while `slow` is in flight.
        expect(di.maybeGet(key: _k('fast')), 1);
        expect(di.maybeGet(key: _k('dependent')), 2);
        expect(di.maybeGet(key: _k('slow')), isNull);
        expect(available(), hasLength(2));
        slow.complete();
        await pending;
        expect(available(), hasLength(3));
        expect(
          available().last,
          contains('slow'),
          reason: 'events follow commit order',
        );
        expect(di.nodes.every((m) => m.isActive), isTrue);
        await di.dispose();
      },
    );

    test('a duplicate key fails before any member is created', () async {
      final log = <String>[];
      final di = Scope(
        module: Module(
          components: [
            _member('x', log),
            _member('y', log),
            _member('x', log, delay: const Duration(milliseconds: 1)),
          ],
        ),
      );
      final error = await di.initialize().then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );
      expect(
        error,
        isA<DuplicateKeyError>().having((e) => e.key, 'key', _k('x')).having(
          (e) => e.labels,
          'labels',
          ['x', 'x'],
        ),
      );
      expect(log, isEmpty, reason: 'nothing is created');
      expect(di.isInitialized, isFalse);
      await di.dispose();
    });

    test(
      'a dormant publisher does not block a dependent that watches it',
      () async {
        final log = <String>[];
        final needsOutside = Component<int>(
          dependency: Dependency.require<int>(key: _k('outside')).map<int>((_) {
            log.add('up publisher');
            return 1;
          }),
          debugLabel: 'publisher',
          key: _k('publisher'),
        );
        final watcher = Component<int>.effect(
          dependency: Dependency.maybe<int>(key: _k('publisher')).map<int>((
            seen,
          ) {
            log.add('up watcher');
            return seen ?? -1;
          }),
          debugLabel: 'watcher',
        );
        final root = Scope(
          module: Module(
            components: [Component.value(value: 5, key: _k('outside'))],
          ),
        );
        final di = root.child(
          module: Module(components: [needsOutside, watcher]),
        );
        await di.initialize();
        expect(log, ['up watcher']);
        expect(di.nodes[0].isActive, isFalse);
        expect(di.nodes[1].value, -1);

        await root.initialize();
        expect(di.nodes[0].isActive, isTrue);
        // The same mutation rebuilds the watcher with the new publisher.
        expect(log, ['up watcher', 'up publisher', 'up watcher']);
        expect(di.nodes[1].value, isNot(-1));
        await root.dispose();
      },
    );

    test('a cycle among members falls back to declaration order', () async {
      // Each side requires the other, so both wait, and initialize does not
      // deadlock on the cycle.
      Component<int> side(String name, String other) => Component<int>(
        dependency: Dependency.require<int>(
          key: _k(other),
        ).map<int>((seen) => seen + 1),
        debugLabel: name,
        key: _k(name),
      );
      final di = Scope(
        module: Module(
          components: [side('left', 'right'), side('right', 'left')],
        ),
      );
      await di.initialize().timeout(const Duration(seconds: 5));
      expect([for (final m in di.nodes) m.isActive], [false, false]);
      await di.dispose();
    });

    test('an optional cycle among members fails initialize', () async {
      // Each side reads the other optionally, so creating one side always
      // changes the target of the other: the reads never settle.
      Component<int> side(String name, String other) => Component<int>(
        dependency: Dependency.maybe<int>(
          key: _k(other),
        ).map<int>((seen) => (seen ?? 0) + 1),
        debugLabel: name,
        key: _k(name),
      );
      final di = Scope(
        module: Module(
          components: [side('left', 'right'), side('right', 'left')],
        ),
      );
      await expectLater(
        di.initialize().timeout(const Duration(seconds: 5)),
        throwsA(isA<DependencyCycleError>()),
      );
      expect(di.isInitialized, isFalse);
      await di.dispose();
    });
  });

  group('random graphs', () {
    test('dependencies commit before dependents start', () async {
      final random = Random(7);
      const count = 150;
      final deps = <int, List<String>>{
        for (var i = 0; i < count; i++)
          i: [
            for (var j = 0; j < i; j++)
              if (random.nextInt(count) < 3) 'n$j',
          ],
      };
      final log = <String>[];
      final components = [
        for (var i = 0; i < count; i++)
          _member(
            'n$i',
            log,
            deps: deps[i]!,
            delay: Duration(milliseconds: random.nextInt(3)),
          ),
      ]..shuffle(random);
      final di = Scope(module: Module(components: components));
      await di.initialize();
      expect(di.nodes.every((m) => m.isActive), isTrue);
      for (var i = 0; i < count; i++) {
        for (final dep in deps[i]!) {
          expect(
            log.indexOf('end $dep'),
            lessThan(log.indexOf('start n$i')),
            reason: 'n$i after $dep',
          );
        }
      }
      await di.dispose();
    });
  });

  group('token keys', () {
    test('a member that requires a token starts after its publisher', () async {
      final log = <String>[];
      final gate = Completer<void>();
      final di = Scope(
        module: Module(
          components: [
            // Declared first, but it requires the token of `setup`.
            _member('reader', log, deps: ['setup']),
            _member('setup', log, gate: gate.future),
            _member('free', log),
          ],
        ),
      );
      final pending = di.initialize();
      await _settle();
      expect(log, containsAll(['start setup', 'start free']));
      expect(log, isNot(contains('start reader')));
      gate.complete();
      await pending;
      expect(
        log.indexOf('start reader'),
        greaterThan(log.indexOf('end setup')),
      );
      await di.dispose();
      expect(
        log.indexOf('down reader'),
        lessThan(log.indexOf('down setup')),
        reason: 'teardown disposes the reader of a token first',
      );
    });
  });

  group('failure with members in flight', () {
    test(
      'a sibling settles first, then rollback runs in reverse order',
      () async {
        final log = <String>[];
        final slow = Completer<void>();
        final di = Scope(
          module: Module(
            components: [
              _member('first', log),
              _member('slow', log, gate: slow.future),
              _member('bad', log, fail: StateError('boom')),
              _member('after', log, deps: ['slow']),
            ],
          ),
        );
        final pending = di.initialize();
        final outcome = expectLater(pending, throwsA(_failedWith('boom')));
        await _settle();
        // The failure is known, but the sibling is still in flight, so nothing
        // is torn down and no new member starts.
        expect(log, [
          'start first',
          'start slow',
          'start bad',
          'end first',
          'fail bad',
        ]);
        expect(di.maybeGet(key: _k('first')), 1, reason: 'not rolled back yet');

        slow.complete();
        await outcome;
        // No cancellation reaches `slow`: it finishes, then it is torn down.
        expect(log.sublist(5), ['end slow', 'down slow', 'down first']);
        expect(log, isNot(contains('start after')));
        for (final name in ['first', 'slow', 'bad', 'after']) {
          expect(di.maybeGet(key: _k(name)), isNull, reason: name);
        }
        await di.dispose();
      },
    );

    test(
      'with two failures the first in declaration order is rethrown',
      () async {
        final log = <String>[];
        final gate = Completer<void>();
        final di = Scope(
          module: Module(
            components: [
              _member('late', log, gate: gate.future, fail: StateError('late')),
              _member('early', log, fail: StateError('early')),
            ],
          ),
        );
        final pending = di.initialize();
        final outcome = expectLater(pending, throwsA(_failedWith('late')));
        await _settle();
        gate.complete();
        await outcome;
        expect(log, containsAllInOrder(['fail early', 'fail late']));
        await di.dispose();
      },
    );

    test('rollback failures are attached to the first failure', () async {
      final log = <String>[];
      final brittle = Component<int>(
        dependency: Dependency<int>(
          create: () async {
            await Future<void>.delayed(Duration.zero);
            return 1;
          },
          dispose: (_) => throw StateError('cleanup'),
        ),
        debugLabel: 'brittle',
        key: _k('brittle'),
      );
      final di = Scope(
        module: Module(
          components: [
            brittle,
            _member('bad', log, fail: StateError('boom')),
          ],
        ),
      );
      await expectLater(
        di.initialize(),
        throwsA(
          isA<ActivationException>()
              .having((e) => e.cause, 'cause', isA<StateError>())
              .having((e) => e.rollbackFailures, 'failures', hasLength(1)),
        ),
      );
      expect(di.maybeGet(key: _k('brittle')), isNull);
      await di.dispose();
    });

    test(
      'a mutation requested after an await raises ReentrantMutationError',
      () async {
        final root = Scope();
        final other = root.child();
        final log = <String>[];
        final gate = Completer<void>();
        final reentrant = Component<int>.effect(
          dependency: Dependency<int>(
            create: () async {
              await gate.future;
              await other.initialize();
              return 0;
            },
          ),
        );
        final di = root.child(
          module: Module(
            components: [
              _member('sibling', log, gate: gate.future),
              reentrant,
            ],
          ),
        );
        final pending = di.initialize();
        final outcome = expectLater(
          pending,
          throwsA(isA<ReentrantMutationError>()),
        );
        await _settle();
        gate.complete();
        await outcome;
        expect(log, ['start sibling', 'end sibling', 'down sibling']);
        await root.dispose();
      },
    );
  });

  group('scope dispose after concurrent initialize', () {
    test('still releases in reverse declaration order', () async {
      final log = <String>[];
      final di = Scope(
        module: Module(
          components: [
            _member('a', log, delay: const Duration(milliseconds: 20)),
            _member('b', log, delay: const Duration(milliseconds: 5)),
            _member('c', log),
          ],
        ),
      );
      await di.initialize();
      log.clear();
      await di.dispose();
      expect(log, ['down c', 'down b', 'down a']);
    });
  });
}
