// The activation of the components of one scope runs concurrently: independent
// components overlap, a component starts when the components that it reads
// committed, and a failure with components in flight settles them first.
import 'dart:async';
import 'dart:math';

import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

DiKey<int> _k(String name) => DiKey<int>(name: name);

/// Collects the node changes that a listener of [scope] sees. Each call of the
/// listener compares `scope.state` with the value that the last call kept.
final class _Changes {
  _Changes(this.scope) : _last = scope.state {
    rightOf(scope.addListener(_onChange));
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

int? _maybe(Scope scope, String name) =>
    scope.getOption<int>(key: _k(name)).toNullable();

/// An asynchronous component. It logs `start`, waits for [gate] or [delay],
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
    dependency: sum.mapTask<int>((v) => Task(() => up(v)), dispose: down),
    debugLabel: name,
    key: _k(name),
  );
}

/// An activation failure whose error is a `StateError` with [message].
Matcher _failedWith(String message) => isA<ActivationFailure>().having(
  (f) => f.error,
  'error',
  isA<StateError>().having((e) => e.message, 'message', message),
);

void main() {
  group('concurrent activation', () {
    test('independent members overlap instead of adding up', () async {
      // from: module_concurrency_test.dart: independent members overlap
      // instead of adding up
      final log = <String>[];
      const delay = Duration(milliseconds: 100);
      final di = Scope(
        components: [
          for (var i = 0; i < 5; i++) _member('m$i', log, delay: delay),
        ],
      );
      final watch = Stopwatch()..start();
      rightOf(await di.run());
      watch.stop();
      // Five sequential components would take 500 ms or more.
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(95));
      expect(watch.elapsedMilliseconds, lessThan(350));
      expect(log.take(5), [for (var i = 0; i < 5; i++) 'start m$i']);
      expect([for (final m in di.nodes) m.isActive], everyElement(true));
      rightOf(await di.dispose());
    });

    test('every independent member starts before any finishes', () async {
      // from: module_concurrency_test.dart: every independent member starts
      // before any finishes
      final log = <String>[];
      final gate = Completer<void>();
      final di = Scope(
        components: [
          for (var i = 0; i < 4; i++) _member('m$i', log, gate: gate.future),
        ],
      );
      final pending = di.run();
      await _settle();
      expect(log, ['start m0', 'start m1', 'start m2', 'start m3']);
      expect(_maybe(di, 'm0'), isNull, reason: 'not ready yet');
      gate.complete();
      rightOf(await pending);
      expect(rightOf(di.get<int>(key: _k('m3'))), 1);
      rightOf(await di.dispose());
    });

    test(
      'a chain activates in dependency order for any declaration order',
      () async {
        // from: module_concurrency_test.dart: a chain activates in dependency
        // order for any declaration order
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
            components: [
              for (final name in order)
                _member(
                  name,
                  log,
                  deps: deps[name]!,
                  delay: const Duration(milliseconds: 5),
                ),
            ],
          );
          rightOf(await di.run());
          expect(log, [
            'start a',
            'end a',
            'start b',
            'end b',
            'start c',
            'end c',
          ], reason: '$order');
          expect(rightOf(di.get<int>(key: _k('c'))), 3);
          rightOf(await di.dispose());
        }
      },
    );

    test('a diamond runs its two middle members together', () async {
      // from: module_concurrency_test.dart: a diamond runs its two middle
      // members together
      final log = <String>[];
      final gateB = Completer<void>();
      final gateC = Completer<void>();
      final di = Scope(
        components: [
          _member('d', log, deps: ['b', 'c']),
          _member('b', log, deps: ['a'], gate: gateB.future),
          _member('c', log, deps: ['a'], gate: gateC.future),
          _member('a', log),
        ],
      );
      final pending = di.run();
      await _settle();
      expect(log, ['start a', 'end a', 'start b', 'start c']);
      gateC.complete();
      await _settle();
      expect(log.last, 'end c');
      expect(log, isNot(contains('start d')), reason: 'b has not committed');
      gateB.complete();
      rightOf(await pending);
      expect(log.sublist(log.indexOf('end c')), [
        'end c',
        'end b',
        'start d',
        'end d',
      ]);
      expect(rightOf(di.get<int>(key: _k('d'))), 5);
      rightOf(await di.dispose());
    });

    test(
      'a member is visible once it is ready, before slow siblings',
      () async {
        // from: module_concurrency_test.dart: a member is visible once it is
        // ready, before slow siblings
        final log = <String>[];
        final slow = Completer<void>();
        final di = Scope(
          components: [
            _member('slow', log, gate: slow.future),
            _member('dependent', log, deps: ['fast']),
            _member('fast', log),
          ],
        );
        final changes = _Changes(di);
        List<String> available() => [
          for (final node in changes.commits)
            if (node.key.isSome()) node.key.toNullable().toString(),
        ];
        final pending = di.run();
        await _settle();
        // `fast` and then `dependent` committed while `slow` is in flight.
        expect(_maybe(di, 'fast'), 1);
        expect(_maybe(di, 'dependent'), 2);
        expect(_maybe(di, 'slow'), isNull);
        expect(available(), hasLength(2));
        slow.complete();
        rightOf(await pending);
        expect(available(), hasLength(3));
        expect(
          available().last,
          contains('slow'),
          reason: 'events follow commit order',
        );
        expect(di.nodes.every((m) => m.isActive), isTrue);
        rightOf(await di.dispose());
      },
    );

    test('a duplicate key fails before any member is created', () async {
      // from: module_concurrency_test.dart: a duplicate key fails before any
      // member is created
      final log = <String>[];
      final di = Scope(
        components: [
          _member('x', log),
          _member('y', log),
          _member('x', log, delay: const Duration(milliseconds: 1)),
        ],
      );
      final failure = (leftOf(await di.run())).only;
      expect(
        failure,
        isA<DuplicateKeyFailure>().having((f) => f.key, 'key', _k('x')).having(
          (f) => f.labels,
          'labels',
          ['x', 'x'],
        ),
      );
      expect(log, isEmpty, reason: 'nothing is created');
      expect(di.isInitialized, isFalse);
      rightOf(await di.dispose());
    });

    test(
      'a dormant publisher does not block a dependent that watches it',
      () async {
        // from: module_concurrency_test.dart: a dormant publisher does not
        // block a dependent that watches it
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
          dependency: Dependency.option<int>(key: _k('publisher')).map<int>((
            seen,
          ) {
            log.add('up watcher');
            return seen.getOrElse(() => -1);
          }),
          debugLabel: 'watcher',
        );
        final root = Scope(
          components: [Component<int>.value(value: 5, key: _k('outside'))],
        );
        final di = root.kid(components: [needsOutside, watcher]);
        rightOf(await di.run());
        expect(log, ['up watcher']);
        expect(di.nodes[0].isActive, isFalse);
        expect(rightOf(di.nodes[1].value), -1);

        rightOf(await root.run());
        expect(di.nodes[0].isActive, isTrue);
        // The same operation rebuilds the watcher with the new publisher.
        expect(log, ['up watcher', 'up publisher', 'up watcher']);
        expect(rightOf(di.nodes[1].value), isNot(-1));
        rightOf(await root.dispose());
      },
    );

    test('a cycle among members falls back to declaration order', () async {
      // Each side requires the other, so both wait, and run does not deadlock
      // on the cycle.
      // from: module_concurrency_test.dart: a cycle among members falls back
      // to declaration order
      Component<int> side(String name, String other) => Component<int>(
        dependency: Dependency.require<int>(
          key: _k(other),
        ).map<int>((seen) => seen + 1),
        debugLabel: name,
        key: _k(name),
      );
      final di = Scope(
        components: [side('left', 'right'), side('right', 'left')],
      );
      rightOf(await di.run().timeout(const Duration(seconds: 5)));
      expect([for (final m in di.nodes) m.isActive], [false, false]);
      rightOf(await di.dispose());
    });

    test('an optional cycle among members fails run', () async {
      // Each side reads the other optionally, so creating one side always
      // changes the target of the other: the reads never settle.
      // from: module_concurrency_test.dart: an optional cycle among members
      // fails initialize
      Component<int> side(String name, String other) => Component<int>(
        dependency: Dependency.option<int>(
          key: _k(other),
        ).map<int>((seen) => seen.getOrElse(() => 0) + 1),
        debugLabel: name,
        key: _k(name),
      );
      final di = Scope(
        components: [side('left', 'right'), side('right', 'left')],
      );
      final cause = leftOf(await di.run().timeout(const Duration(seconds: 5)));
      expect(cause.failures.first, isA<UnsettledFailure>());
      expect(di.isInitialized, isFalse);
      rightOf(await di.dispose());
    });
  });

  group('random graphs', () {
    test('dependencies commit before dependents start', () async {
      // from: module_concurrency_test.dart: dependencies commit before
      // dependents start
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
      final di = Scope(components: components);
      rightOf(await di.run());
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
      rightOf(await di.dispose());
    });
  });

  group('token keys', () {
    test('a member that requires a token starts after its publisher', () async {
      // from: module_concurrency_test.dart: a member that requires a token
      // starts after its publisher
      final log = <String>[];
      final gate = Completer<void>();
      final di = Scope(
        components: [
          // Declared first, but it requires the token of `setup`.
          _member('reader', log, deps: ['setup']),
          _member('setup', log, gate: gate.future),
          _member('free', log),
        ],
      );
      final pending = di.run();
      await _settle();
      expect(log, containsAll(['start setup', 'start free']));
      expect(log, isNot(contains('start reader')));
      gate.complete();
      rightOf(await pending);
      expect(
        log.indexOf('start reader'),
        greaterThan(log.indexOf('end setup')),
      );
      rightOf(await di.dispose());
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
        // from: module_concurrency_test.dart: a sibling settles first, then
        // rollback runs in reverse order
        final log = <String>[];
        final slow = Completer<void>();
        final di = Scope(
          components: [
            _member('first', log),
            _member('slow', log, gate: slow.future),
            _member('bad', log, fail: StateError('boom')),
            _member('after', log, deps: ['slow']),
          ],
        );
        final pending = di.run();
        final outcome = pending.then((exit) {
          expect(leftOf(exit).failures.first, _failedWith('boom'));
        });
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
        expect(_maybe(di, 'first'), 1, reason: 'not rolled back yet');

        slow.complete();
        await outcome;
        // No cancellation reaches `slow`: it finishes, then it is torn down.
        expect(log.sublist(5), ['end slow', 'down slow', 'down first']);
        expect(log, isNot(contains('start after')));
        for (final name in ['first', 'slow', 'bad', 'after']) {
          expect(_maybe(di, name), isNull, reason: name);
        }
        rightOf(await di.dispose());
      },
    );

    test(
      'with two failures the first in declaration order is the failure',
      () async {
        // from: module_concurrency_test.dart: with two failures the first in
        // declaration order is rethrown
        final log = <String>[];
        final gate = Completer<void>();
        final di = Scope(
          components: [
            _member('late', log, gate: gate.future, fail: StateError('late')),
            _member('early', log, fail: StateError('early')),
          ],
        );
        final pending = di.run();
        final outcome = pending.then((exit) {
          expect(leftOf(exit).failures.first, _failedWith('late'));
        });
        await _settle();
        gate.complete();
        await outcome;
        expect(log, containsAllInOrder(['fail early', 'fail late']));
        rightOf(await di.dispose());
      },
    );

    test('rollback failures are attached to the first failure', () async {
      // from: module_concurrency_test.dart: rollback failures are attached to
      // the first failure
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
        components: [
          brittle,
          _member('bad', log, fail: StateError('boom')),
        ],
      );
      final cause = leftOf(await di.run());
      expect(cause.failures.first, isA<ActivationFailure>());
      expect(
        (cause.failures.first as ActivationFailure).error,
        isA<StateError>(),
      );
      expect(cause.defects, hasLength(1));
      expect(_maybe(di, 'brittle'), isNull);
      rightOf(await di.dispose());
    });

    test('an operation requested after an await is a '
        'ReentrantMutationFailure', () async {
      // from: module_concurrency_test.dart: a mutation requested after an
      // await raises ReentrantMutationError
      final root = Scope(components: []);
      final other = root.kid();
      final log = <String>[];
      final gate = Completer<void>();
      final reentrant = Component<int>.effect(
        dependency: Dependency<int>(
          create: () async {
            await gate.future;
            final result = await other.run();
            return result.match(
              (cause) => throw cause.failures.first,
              (_) => 0,
            );
          },
        ),
      );
      final di = root.kid(
        components: [
          _member('sibling', log, gate: gate.future),
          reentrant,
        ],
      );
      final pending = di.run();
      final outcome = pending.then((exit) {
        final failure = leftOf(exit).failures.first as ActivationFailure;
        expect(failure.error, isA<ReentrantMutationFailure>());
      });
      await _settle();
      gate.complete();
      await outcome;
      expect(log, ['start sibling', 'end sibling', 'down sibling']);
      rightOf(await root.dispose());
    });
  });

  group('scope dispose after concurrent run', () {
    test('still releases in reverse declaration order', () async {
      // from: module_concurrency_test.dart: still releases in reverse
      // declaration order
      final log = <String>[];
      final di = Scope(
        components: [
          _member('a', log, delay: const Duration(milliseconds: 20)),
          _member('b', log, delay: const Duration(milliseconds: 5)),
          _member('c', log),
        ],
      );
      rightOf(await di.run());
      log.clear();
      rightOf(await di.dispose());
      expect(log, ['down c', 'down b', 'down a']);
    });
  });
}
