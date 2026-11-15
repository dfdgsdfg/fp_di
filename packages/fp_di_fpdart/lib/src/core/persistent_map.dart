// Internal types. The library file does not export this file.
import 'dart:collection';

/// An immutable map with structural sharing: a hash array mapped trie.
///
/// A change builds a new map and shares every part of the trie that it does not
/// touch, so a change costs a time that is logarithmic in the size of the map,
/// where a copy of a `Map` costs a time that is linear. A read is a `Map` read.
/// The map implements `Map` for reading: a call that would change it throws an
/// `UnsupportedError`. [put] and [without] give the changed map.
///
/// The order of the iteration follows the hash of the keys and not the order of
/// the insertion. A caller that needs an order sorts.
final class PMap<K, V> extends UnmodifiableMapBase<K, V> {
  const PMap._(this._root, this._length);

  /// The map without an entry.
  static PMap<K, V> empty<K, V>() => PMap<K, V>._(null, 0);

  /// The map with the entries of [source]. A [PMap] is its own copy.
  factory PMap.from(Map<K, V> source) {
    if (source is PMap<K, V>) return source;
    var result = PMap.empty<K, V>();
    for (final MapEntry(:key, :value) in source.entries) {
      result = result.put(key, value);
    }
    return result;
  }

  final _Node? _root;
  final int _length;

  @override
  int get length => _length;

  @override
  bool get isEmpty => _length == 0;

  @override
  bool get isNotEmpty => _length != 0;

  @override
  V? operator [](Object? key) {
    var node = _root;
    final hash = _hashOf(key);
    var shift = 0;
    while (node != null) {
      switch (node) {
        case _Branch():
          final bit = 1 << ((hash >> shift) & _mask);
          if (node.bitmap & bit == 0) return null;
          final slot = node.slots[_bitCount(node.bitmap & (bit - 1))];
          if (slot is _Leaf) {
            return slot.hash == hash && slot.key == key
                ? slot.value as V?
                : null;
          }
          node = slot as _Node;
          shift += _bits;
        case _Collision():
          if (node.hash != hash) return null;
          for (final leaf in node.leaves) {
            if (leaf.key == key) return leaf.value as V?;
          }
          return null;
      }
    }
    return null;
  }

  @override
  bool containsKey(Object? key) => _contains(key);

  bool _contains(Object? key) {
    for (final leaf in _leavesFor(key)) {
      if (leaf.key == key) return true;
    }
    return false;
  }

  Iterable<_Leaf> _leavesFor(Object? key) sync* {
    var node = _root;
    final hash = _hashOf(key);
    var shift = 0;
    while (node != null) {
      switch (node) {
        case _Branch():
          final bit = 1 << ((hash >> shift) & _mask);
          if (node.bitmap & bit == 0) return;
          final slot = node.slots[_bitCount(node.bitmap & (bit - 1))];
          if (slot is _Leaf) {
            if (slot.hash == hash) yield slot;
            return;
          }
          node = slot as _Node;
          shift += _bits;
        case _Collision():
          if (node.hash == hash) yield* node.leaves;
          return;
      }
    }
  }

  /// The map with [value] at [key].
  PMap<K, V> put(K key, V value) {
    final hash = _hashOf(key);
    final grown = <bool>[false];
    final root = _insert(_root, _Leaf(hash, key, value), 0, grown);
    return PMap<K, V>._(root, grown[0] ? _length + 1 : _length);
  }

  /// The map without [key].
  PMap<K, V> without(Object? key) {
    if (_root == null) return this;
    final removed = <bool>[false];
    final root = _delete(_root, _hashOf(key), key, 0, removed);
    if (!removed[0]) return this;
    return PMap<K, V>._(root, _length - 1);
  }

  /// The keys whose entry differs between this map and [other]: a key that one
  /// map lacks, and a key with values that are not the same object.
  ///
  /// The walk does not enter a part of the trie that both maps share, so the
  /// time depends on the number of changes and not on the size of the maps. The
  /// answer can hold a key whose entry is equal, when the maps differ in shape
  /// around it.
  Iterable<K> changedKeys(PMap<K, V> other) sync* {
    final first = _root;
    final second = other._root;
    if (identical(first, second)) return;
    if (first == null || second == null) {
      yield* keys;
      yield* other.keys;
      return;
    }
    yield* _diff(first, second).map((key) => key as K);
  }

  @override
  Iterable<K> get keys => _walk().map((leaf) => leaf.key as K);

  @override
  Iterable<V> get values => _walk().map((leaf) => leaf.value as V);

  @override
  Iterable<MapEntry<K, V>> get entries =>
      _walk().map((leaf) => MapEntry<K, V>(leaf.key as K, leaf.value as V));

  @override
  void forEach(void Function(K key, V value) action) {
    for (final leaf in _walk()) {
      action(leaf.key as K, leaf.value as V);
    }
  }

  Iterable<_Leaf> _walk() sync* {
    final root = _root;
    if (root == null) return;
    final stack = <_Node>[root];
    while (stack.isNotEmpty) {
      switch (stack.removeLast()) {
        case _Branch(:final slots):
          for (final slot in slots) {
            if (slot is _Leaf) {
              yield slot;
            } else {
              stack.add(slot as _Node);
            }
          }
        case _Collision(:final leaves):
          yield* leaves;
      }
    }
  }
}

