/// The supertype of every key: the runtime identity of a dependency binding.
///
/// This type has no type argument, so a set of keys of different types, such
/// as `Module.requires`, has this element type. Its subtypes are [DiKey] and
/// the collection keys [DiSetKey] and [DiMapKey]. An entry of a map has the
/// key type [DiMapEntryKey], a subtype of [DiKey].
///
/// {@category Keys}
abstract interface class DiKeyBase {
  /// The Dart type carried by this key.
  Type get type;

  /// An optional name that tells apart several bindings of the same type,
  /// like get_it's `instanceName`.
  String? get name;
}

/// A type-safe dependency key.
///
/// `DiKey<T>()` is the default key for [T]. A [name] tells apart several
/// bindings of the same Dart type, as get_it's `instanceName` does, for
/// example `DiKey<int>(name: 'timeout')`.
///
/// Dart erases an extension type to its representation type at run time, so
/// a key without a name cannot tell `DiKey<PoolSize>()` from `DiKey<int>()`.
/// A key of a core value type therefore needs a name ([needsName]). An
/// extension type states its key once:
///
/// ```dart
/// extension type const PoolSize(int value) implements int {
///   static const key = DiKey<PoolSize>(name: 'PoolSize');
/// }
/// ```
///
/// A [DiMapKey] derives the key of an entry with `entryKey(id)`. That key is a
/// [DiMapEntryKey], a `DiKey` that also carries its map key, so it equals no
/// plain key and no entry of another map key.
///
/// {@category Keys}
final class DiKey<T> implements DiKeyBase {
  /// Creates the key of the type [T], with an optional [name].
  const DiKey({this.name});

  /// The name of this key. For a [DiMapEntryKey], the id of the entry.
  @override
  final String? name;

  @override
  Type get type => T;

  /// Equal to another plain [DiKey] of the same type and name. A
  /// [DiMapEntryKey] and a key of another kind are never equal, even with the
  /// same type and name.
  @override
  bool operator ==(Object other) =>
      other is DiKey &&
      other is! DiMapEntryKey &&
      other.type == T &&
      other.name == name;

  @override
  int get hashCode => Object.hash(T, name);

  /// Whether this key has no name and its type is a core value type, such as
  /// `int` or `String?`. An extension type over a core value type erases to
  /// it, so such a key MUST have a name; the `Component` constructor rejects
  /// it otherwise.
  bool get needsName => name == null && _coreValueTypes.contains(T);

  /// Whether this key names a type that no lookup can produce.
  ///
  /// `FutureOr<X>` and `Future<X>` arise from return-type inference at a
  /// `publish` call site, never from a deliberate binding.
  bool get isUnreachable {
    final type = T.toString();
    return type.startsWith('FutureOr<') || type.startsWith('Future<');
  }

  @override
  String toString() => name == null ? 'DiKey<$T>' : 'DiKey<$T>($name)';
}

/// The key of one entry of a [DiMapKey], created by `DiMapKey.entryKey(id)`.
///
/// It is a [DiKey], so a member publishes it with `Component(key: ...)` and
/// reads it with `Dependency.require(key: ...)`, like a plain key. Its [name]
/// is the [id] of the entry.
///
/// {@category Keys}
final class DiMapEntryKey<T> extends DiKey<T> {
  const DiMapEntryKey._(this.mapKey, String id) : super(name: id);

  /// The map key that this entry belongs to.
  final DiMapKey<T> mapKey;

  /// The id of the entry in its [mapKey].
  String get id => name!;

  /// Equal to another [DiMapEntryKey] of the same type, id, and map key. A
  /// plain [DiKey] is never equal, even with the same type and name.
  @override
  bool operator ==(Object other) =>
      other is DiMapEntryKey &&
      other.type == T &&
      other.name == name &&
      other.mapKey == mapKey;

  @override
  int get hashCode => Object.hash(T, name, mapKey);

  @override
  String toString() => '$mapKey[$name]';
}

/// A key that many members contribute to, read as one value.
///
/// [DiSetKey] collects anonymous contributions into a `Set<T>`. [DiMapKey]
/// collects entries, each published under `entryKey(id)`, into a
/// `Map<String, T>`. A reader sees the contributions of its scope and
/// its ancestors. The key is not a binding: a collection read expands to
/// plain reads of the keys of its contributions.
///
/// {@category Keys}
sealed class DiCollectionKey<T> implements DiKeyBase {
  const DiCollectionKey({required this.name});

  /// The name that tells apart two collections of one element type.
  @override
  final String name;

  /// The element type.
  @override
  Type get type => T;
}

/// A collection of anonymous contributions, read as a `Set<T>`.
///
/// A member contributes with `Component.into(key: ..., dependency: ...)`. A
/// reader reads it with `Dependency.requireSet(key: ...)` or
/// `Dependency.maybeSet(key: ...)`.
/// Equal values of two contributors are one element.
///
/// {@category Keys}
final class DiSetKey<T> extends DiCollectionKey<T> {
  /// Creates the set key of the elements of type [T] with the [name].
  const DiSetKey({required super.name});

  @override
  bool operator ==(Object other) =>
      other is DiSetKey && other.type == T && other.name == name;

  @override
  int get hashCode => Object.hash(DiSetKey, T, name);

  @override
  String toString() => 'DiSetKey<$T>($name)';
}

/// A collection of entries with a `String` id, read as a `Map<String, T>`.
///
/// A member publishes an entry with `Component(key: map.entryKey(id), ...)`.
/// Another member reads one entry with `Dependency.require(key:
/// map.entryKey(id))`, and a reader reads all of them with
/// `Dependency.requireMap(key: ...)` or `Dependency.maybeMap(key: ...)`. An
/// entry of a
/// nearer scope shadows an entry of an ancestor with the same id.
///
/// {@category Keys}
final class DiMapKey<T> extends DiCollectionKey<T> {
  /// Creates the map key of the entries of type [T] with the [name].
  const DiMapKey({required super.name});

  /// The key of the entry [id] of this map.
  DiMapEntryKey<T> entryKey(String id) => DiMapEntryKey<T>._(this, id);

  @override
  bool operator ==(Object other) =>
      other is DiMapKey && other.type == T && other.name == name;

  @override
  int get hashCode => Object.hash(DiMapKey, T, name);

  @override
  String toString() => 'DiMapKey<$T>($name)';
}

Type _typeOf<X>() => X;

/// The types that an extension type wraps most often. A key without a name
/// of one of them is ambiguous, because the extension type erases to it.
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
