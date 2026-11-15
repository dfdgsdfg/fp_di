// The cost of a run with many nodes and many observers. The bounds are the
// bounds of fp_di.
import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:test/test.dart';

import 'support.dart';

const _numbers = DiSetKey<int>(name: 'numbers');

/// A strict reader of [_numbers] that publishes the number of its elements.
Component<int> _counter(DiKey<int> key) => Component<int>(
  key: key,
  dependency: Dependency.requireSet<int>(
    key: _numbers,
  ).map((values) => values.length),
);

void main() {
  group('cost', () {
    test('runs a chain of 4000 components with a read of the state at each '
        'transition', () async {
      // from: runtime_state_test.dart: initializes a chain of 4000 members
      // with a read at each transition
      final keys = [
        for (var i = 0; i < 4000; i++) DiKey<int>(name: 'member $i'),
      ];
      // Each component reads the component before it, as the cost fixtures of
      // module_test.dart do.
      final root = Scope(
        components: [
          for (var i = 0; i < 4000; i++)
            Component<int>(
              key: keys[i],
              dependency: i == 0
                  ? Dependency<int>(create: () => 0)
                  : Dependency.require<int>(key: keys[i - 1]).map((_) => i),
            ),
        ],
      );
      var reads = 0;
      ScopeState? last;
      rightOf(
        root.addListener(() {
          last = root.state;
          reads++;
        }),
      );
      final watch = Stopwatch()..start();
      rightOf(await root.run());
      watch.stop();
      expect(last!.phase, ScopePhase.initialized);
      expect(last!.nodeStates, hasLength(4000));
      expect(reads, greaterThanOrEqualTo(8000));
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      rightOf(await root.dispose());
    });

    // from: runtime_state_test.dart: initializes 1000 set contributors and 20
    // strict readers, $name
    for (final (name, reversed) in [
      ('declaration order', false),
      ('reverse order', true),
    ]) {
      test('runs 1000 set contributors and 20 strict readers, $name', () async {
        const contributors = 1000;
        DiKey<int> link(int i) => DiKey<int>(name: 'link $i');
        // A chain of links fixes the order in which the contributions commit.
        Dependency<int> after(int i) {
          final first = reversed ? contributors - 1 : 0;
          return i == first
              ? Dependency<int>(create: () => i)
              : Dependency.require<int>(
                  key: link(reversed ? i + 1 : i - 1),
                ).map((_) => i);
        }

        final root = Scope(
          components: [
            for (var i = 0; i < contributors; i++) ...[
              Component<int>(key: link(i), dependency: after(i)),
              Component<int>.into(
                key: _numbers,
                dependency: Dependency.require<int>(key: link(i)),
              ),
            ],
            for (var i = 0; i < 20; i++)
              _counter(DiKey<int>(name: 'reader $i')),
          ],
        );
        final watch = Stopwatch()..start();
        rightOf(await root.run());
        watch.stop();
        expect(
          rightOf(root.get<int>(key: const DiKey<int>(name: 'reader 0'))),
          1000,
        );
        expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
        rightOf(await root.dispose());
      });
    }
  });
}
