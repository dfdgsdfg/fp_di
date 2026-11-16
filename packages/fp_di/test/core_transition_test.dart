// The table of the allowed lifecycle transitions of one scope, and the
// outcome types of an activation attempt. No runtime runs here.
import 'package:fp_di/fp_di.dart';
import 'package:fp_di/src/core/core_activation.dart';
import 'package:fp_di/src/core/core_cause.dart';
import 'package:fp_di/src/core/core_transition.dart';
import 'package:test/test.dart';

void main() {
  group('coreScopeTransition', () {
    ScopePhase? step(ScopePhase phase, CoreScopeEvent event) =>
        coreScopeTransition(phase, event);

    test('a scope walks from declared to disposed', () {
      var phase = ScopePhase.declared;
      for (final (event, expected) in [
        (CoreScopeEvent.beginInitialize, ScopePhase.initializing),
        (CoreScopeEvent.finishInitialize, ScopePhase.initialized),
        (CoreScopeEvent.requestDisposal, ScopePhase.disposeRequested),
        (CoreScopeEvent.markDisposing, ScopePhase.disposing),
        (CoreScopeEvent.markDisposed, ScopePhase.disposed),
      ]) {
        phase = step(phase, event)!;
        expect(phase, expected, reason: '$event');
      }
    });

    test('a rollback returns the scope to declared', () {
      final initializing = step(
        ScopePhase.declared,
        CoreScopeEvent.beginInitialize,
      )!;
      expect(
        step(initializing, CoreScopeEvent.rollbackInitialize),
        ScopePhase.declared,
      );
    });

    test('an end of initialize keeps the phase of a disposal request', () {
      for (final event in [
        CoreScopeEvent.finishInitialize,
        CoreScopeEvent.rollbackInitialize,
      ]) {
        expect(
          step(ScopePhase.disposeRequested, event),
          ScopePhase.disposeRequested,
        );
      }
    });

    test('a scope that no disposal reached disposes from any live phase', () {
      for (final phase in [
        ScopePhase.declared,
        ScopePhase.initializing,
        ScopePhase.initialized,
        ScopePhase.disposeRequested,
      ]) {
        expect(
          step(phase, CoreScopeEvent.requestDisposal),
          ScopePhase.disposeRequested,
        );
        expect(step(phase, CoreScopeEvent.markDisposing), ScopePhase.disposing);
      }
    });

    test('a half done disposal can start again', () {
      expect(
        step(ScopePhase.disposing, CoreScopeEvent.markDisposing),
        ScopePhase.disposing,
      );
    });

    test('a forbidden event gives null', () {
      expect(
        step(ScopePhase.initialized, CoreScopeEvent.beginInitialize),
        null,
      );
      expect(step(ScopePhase.declared, CoreScopeEvent.finishInitialize), null);
      expect(
        step(ScopePhase.initialized, CoreScopeEvent.rollbackInitialize),
        null,
      );
      expect(step(ScopePhase.disposing, CoreScopeEvent.requestDisposal), null);
      expect(step(ScopePhase.disposed, CoreScopeEvent.requestDisposal), null);
      expect(step(ScopePhase.disposed, CoreScopeEvent.markDisposing), null);
      expect(step(ScopePhase.initialized, CoreScopeEvent.markDisposed), null);
      expect(step(ScopePhase.disposed, CoreScopeEvent.markDisposed), null);
    });

    test('the phase disposed allows no event', () {
      for (final event in CoreScopeEvent.values) {
        expect(step(ScopePhase.disposed, event), null, reason: '$event');
      }
    });
  });

  group('CoreActivationOutcome', () {
    test('a switch covers every outcome', () {
      final failure = CoreFail(StateError('failed'), StackTrace.empty);
      final outcomes = <CoreActivationOutcome>[
        const CoreCommitted(),
        const CoreNotStarted(CoreNotStartedReason.unsatisfied),
        const CoreWithdrawn(),
        CoreInterrupted(
          CoreInterrupt(ActivationCanceledException(), StackTrace.empty),
        ),
        CoreFailed(failure),
      ];
      final names = [
        for (final outcome in outcomes)
          switch (outcome) {
            CoreCommitted() => 'committed',
            CoreNotStarted(:final reason) => 'not started ${reason.name}',
            CoreWithdrawn() => 'withdrawn',
            CoreInterrupted() => 'interrupted',
            CoreFailed(failure: final held) =>
              identical(held, failure) ? 'failed' : 'other',
          },
      ];
      expect(names, [
        'committed',
        'not started unsatisfied',
        'withdrawn',
        'interrupted',
        'failed',
      ]);
    });
  });
}
