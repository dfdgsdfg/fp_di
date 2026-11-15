// Internal library. The library file does not export this file.
//
// The effectful shell of the runtime. The pure core in `../core/` holds the
// rules. The shell holds the mutable cells of one root, reads the state from
// them, runs the user steps, and applies the transitions of the core.
//
// Every program of the shell is a `Task` value: it does nothing until it
// runs. A program reads the state with `state`, and changes it with `apply`
// or `write`. A recursive program has no mutable field of a class. The
// mutable cells are the `IORef` values of [Runtime], and each one has a
// stated purpose.
import 'dart:async';

import 'package:fpdart/fpdart.dart';

import '../cancellation.dart';
import '../cause.dart';
import '../component.dart';
import '../core/core.dart';
import '../dependency.dart';
import '../failure.dart';
import '../finalizers.dart';
import '../hold.dart';
import '../key.dart';
import '../slow_mutation.dart';

part 'activation.dart';
part 'disposal.dart';
part 'holds.dart';
part 'initialize.dart';
part 'kernel.dart';
part 'reconcile.dart';
part 'teardown.dart';

/// The cells of one running activation, as the runtime keeps them.
///
/// The record is immutable. Each field is an `IORef`.
final class Activation {
  const Activation._(
    this.token,
    this.reads,
    this.awaited,
    this.view,
    this.membership,
  );

  /// Creates the cells of a new activation.
  factory Activation.create() => Activation._(
    CancellationSource(),
    IORef.create<Set<NodeId>>(const {}).run(),
    IORef.create<Set<NodeId>>(const {}).run(),
    IORef.create<Map<DiKey<Object?>, Option<PublisherRef>>>(const {}).run(),
    IORef.create<Map<DiCollectionKey<Object?>, List<DiKey<Object?>>>>(
      const {},
    ).run(),
  );

  /// The cancellation token of the activation. It stays with the committed
  /// activation until the release of the node ends.
  final CancellationSource token;

  /// The nodes whose values the activation read.
  final IORef<Set<NodeId>> reads;

  /// The roots of the pending withdrawals that canceled the activation at a
  /// read.
  final IORef<Set<NodeId>> awaited;

  /// The publisher that each read key had when the activation read it.
  final IORef<Map<DiKey<Object?>, Option<PublisherRef>>> view;

  /// The contribution keys of each collection that the activation read.
  final IORef<Map<DiCollectionKey<Object?>, List<DiKey<Object?>>>> membership;
}

/// The result of a disposal, which every caller of the disposal shares.
final class Disposal {
  /// Creates a disposal with the [result] that completes later.
  Disposal(this.result) : finished = IORef.create<bool>(false).run();

  /// The result of the disposal.
  final Future<Exit<DiFailure, Unit>> result;

  /// Whether the result completed.
  final IORef<bool> finished;
}

/// One open hold of a disposal, as the runtime keeps it.
final class HoldEntry {
  /// Creates a hold with the [debugLabel]. The clock of the hold starts now.
  HoldEntry(this.debugLabel, this.debugStackTrace)
    : _clock = Stopwatch()..start();

  /// The label that the holder gave, or `null`.
  final String? debugLabel;

  /// The stack trace of the `disposeHold` call. The runtime records it inside
  /// an `assert` only.
  final StackTrace? debugStackTrace;

  final Stopwatch _clock;

  /// The state of the hold in the scope with the path [scopePath].
  HoldState stateIn(String scopePath) => HoldState(
    debugLabel: debugLabel,
    scopePath: scopePath,
    elapsed: _clock.elapsed,
    debugStackTrace: debugStackTrace,
  );
}

/// A disposal that waits for holds, outside the queue of the lifecycle
/// operations.
final class Parked {
  /// Creates the record of a parked disposal.
  Parked(this.disposal, this.completer, this.callerZone, this.timer);

  /// The disposal that the callers share.
  final Disposal disposal;

  /// The completer of the result of [disposal].
  final Completer<Exit<DiFailure, Unit>> completer;

  /// The zone of the call that accepted the disposal. It is never a running
  /// mutation, so the disposal can queue from there.
  final Zone callerZone;

  /// The timer of the slow report, or `null` without a listener.
  final Timer? timer;
}

/// The marker of a running mutation. A zone carries it.
final class _Mutation {
  _Mutation() : running = IORef.create<bool>(true).run();

  /// False after the mutation ended, so a late callback of the zone may start
  /// a new mutation.
  final IORef<bool> running;
}

/// A listener of a scope.
typedef Listener = ({ScopeId scope, void Function() call});

/// The outcome of one attempt to activate a node: the cause that the attempt
/// threw, or whether the attempt ran.
typedef Attempt = Either<Cause<DiFailure>, bool>;

extension _Cell<A> on IORef<A> {
  A get now => read().run();

  void set(A next) => write(next).run();

  void update(A Function(A current) f) => modify(f).run();
}

