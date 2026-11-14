import 'dart:async';

import 'cancellation.dart';
import 'key.dart';

/// The operations a component uses while it activates. Only the runtime
/// implements and calls it.
abstract interface class DiContext {
  /// Reads the value of [key], or of the default key of [T]. The runtime
  /// records the read for change tracking. Throws `UnavailableKeyException`
  /// when the key does not resolve.
  T require<T>({DiKey<T>? key});

  /// Reads the value of [key], or of the default key of [T]. Returns null
  /// when the key does not resolve. The runtime tracks the key even then.
  T? maybeGet<T>({DiKey<T>? key});

  /// Publishes [value] under [key] and returns [value]. The value becomes
  /// visible when the activation commits. Throws `DuplicateKeyError` when the
  /// scope already has a publisher of [key].
  T publish<T>(T value, {required DiKey<T> key});

  /// The values of the members of [key]. With [strict], every member must
  /// resolve; otherwise only the active members are read.
  Set<T> readSet<T>(DiSetKey<T> key, {required bool strict});

  /// The selected entries of [key]. With [strict], every id must resolve;
  /// otherwise only the resolved ids are read.
  Map<String, T> readMap<T>(DiMapKey<T> key, {required bool strict});

  /// Publishes [value] as the contribution of the running component to its
  /// set key.
  void contribute(Object? value);

  /// The token of the activation that runs the `Dependency`.
  CancellationToken get cancellation;

  /// Throws an `ActivationCanceledException` when [cancellation] is
  /// canceled. The steps of a `Dependency` call it before they run.
  void checkpoint();

  /// Runs [create] and records [dispose] for teardown.
  Future<A> acquire<A>(
    FutureOr<A> Function() create, {
    FutureOr<void> Function(A value)? dispose,
  });
}
