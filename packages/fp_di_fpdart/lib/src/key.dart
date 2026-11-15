import 'package:fpdart/fpdart.dart';

/// The supertype of every key: a plain [DiKey], a [DiSetKey], and a
/// [DiMapKey].
///
/// A list of missing keys holds this type, because a node can wait for a
/// collection.
abstract interface class DiKeyBase {
  /// The type of the value that the key identifies.
  Type get type;

  /// The name of the key, or `null` for a plain key without a name.
  String? get name;
}

/// The identity of a published value: a type and an optional name.
///
/// Two keys are equal when their types and their names are equal. A scope
/// publishes at most one value for each key.
final class DiKey<T> implements DiKeyBase {
  /// Creates the key of type [T] with an optional [name].
  ///
  /// Use a [name] to publish two values of one type.
  const DiKey({this.name});

  @override
  final String? name;

  @override
  Type get type => T;

  /// The equality typeclass of keys, built on `==`.
  ///
  /// Two keys are equal when their types and their names are equal.
  static final Eq<DiKey<Object?>> eq = Eq.fromUniversalEquals();

  /// The hash typeclass of keys, built on `==` and `hashCode`.
  ///
  /// Equal keys have equal hashes.
  static final Hash<DiKey<Object?>> hash = Hash.fromUniversalHashCode();

  @override
  bool operator ==(Object other) =>
      other is DiKey<Object?> &&
      other is! _EffectKey<Object?> &&
      other is! ContributionKey &&
      other is! DiMapEntryKey<Object?> &&
      other.type == type &&
      other.name == name;

  @override
  int get hashCode => Object.hash(T, name);

  /// Whether the key has no name and its type is a core value type, such as
  /// `int` or `String?`.
  ///
  /// An extension type over a core value type erases to that type at run
  /// time, so two such keys without a name are equal. A scope refuses a
  /// component that publishes or reads such a key: `run` fails with an
  /// [UnnamedKeyFailure].
  bool get needsName => name == null && _coreValueTypes.contains(type);

  /// Whether the key names a type that no lookup can produce.
  ///
  /// `FutureOr<X>` and `Future<X>` arise from the inference of a return type,
  /// never from a deliberate binding. A scope refuses a component that
  /// publishes such a key: `run` fails with an [UnreachableKeyFailure].
  bool get isUnreachable {
    final text = type.toString();
    return text.startsWith('FutureOr<') || text.startsWith('Future<');
  }

  @override
  String toString() => name == null ? 'DiKey<$T>' : 'DiKey<$T>($name)';
}

/// The key of one entry of a [DiMapKey].
///
/// The key is a [DiKey], so a component publishes it and a dependency reads
/// it. The name of the key is the id of the entry. An entry key equals no plain
/// key, and no entry key of another map.
final class DiMapEntryKey<T> extends DiKey<T> {
  DiMapEntryKey._(this.mapKey, String id) : super(name: id);

  /// The map that the entry belongs to.
  final DiMapKey<T> mapKey;

  /// The id of the entry in the map.
  String get id => name!;

  @override
  bool operator ==(Object other) =>
      other is DiMapEntryKey<Object?> &&
      other.type == type &&
      other.name == name &&
      other.mapKey == mapKey;

  @override
  int get hashCode => Object.hash(T, name, mapKey);

  @override
  String toString() => '$mapKey[$name]';
}

/// The key of a collection: the values that components contribute.
///
/// A collection key always has a name. It equals no plain key and no key of
/// the other kind of collection.
sealed class DiCollectionKey<T> implements DiKeyBase {
  /// Creates a collection key with the [name].
  const DiCollectionKey({required String name}) : _name = name;

  final String _name;

  @override
  String get name => _name;

  @override
  Type get type => T;
}

/// The key of a set: each `Component.into` of this key adds one element.
///
/// The set has no id for an element. The elements keep the order of the
/// declarations, and equal values give one element.
final class DiSetKey<T> extends DiCollectionKey<T> {
  /// Creates the key of a set with the [name].
  const DiSetKey({required super.name});

  @override
  bool operator ==(Object other) =>
      other is DiSetKey<Object?> && other.type == type && other.name == name;

  @override
  int get hashCode => Object.hash(DiSetKey, T, name);

  @override
  String toString() => 'DiSetKey<$T>($name)';
}

/// The key of a map from an id to a value: each component that publishes an
/// entry key of this map adds one entry.
///
/// A nearer scope that publishes an entry of the same id shadows the entry of
/// an ancestor, and the entry keeps the position of the first declaration.
final class DiMapKey<T> extends DiCollectionKey<T> {
  /// Creates the key of a map with the [name].
  const DiMapKey({required super.name});

  /// The key of the entry [id] of this map.
  DiMapEntryKey<T> entryKey(String id) => DiMapEntryKey<T>._(this, id);

  @override
  bool operator ==(Object other) =>
      other is DiMapKey<Object?> && other.type == type && other.name == name;

  @override
  int get hashCode => Object.hash(DiMapKey, T, name);

  @override
  String toString() => 'DiMapKey<$T>($name)';
}

/// The key of a component that publishes no key.
///
/// The key equals only itself. It cannot collide with another key, and no code
/// can build a key that equals it.
final class _EffectKey<T> extends DiKey<T> {
  _EffectKey(this.owner);

  /// The label of the component, or `null`.
  final String? owner;

  @override
  bool operator ==(Object other) => identical(this, other);

  @override
  int get hashCode => identityHashCode(this);

  @override
  String toString() => owner == null ? 'effect<$T>' : 'effect($owner)';
}

/// A new key that equals only itself, for a component with the label [owner].
DiKey<T> effectKey<T>(String? owner) => _EffectKey<T>(owner);

/// The key under which one declaration of a set contribution publishes.
///
/// Each declaration of each scope has a key of its own, so every contribution
/// is one binding of one key in one scope. The key never leaves the runtime:
/// a node of a contribution has no key in its state.
final class ContributionKey extends DiKey<Object?> {
  /// Creates the key of one declaration that contributes to [set].
  ContributionKey(this.set);

  /// The set that the declaration contributes to.
  final DiSetKey<Object?> set;

  @override
  Type get type => set.type;

  @override
  bool operator ==(Object other) => identical(this, other);

  @override
  int get hashCode => identityHashCode(this);

  @override
  String toString() => 'contribution to $set';
}

Type _typeOf<T>() => T;

/// The types that a key needs a name for: the core value types and their
/// nullable forms.
final Set<Type> _coreValueTypes = {
  _typeOf<bool>(),
  _typeOf<bool?>(),
  _typeOf<int>(),
  _typeOf<int?>(),
  _typeOf<double>(),
  _typeOf<double?>(),
  _typeOf<num>(),
  _typeOf<num?>(),
  _typeOf<String>(),
  _typeOf<String?>(),
  _typeOf<BigInt>(),
  _typeOf<BigInt?>(),
  _typeOf<DateTime>(),
  _typeOf<DateTime?>(),
  _typeOf<Duration>(),
  _typeOf<Duration?>(),
  _typeOf<Uri>(),
  _typeOf<Uri?>(),
  _typeOf<Symbol>(),
  _typeOf<Symbol?>(),
  _typeOf<Object>(),
  _typeOf<Object?>(),
};