/// The runtime of one root scope. The children of the root share it.
final class Runtime {
  Runtime._(this._onSlow, this._threshold)
    : _state = IORef.create<RuntimeState>(RuntimeState.empty).run(),
      _queueTail = IORef.create<Future<void>>(Future<void>.value()).run(),
      _open = IORef.create<int>(0).run(),
      _snapshots = IORef.create<Snapshots>(Snapshots.empty).run(),
      _listeners = IORef.create<List<Listener>>(const []).run(),
      _rounds = IORef.create<List<Option<ScopeId>>>(const []).run(),
      _inRound = IORef.create<bool>(false).run(),
      _reports = IORef.create<List<Cause<DiFailure>>>(const []).run(),
      _delivering = IORef.create<bool>(false).run(),
      _closed = IORef.create<bool>(false).run(),
      _activations = IORef.create<Map<int, Activation>>(const {}).run(),
      _committed = IORef.create<Map<NodeId, Activation>>(const {}).run(),
      _waiters = IORef.create<Map<NodeId, Map<Zone, Completer<Wake>>>>(
        const {},
      ).run(),
      _scopeDisposals = IORef.create<Map<ScopeId, Disposal>>(const {}).run(),
      _nodeDisposals = IORef.create<Map<NodeId, Disposal>>(const {}).run(),
      _holds = IORef.create<Map<ScopeId, List<HoldEntry>>>(const {}).run(),
      _parked = IORef.create<Map<ScopeId, Parked>>(const {}).run(),
      _releasing = IORef.create<List<String>>(const []).run(),
      _queued = IORef.create<int>(0).run(),
      _errors = StreamController<Cause<DiFailure>>.broadcast(sync: true);

  /// Creates the runtime of a new root.
  ///
  /// The runtime reports to [onSlowMutation] each time an operation runs
  /// another [slowMutationThreshold] longer. Without a listener the runtime
  /// starts no timer.
  factory Runtime.create({
    SlowMutationListener? onSlowMutation,
    Duration slowMutationThreshold = const Duration(seconds: 2),
  }) => Runtime._(onSlowMutation, slowMutationThreshold);

  /// The listener of the slow reports, or `null`.
  final SlowMutationListener? _onSlow;

  /// The time that an operation runs between two slow reports.
  final Duration _threshold;

  /// The state of the runtime. It is the only source of truth for the rules of
  /// the core.
  final IORef<RuntimeState> _state;

  /// The end of the queue of mutations: the gate of the last mutation that
  /// the runtime accepted. A new mutation starts after it, while a mutation is
  /// open.
  final IORef<Future<void>> _queueTail;

  /// The number of mutations that the runtime accepted and that have not
  /// released their gate. When it is zero, the tail is stale, and the next
  /// mutation does not wait on it.
  final IORef<int> _open;

  /// The snapshots that the last reads built. A read of a state keeps the
  /// object of what did not change since then. The memo changes no rule: a
  /// read without it gives an equal value.
  final IORef<Snapshots> _snapshots;

  /// The listeners of every scope of the root, in insertion order.
  final IORef<List<Listener>> _listeners;

  /// The rounds of listener calls that wait, oldest first. A round is the
  /// scope that a transition disposed, or `None`.
  final IORef<List<Option<ScopeId>>> _rounds;

  /// Whether a round of listener calls runs. Rounds never nest.
  final IORef<bool> _inRound;

  /// The reports that wait for delivery to `errors`, oldest first.
  final IORef<List<Cause<DiFailure>>> _reports;

  /// Whether a report is in delivery. A report waits while another is in
  /// delivery.
  final IORef<bool> _delivering;

  /// Whether the `errors` stream is closed. A report after that is dropped.
  final IORef<bool> _closed;

  /// The running activations by ticket: the cancellation token of each one,
  /// and what it read.
  final IORef<Map<int, Activation>> _activations;

  /// The callers of `whenActive` that wait for the next commit of a node. Each
  /// zone has one completer, so a zone that is dead cannot starve another.
  final IORef<Map<NodeId, Map<Zone, Completer<Wake>>>> _waiters;

  /// The activation of each committed node, until its release ends. Its token
  /// is canceled when the release starts.
  final IORef<Map<NodeId, Activation>> _committed;

  /// The disposal that a scope accepted. Every caller shares it.
  final IORef<Map<ScopeId, Disposal>> _scopeDisposals;

  /// The disposal that a node accepted. Every caller shares it.
  final IORef<Map<NodeId, Disposal>> _nodeDisposals;

  /// The open holds of each scope, in the order of the calls.
  final IORef<Map<ScopeId, List<HoldEntry>>> _holds;

  /// The disposals that wait for holds, by the scope that accepted them.
  final IORef<Map<ScopeId, Parked>> _parked;

  /// The owners whose dispose functions run now, in the order they started.
  final IORef<List<String>> _releasing;

  /// The number of operations that wait for an earlier operation to end.
  final IORef<int> _queued;

  /// The stream of the failures that no caller receives. The controller is the
  /// only effect cell that is not an `IORef`: a stream cannot be a value.
  final StreamController<Cause<DiFailure>> _errors;

  /// The key of the zone value that marks a running mutation of this runtime.
  final Object _zoneKey = Object();

  /// The failures that no caller receives.
  Stream<Cause<DiFailure>> get errors => _errors.stream;

  /// The state of the runtime now.
  RuntimeState get state => _state.now;
}

/// What a waiter of `whenActive` learns: the value, or the failure.
typedef Wake = Either<DiFailure, Object?>;
