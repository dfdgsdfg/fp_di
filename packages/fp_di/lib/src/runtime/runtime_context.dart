part of 'scope.dart';

// The context that one activation of a node runs against: the runtime
// implementation of `DiContext` from context.dart. It reads the private
// state of the runtime, so it is a part of this library.

final class _RuntimeContext implements DiContext {
  _RuntimeContext(this.runtime, this.node) {
    node.activationContext = this;
  }

  final _Runtime runtime;
  final _RuntimeNode node;

  final List<_RuntimePublisher> staged = <_RuntimePublisher>[];
  final List<DisposeFunction> cleanups = <DisposeFunction>[];
  final Set<_RuntimePublisher> dependencies = <_RuntimePublisher>{};
  final Map<DiKeyBase, _RuntimePublisher> committed =
      <DiKeyBase, _RuntimePublisher>{};
  final Map<DiCollectionKey<Object?>, List<DiKeyBase>> committedMembership =
      <DiCollectionKey<Object?>, List<DiKeyBase>>{};

  /// Releases that failed after their activation was gone, which the
  /// cleanup list never saw and so cannot report on its own.
  final List<DisposeFailure> rollbackFailures = <DisposeFailure>[];

  bool tearingDown = false;

  /// Canceled when the disposal of the owner is requested and when this
  /// activation deactivates.
  final CancellationSource token = CancellationSource();

  @override
  CancellationToken get cancellation => token;

  @override
  bool get ownerDisposalRequested => node.disposalRequested;

  @override
  void checkpoint() {
    if (token.isCanceled) throw ActivationCanceledException();
  }

  /// Cancels this activation because a value it reads is being withdrawn.
  /// The node then waits for every such withdrawal to finish.
  void cancelForWithdrawal([Iterable<_RuntimeNode>? roots]) {
    token.cancel(CancelReason.withdrawal);
    node.awaiting.addAll(
      roots ??
          [
            for (final pending in runtime.pendingWithdrawals)
              if (pending.reach.any(_reads)) pending.root,
          ],
    );
  }

  bool _reads(_RuntimeNode owner) =>
      dependencies.any((publisher) => identical(publisher.owner, owner)) ||
      node.plainReads.any((key) => identical(node.resolve(key)?.owner, owner));

  /// A read of a publisher whose withdrawal is pending cancels this
  /// activation, so it never commits against a departing value.
  void _readOf(_RuntimePublisher publisher) {
    final roots = runtime.withdrawalsOf(publisher).toList();
    if (roots.isNotEmpty) cancelForWithdrawal(roots);
  }

  @override
  T require<T>({DiKey<T>? key}) {
    final actual = key ?? DiKey<T>();
    assert(
      RuntimeFaults.selfChecksMuted || _inShape(actual, node.declaredRequires),
      'SelfCheck ReadsWithinShape: ${node.label} requires $actual outside '
      'its shape',
    );
    final publisher = node.resolve(actual);
    if (publisher == null) throw UnavailableKeyException(actual);
    runtime.addDependency(node, publisher, this);
    _readOf(publisher);
    return publisher.value as T;
  }

  @override
  T? maybeGet<T>({DiKey<T>? key}) {
    final actual = key ?? DiKey<T>();
    assert(
      RuntimeFaults.selfChecksMuted ||
          _inShape(actual, node.declaredPlainReads),
      'SelfCheck ReadsWithinShape: ${node.label} reads $actual outside its '
      'shape',
    );
    final publisher = node.resolve(actual);
    // A key read while unbound is still tracked, so the node reloads when a
    // publisher for it later appears.
    if (publisher == null) return null;
    runtime.addDependency(node, publisher, this);
    _readOf(publisher);
    return publisher.value as T;
  }

  @override
  T publish<T>(T value, {required DiKey<T> key}) {
    _ensureActivating('publish');
    if (key.isUnreachable) throw UnreachableKeyError(key);
    if (node.scope.bindings.containsKey(key) ||
        staged.any((publisher) => publisher.key == key)) {
      throw DuplicateKeyError(key);
    }
    staged.add(_RuntimePublisher(key, value, node.scope, node));
    return value;
  }

