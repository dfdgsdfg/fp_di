import 'package:fpdart/fpdart.dart';

/// The identity of a published value: a type and an optional name.
///
/// Two keys are equal when their types and their names are equal. A scope
/// publishes at most one value for each key.
final class DiKey<T> {
  /// Creates the key of type [T] with an optional [name].
  ///
  /// Use a [name] to publish two values of one type.
  const DiKey({this.name});

  /// The optional name that tells two keys of one type apart.
  final String? name;

  /// The type of the value that the key identifies.
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
      other.type == type &&
      other.name == name;

  @override
  int get hashCode => Object.hash(T, name);

  @override
  String toString() => name == null ? 'DiKey<$T>' : 'DiKey<$T>($name)';
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
