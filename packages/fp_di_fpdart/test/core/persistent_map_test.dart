import 'dart:math';

import 'package:fp_di_fpdart/src/core/persistent_map.dart';
import 'package:test/test.dart';

/// A key whose hash is [hash], to force collisions.
final class _Key {
  const _Key(this.id, this.hash);

  final int id;
  final int hash;

  @override
  bool operator ==(Object other) => other is _Key && other.id == id;

  @override
  int get hashCode => hash;
}

void main() {
  test('an empty map has no entry', () {
    final map = PMap.empty<int, String>();
    expect(map, isEmpty);
    expect(map[1], isNull);
    expect(map.containsKey(1), isFalse);
    expect(map.keys, isEmpty);
  });

  test('put and without give new maps and keep the old ones', () {
    final one = PMap.empty<int, String>().put(1, 'a');
    final two = one.put(2, 'b');
    final without = two.without(1);
    expect(one.length, 1);
    expect(two.length, 2);
    expect(without.length, 1);
    expect(one[2], isNull);
    expect(two[1], 'a');
    expect(without[1], isNull);
    expect(without[2], 'b');
    expect(one.put(1, 'c')[1], 'c');
    expect(one.put(1, 'c').length, 1);
    expect(identical(one.without(9), one), isTrue);
  });

  test('a stored null value is a key', () {
    final map = PMap.empty<int, String?>().put(1, null);
    expect(map.containsKey(1), isTrue);
    expect(map.containsKey(2), isFalse);
    expect(map.length, 1);
  });

  test('it behaves as a Map under random operations', () {
    final random = Random(3);
    final model = <int, int>{};
    var map = PMap.empty<int, int>();
    for (var i = 0; i < 20000; i++) {
      final key = random.nextInt(2000);
      if (random.nextInt(3) == 0) {
        model.remove(key);
        map = map.without(key);
      } else {
        model[key] = i;
        map = map.put(key, i);
      }
      if (i % 997 == 0) {
        expect(map.length, model.length);
        expect({for (final e in map.entries) e.key: e.value}, model);
      }
    }
    expect(map.length, model.length);
    for (var key = 0; key < 2000; key++) {
      expect(map[key], model[key], reason: '$key');
      expect(map.containsKey(key), model.containsKey(key));
    }
    expect(map.keys.toSet(), model.keys.toSet());
    expect(map.values.length, model.length);
  });

  test('keys with one hash are kept apart', () {
    var map = PMap.empty<_Key, int>();
    for (var i = 0; i < 20; i++) {
      map = map.put(_Key(i, 7), i);
    }
    map = map.put(_Key(100, 8), 100);
    expect(map.length, 21);
    for (var i = 0; i < 20; i++) {
      expect(map[_Key(i, 7)], i);
    }
    expect(map[_Key(100, 8)], 100);
    final smaller = map.without(_Key(3, 7)).without(_Key(4, 7));
    expect(smaller.length, 19);
    expect(smaller[_Key(3, 7)], isNull);
    expect(smaller[_Key(5, 7)], 5);
    expect(map[_Key(3, 7)], 3);
    expect(map.put(_Key(5, 7), 55)[_Key(5, 7)], 55);
    expect(map.put(_Key(5, 7), 55).length, 21);
  });

  test('it rejects a change as a Map', () {
    final map = PMap.empty<int, int>().put(1, 1);
    expect(() => map[2] = 2, throwsUnsupportedError);
    expect(map.clear, throwsUnsupportedError);
    expect(() => map.remove(1), throwsUnsupportedError);
  });

  test('from copies a Map and keeps a PMap', () {
    final map = PMap.from({1: 'a', 2: 'b'});
    expect(map, {1: 'a', 2: 'b'});
    expect(identical(PMap.from(map), map), isTrue);
  });

  test('a change of a large map costs far less than a copy', () {
    var map = PMap.empty<int, int>();
    for (var i = 0; i < 100000; i++) {
      map = map.put(i, i);
    }
    final watch = Stopwatch()..start();
    var next = map;
    for (var i = 0; i < 20000; i++) {
      next = next.put(i, -i);
    }
    watch.stop();
    expect(next[5], -5);
    expect(map[5], 5);
    // Twenty thousand copies of 100000 entries would take minutes.
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });
}
