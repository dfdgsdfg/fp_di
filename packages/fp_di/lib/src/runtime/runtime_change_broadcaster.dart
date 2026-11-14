part of 'scope.dart';

// The listeners and the error stream of one runtime. Each transition of the
// state calls every listener of the root once.

/// One listener of one scope.
final class _RuntimeListener {
  _RuntimeListener(this.scope, this.call);

  final _RuntimeScope scope;
  final void Function() call;

  /// Whether the listener left the runtime. A round that already copied the
  /// listeners skips it.
  bool removed = false;
}

final class _RuntimeChangeBroadcaster {
  /// The listeners of every scope of the root, in the order they were added.
  final List<_RuntimeListener> listeners = <_RuntimeListener>[];

  final StreamController<DiException> errors =
      StreamController<DiException>.broadcast(sync: true);

  /// The number of transitions of the state.
  int revision = 0;

  /// The transitions whose listener calls have not run. A value is the scope
  /// that its transition disposed, or null.
  final Queue<_RuntimeScope?> _rounds = Queue<_RuntimeScope?>();
  bool _calling = false;

  /// Adds [listener] to [scope]. A second call with the same function on the
  /// same scope adds nothing.
  void add(_RuntimeScope scope, void Function() listener) {
    for (final entry in listeners) {
      if (identical(entry.scope, scope) && entry.call == listener) return;
    }
    listeners.add(_RuntimeListener(scope, listener));
  }

  /// Removes [listener] from [scope].
  void remove(_RuntimeScope scope, void Function() listener) {
    _removeWhere(
      (entry) => identical(entry.scope, scope) && entry.call == listener,
    );
  }

  void _removeWhere(bool Function(_RuntimeListener entry) test) {
    listeners.removeWhere((entry) {
      if (!test(entry)) return false;
      entry.removed = true;
      return true;
    });
  }

  /// The failures that wait for the report in progress.
  final Queue<DiException> _reports = Queue<DiException>();
  bool _reporting = false;

  /// Reports [error], which no caller receives.
  ///
  /// The stream calls its subscribers inside `add`, and a subscriber can
  /// start a transition whose listener throws. That failure waits here, and
  /// the runtime reports it after the report in progress: a stream cannot
  /// take an event while it delivers one.
  void report(DiException error) {
    _reports.add(error);
    if (_reporting) return;
    _reporting = true;
    try {
      while (_reports.isNotEmpty) {
        final next = _reports.removeFirst();
        if (!errors.isClosed) errors.add(next);
      }
    } finally {
      _reporting = false;
    }
  }

  /// Ends one transition: the runtime has replaced the state. Increases
  /// [revision] and calls each listener once. [disposed] is the scope that
  /// the transition disposed; its listeners leave after their calls.
  ///
  /// The calls of one transition complete before the calls of the next. A
  /// transition that a listener starts increases [revision] at once, and its
  /// calls follow the calls in progress. A listener that throws is removed,
  /// and the error stream reports it after the calls.
  ///
  /// With [silent], the transition calls no listener. Only the defect
  /// `SilentReleaseStart` sets it.
  void transition({_RuntimeScope? disposed, bool silent = false}) {
    revision++;
    if (silent) return;
    _rounds.add(disposed);
    if (_calling) return;
    _calling = true;
    try {
      while (_rounds.isNotEmpty) {
        final ended = _rounds.removeFirst();
        final failures = <DiListenerException>[];
        for (final entry in List<_RuntimeListener>.of(listeners)) {
          if (entry.removed) continue;
          try {
            entry.call();
          } on Object catch (error, stackTrace) {
            // The defect keeps the listener that threw.
            if (!RuntimeFaults.injects(RuntimeDefect.keepThrowingListener)) {
              _removeWhere((other) => identical(other, entry));
            }
            failures.add(DiListenerException(error, stackTrace));
          }
        }
        if (ended != null) {
          _removeWhere((entry) => identical(entry.scope, ended));
        }
        failures.forEach(report);
      }
    } finally {
      _calling = false;
    }
  }
}
