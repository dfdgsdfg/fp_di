part of 'scope.dart';

// The serial queue of the mutations of one runtime. It knows no node, key,
// or scope: it orders the actions, rejects a mutation from inside a running
// one, and reports an action that runs past a threshold.

/// Zone slot holding the mutation that a callback was created in.
const Object _mutationZoneKey = #fpDiActiveMutation;

/// One mutation. A callback created inside it, such as a stream listener,
/// keeps it in its zone; [running] tells a call from inside the running
/// mutation apart from a later callback of a finished one.
final class _RuntimeMutation {
  _RuntimeMutation(this.queue);

  final _RuntimeMutationQueue queue;
  bool running = true;
}

final class _RuntimeMutationQueue {
  _RuntimeMutationQueue({this.onSlow, required this.slowThreshold});

  /// Called with the operation and its elapsed time after each
  /// [slowThreshold] that a mutation runs past.
  final void Function(String operation, Duration elapsed)? onSlow;
  final Duration slowThreshold;

  /// Mutations requested and not yet started.
  int get queued => _queued;
  int _queued = 0;

  /// Mutations requested whose gate is not released yet. A mutation leaves
  /// the count in its `finally`, before it completes the gate. When the count
  /// is zero, [_tail] is stale: the next mutation does not wait on it.
  int _open = 0;

  /// The mutation that runs now. Only assertions read and write it, for
  /// the `SerialMutations` self-check.
  _RuntimeMutation? _running;

  Future<void> _tail = Future<void>.value();

  /// Whether the caller runs inside a mutation of this queue that has not
  /// finished. A mutation from there would wait for itself.
  bool get inMutation {
    final mutation = Zone.current[_mutationZoneKey];
    return mutation is _RuntimeMutation &&
        identical(mutation.queue, this) &&
        mutation.running;
  }

  /// Runs [action] as one mutation, after every mutation requested before it.
  Future<T> run<T>(String operation, Future<T> Function() action) {
    // Mutations are serialized on one queue, so a call issued from *inside* a
    // running mutation would await a gate that only opens once it returns.
    // The zone marker distinguishes that from an unrelated caller arriving
    // while a mutation happens to be in flight, which may simply queue.
    if (inMutation) {
      return Future<T>.error(
        ReentrantMutationError(operation),
        StackTrace.current,
      );
    }
    // Wait on the gate only while its mutation is open. A gate that was
    // released is a future of the zone that created it, and a listener on a
    // completed future runs in that zone. That zone can be dead by now, and
    // then the waiting mutation never starts.
    final previous = _open > 0 ? _tail : null;
    final gate = Completer<void>();
    final result = Completer<T>();
    _tail = gate.future;
    _open++;
    _queued++;
    // The caller's zone is never a running mutation of this queue.
    final callerZone = Zone.current;
    unawaited(() async {
      // The fault removes the wait, so this mutation overlaps the last.
      if (!RuntimeFaults.breaks(RuntimeSelfCheckFault.serialMutations)) {
        try {
          // One asynchronous hop in either branch: the action never starts
          // inside this call. The fresh future is complete and belongs to the
          // zone of the caller, so the hop needs no other zone.
          await (previous ?? Future<void>.sync(() {}));
        } on Object {
          // Each mutation reports through its own result; the queue stays live.
        }
      }
      _queued--;
      final mutation = _RuntimeMutation(this);
      final slow = _watchSlow(operation, callerZone);
      try {
        assert(
          RuntimeFaults.selfChecksMuted || _running == null,
          'SelfCheck SerialMutations: $operation starts while another '
          'mutation of the runtime still runs',
        );
        assert(() {
          _running = mutation;
          return true;
        }());
        final zone = Zone.current.fork(
          zoneValues: <Object, Object>{_mutationZoneKey: mutation},
        );
        result.complete(await zone.run(action));
      } on Object catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      } finally {
        slow?.cancel();
        mutation.running = false;
        assert(() {
          if (identical(_running, mutation)) _running = null;
          return true;
        }());
        _open--;
        gate.complete();
      }
    }());
    return result.future;
  }

  /// Calls [onSlow] for [operation] after each threshold it runs past. The
  /// timer runs in the caller's zone, outside the mutation, so the listener
  /// can request mutations, which queue behind this one.
  Timer? _watchSlow(String operation, Zone callerZone) {
    final onSlow = this.onSlow;
    if (onSlow == null) return null;
    final watch = Stopwatch()..start();
    return callerZone.run(
      () => Timer.periodic(
        slowThreshold,
        (_) => onSlow(operation, watch.elapsed),
      ),
    );
  }
}