Iterable<Object?> _diff(_Node first, _Node second) sync* {
  if (identical(first, second)) return;
  if (first is _Branch && second is _Branch) {
    var bits = first.bitmap | second.bitmap;
    while (bits != 0) {
      final bit = bits & -bits;
      bits &= bits - 1;
      final inFirst = first.bitmap & bit != 0;
      final inSecond = second.bitmap & bit != 0;
      final a = inFirst
          ? first.slots[_bitCount(first.bitmap & (bit - 1))]
          : null;
      final b = inSecond
          ? second.slots[_bitCount(second.bitmap & (bit - 1))]
          : null;
      if (a == null) {
        yield* _keysOf(b!);
      } else if (b == null) {
        yield* _keysOf(a);
      } else if (identical(a, b)) {
        continue;
      } else if (a is _Leaf && b is _Leaf) {
        if (a.hash == b.hash && a.key == b.key) {
          if (!identical(a.value, b.value)) yield a.key;
        } else {
          yield a.key;
          yield b.key;
        }
      } else if (a is _Node && b is _Node) {
        yield* _diff(a, b);
      } else {
        yield* _keysOf(a);
        yield* _keysOf(b);
      }
    }
    return;
  }
  yield* _keysOf(first);
  yield* _keysOf(second);
}

Iterable<Object?> _keysOf(Object slot) sync* {
  if (slot is _Leaf) {
    yield slot.key;
    return;
  }
  final stack = <_Node>[slot as _Node];
  while (stack.isNotEmpty) {
    switch (stack.removeLast()) {
      case _Branch(:final slots):
        for (final inner in slots) {
          if (inner is _Leaf) {
            yield inner.key;
          } else {
            stack.add(inner as _Node);
          }
        }
      case _Collision(:final leaves):
        for (final leaf in leaves) {
          yield leaf.key;
        }
    }
  }
}

const int _bits = 4;
const int _mask = 15;
const int _hashBits = 30;

int _hashOf(Object? key) {
  var h = key.hashCode;
  h ^= h >> 15;
  h *= 0x2c1b3c6d;
  h ^= h >> 12;
  return h & ((1 << _hashBits) - 1);
}

int _bitCount(int value) {
  var v = value - ((value >> 1) & 0x5555);
  v = (v & 0x3333) + ((v >> 2) & 0x3333);
  v = (v + (v >> 4)) & 0x0f0f;
  return (v + (v >> 8)) & 0x1f;
}

sealed class _Node {}

final class _Leaf {
  const _Leaf(this.hash, this.key, this.value);

  final int hash;
  final Object? key;
  final Object? value;
}

final class _Branch extends _Node {
  _Branch(this.bitmap, this.slots);

  final int bitmap;

  /// Each slot is a [_Leaf] or a [_Node].
  final List<Object> slots;
}

final class _Collision extends _Node {
  _Collision(this.hash, this.leaves);

  final int hash;
  final List<_Leaf> leaves;
}

_Node _insert(_Node? node, _Leaf leaf, int shift, List<bool> grown) {
  switch (node) {
    case null:
      grown[0] = true;
      return _Branch(1 << ((leaf.hash >> shift) & _mask), [leaf]);
    case _Collision():
      if (node.hash == leaf.hash) {
        final at = node.leaves.indexWhere((other) => other.key == leaf.key);
        final leaves = [...node.leaves];
        if (at < 0) {
          grown[0] = true;
          leaves.add(leaf);
        } else {
          leaves[at] = leaf;
        }
        return _Collision(node.hash, leaves);
      }
      // A collision node sits in a slot; a branch above it separates the
      // hashes.
      return _insert(
        _Branch(1 << ((node.hash >> shift) & _mask), [node]),
        leaf,
        shift,
        grown,
      );
    case _Branch():
      final bit = 1 << ((leaf.hash >> shift) & _mask);
      final index = _bitCount(node.bitmap & (bit - 1));
      if (node.bitmap & bit == 0) {
        grown[0] = true;
        final slots = [...node.slots]..insert(index, leaf);
        return _Branch(node.bitmap | bit, slots);
      }
      final slot = node.slots[index];
      final Object replaced;
      if (slot is _Leaf) {
        if (slot.hash == leaf.hash && slot.key == leaf.key) {
          replaced = leaf;
        } else if (slot.hash == leaf.hash) {
          grown[0] = true;
          replaced = _Collision(slot.hash, [slot, leaf]);
        } else {
          replaced = _insert(
            _Branch(1 << ((slot.hash >> (shift + _bits)) & _mask), [slot]),
            leaf,
            shift + _bits,
            grown,
          );
        }
      } else {
        replaced = _insert(slot as _Node, leaf, shift + _bits, grown);
      }
      final slots = [...node.slots];
      slots[index] = replaced;
      return _Branch(node.bitmap, slots);
  }
}

_Node? _delete(_Node? node, int hash, Object? key, int shift, List<bool> gone) {
  switch (node) {
    case null:
      return null;
    case _Collision():
      if (node.hash != hash) return node;
      final at = node.leaves.indexWhere((leaf) => leaf.key == key);
      if (at < 0) return node;
      gone[0] = true;
      final leaves = [...node.leaves]..removeAt(at);
      return leaves.isEmpty ? null : _Collision(node.hash, leaves);
    case _Branch():
      final bit = 1 << ((hash >> shift) & _mask);
      if (node.bitmap & bit == 0) return node;
      final index = _bitCount(node.bitmap & (bit - 1));
      final slot = node.slots[index];
      final Object? replaced;
      if (slot is _Leaf) {
        if (slot.hash != hash || slot.key != key) return node;
        gone[0] = true;
        replaced = null;
      } else {
        replaced = _delete(slot as _Node, hash, key, shift + _bits, gone);
        if (!gone[0]) return node;
      }
      final slots = [...node.slots];
      if (replaced == null) {
        slots.removeAt(index);
        final bitmap = node.bitmap & ~bit;
        return slots.isEmpty ? null : _Branch(bitmap, slots);
      }
      slots[index] = replaced;
      return _Branch(node.bitmap, slots);
  }
}
