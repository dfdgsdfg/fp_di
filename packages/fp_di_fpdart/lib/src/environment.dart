// Internal type. The library file does not export this file.
import 'package:fpdart/fpdart.dart';

import 'key.dart';

/// The values that a scope makes visible, by key.
///
/// The environment is the `ZEnvironment` of ZIO: an immutable map from a key
/// to a value. A child scope stacks its own values over the environment of
/// its parent, so a lookup is one lookup in one map.
final class Environment {
  const Environment._(this._entries);

  /// Creates an environment with the [entries].
  ///
  /// The environment keeps a copy, so a later change of [entries] has no
  /// effect.
  factory Environment.of(Map<DiKey<Object?>, Object?> entries) =>
      Environment._(Map.unmodifiable(entries));

  /// The environment with no value.
  static const Environment empty = Environment._({});

  /// The monoid of stacking: the right environment wins for a shared key.
  ///
  /// The identity is [empty]. The operation is associative.
  static final Monoid<Environment> monoid = Monoid.instance<Environment>(
    empty,
    (below, above) => Environment.of({...below._entries, ...above._entries}),
  );

  final Map<DiKey<Object?>, Object?> _entries;

  /// Whether the environment has a value for [key].
  ///
  /// A value can be `null`, so the result differs from a `null` lookup.
  bool contains(DiKey<Object?> key) => _entries.containsKey(key);

  /// The value for [key], or `None` when the environment has no such value.
  Option<Object?> lookup(DiKey<Object?> key) =>
      contains(key) ? Some(_entries[key]) : const None();

  /// The value for [key]. The environment must have the value.
  T read<T>(DiKey<T> key) => _entries[key] as T;
}
