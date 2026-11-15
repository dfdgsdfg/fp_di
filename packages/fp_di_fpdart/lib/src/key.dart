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

  @override
  bool operator ==(Object other) =>
      other is DiKey<Object?> && other.type == type && other.name == name;

  @override
  int get hashCode => Object.hash(T, name);

  @override
  String toString() => name == null ? 'DiKey<$T>' : 'DiKey<$T>($name)';
}