  @override
  Set<T> readSet<T>(DiSetKey<T> key, {required bool strict}) {
    assert(
      RuntimeFaults.selfChecksMuted || _inCollectionShape(key),
      'SelfCheck ReadsWithinShape: ${node.label} reads the set $key outside '
      'its shape',
    );
    final keys = node.contributionKeysOf(key);
    committedMembership[key] = keys;
    final result = <T>{};
    for (final contribution in keys) {
      final value = _readContribution(contribution, key, strict: strict);
      if (value != null) result.add(value.$1 as T);
    }
    return result;
  }

  @override
  Map<String, T> readMap<T>(DiMapKey<T> key, {required bool strict}) {
    assert(
      RuntimeFaults.selfChecksMuted || _inCollectionShape(key),
      'SelfCheck ReadsWithinShape: ${node.label} reads the map $key outside '
      'its shape',
    );
    final keys = node.contributionKeysOf(key);
    committedMembership[key] = keys;
    final result = <String, T>{};
    for (final contribution in keys) {
      final value = _readContribution(contribution, key, strict: strict);
      if (value != null) result[contribution.name!] = value.$1 as T;
    }
    return result;
  }

  /// Whether [key] is in [declared], a key set of the shape of the node. The
  /// fault compares the read with an empty shape.
  bool _inShape(DiKeyBase key, Set<DiKeyBase> declared) =>
      !RuntimeFaults.breaks(RuntimeSelfCheckFault.readsWithinShape) &&
      declared.contains(key);

  /// Whether [key] is a collection key in the shape of the node.
  bool _inCollectionShape(DiCollectionKey<Object?> key) =>
      !RuntimeFaults.breaks(RuntimeSelfCheckFault.readsWithinShape) &&
      (node.collectionKeys.contains(key) ||
          node.optionalCollectionKeys.contains(key));

  /// The value of the publisher of [contribution], tracked as a plain read, or
  /// null when it does not resolve and [strict] is false.
  (Object?,)? _readContribution(
    DiKeyBase contribution,
    DiCollectionKey<Object?> collection, {
    required bool strict,
  }) {
    final publisher = node.resolve(contribution);
    if (publisher == null) {
      if (strict) throw UnavailableKeyException(collection);
      return null;
    }
    runtime.addDependency(node, publisher, this);
    _readOf(publisher);
    return (publisher.value,);
  }

  @override
  void contribute(Object? value) {
    _ensureActivating('contribute');
    final key = node.contributionKey;
    if (key == null) throw OutsideActivationError('contribute');
    staged.add(_RuntimePublisher(key, value, node.scope, node));
  }

  @override
  Future<A> acquire<A>(
    FutureOr<A> Function() create, {
    FutureOr<void> Function(A value)? dispose,
  }) async {
    _ensureActivating('acquire');
    final lease = await createLease(create, dispose);
    // Every step runs in order, so no public use closes the activation while
    // an acquisition is in flight. The fault closes it and removes the guard.
    if (RuntimeFaults.breaks(RuntimeSelfCheckFault.closedActivation)) {
      tearingDown = true;
    } else if (!_activating) {
      // The activation is gone; the lease would otherwise leak.
      try {
        await lease.dispose();
      } on Object catch (error, stackTrace) {
        rollbackFailures.add(DisposeFailure('acquire', error, stackTrace));
      }
      throw OutsideActivationError('acquire');
    }
    assert(
      RuntimeFaults.selfChecksMuted || _activating,
      'SelfCheck ClosedActivation: an acquisition of ${node.label} joins the '
      'journal of a closed activation',
    );
    cleanups.add(lease.dispose);
    return lease.value;
  }

  /// Whether this activation is the open episode of its node. An activation
  /// that committed, failed, or rolled back is closed even while its node
  /// still exists, so a late request from it never reaches the node.
  bool get _activating =>
      identical(node.inFlight, this) &&
      !tearingDown &&
      !node.deactivating &&
      !node.removed;

  void _ensureActivating(String operation) {
    if (!_activating) throw OutsideActivationError(operation);
  }
}
