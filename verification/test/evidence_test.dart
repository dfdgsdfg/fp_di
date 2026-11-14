// V-T-VR-FORM-004: only complete, valid, expected outcomes count as passed.
//
// Run: dart run agents/scripts/test_core.dart verification/test
import 'package:test/test.dart';

import '../evidence.dart';

const _done =
    'Model checking completed. No error has been found.\n'
    '1,234 states generated, 345 distinct states found, 0 states left.';

Map<String, Object?> _scenario({
  Object expected = 'pass',
  Object observed = 'pass',
  String? status,
  Object? distinctStates = '345',
  List<String> drop = const [],
}) {
  final scenario = <String, Object?>{
    'name': 'S',
    'config': 'S.cfg',
    'configSha256': 'c',
    'constants': ['N = 2'],
    'invariants': ['TypeOK'],
    'properties': <String>[],
    'expected': expected,
    'observed': observed,
    'status': status ?? scenarioStatus(observed, expected),
    'distinctStates': distinctStates,
    'exitCode': 0,
    'durationMs': 10,
    'log': 'out/S/tlc.log',
  };
  for (final field in drop) {
    scenario.remove(field);
  }
  return scenario;
}

Map<String, Object?> _report(
  List<Map<String, Object?>> scenarios, {
  String status = 'passed',
  bool tool = true,
}) => {
  'runId': 'r',
  'status': status,
  'tool': tool
      ? {'tlc': '1.7.4', 'tlcSha256': 't', 'java': 'j', 'lockSha256': 'l'}
      : {'tlc': '1.7.4'},
  'assumptions': 'bounded',
  'models': [
    {
      'model': 'M.tla',
      'modelSha256': 'm',
      'sources': {'a.dart': 'h'},
      'scenarios': scenarios,
    },
  ],
};

void main() {
  group('classify', () {
    const invariantTrace =
        'Error: Invariant NoopAfterEnd is violated.\n'
        'Error: The behavior up to this point is:\n'
        'State 1: <Initial predicate>\n'
        '/\\ x = 0\n'
        '\n'
        'State 2: <Step line 3, col 5 to line 4, col 9 of module M>\n'
        '/\\ x = 1\n'
        '\n'
        '26 states generated, 20 distinct states found, 0 states left.\n'
        'Finished in 00s at (2026-11-09 14:01:10)\n';
    const temporalTrace =
        'Error: Temporal properties were violated.\n'
        'Error: The following behavior constitutes a counter-example:\n'
        'State 1: <Initial predicate>\n'
        '/\\ x = 0\n'
        '\n'
        'State 2: Stuttering\n'
        '116 states generated, 76 distinct states found, 0 states left.\n'
        'Finished in 00s at (2026-11-09 14:01:11)\n';

    test('a completed run without errors passes', () {
      expect(classify(_done, 0, const []), 'pass');
    });

    test('a whole invariant trace with exit 12 names the invariant', () {
      expect(classify(invariantTrace, 12, const []), {
        'invariant': 'NoopAfterEnd',
      });
    });

    test('a whole temporal trace with exit 13 names the single property', () {
      expect(classify(temporalTrace, 13, const ['Settles']), {
        'temporal': 'Settles',
      });
      expect(
        classify(temporalTrace, 13, const ['A', 'B']),
        'incomplete',
        reason: 'TLC does not name the violated property',
      );
    });

    test('a trace cut after a state header is incomplete', () {
      const cut =
          'Error: Invariant NoopAfterEnd is violated.\n'
          'Error: The behavior up to this point is:\n'
          'State 1:';
      expect(classify(cut, 137, const []), 'incomplete', reason: 'killed');
      expect(classify(cut, 12, const []), 'incomplete', reason: 'no body');
      expect(
        classify(
          '$cut\njava.lang.OutOfMemoryError: Java heap space',
          255,
          const [],
        ),
        'incomplete',
        reason: 'a tool failure after the trace',
      );
    });

    test('a trace without its end or its lasso is incomplete', () {
      final unfinished = invariantTrace.substring(
        0,
        invariantTrace.indexOf('Finished in'),
      );
      expect(classify(unfinished, 12, const []), 'incomplete');
      expect(
        classify(
          temporalTrace.replaceFirst('State 2: Stuttering\n', ''),
          13,
          const ['Settles'],
        ),
        'incomplete',
        reason: 'a lasso without its end',
      );
      expect(
        classify('Error: Invariant X is violated.', 12, const []),
        'incomplete',
        reason: 'a message without a trace',
      );
    });

    test('an exit code that does not match the outcome is incomplete', () {
      expect(classify(invariantTrace, 13, const []), 'incomplete');
      expect(classify(temporalTrace, 12, const ['Settles']), 'incomplete');
      expect(classify(_done, 1, const []), 'incomplete');
    });

    test('a tool failure anywhere is incomplete', () {
      expect(
        classify(
          'Error: TLC threw an unexpected exception.\n$invariantTrace',
          12,
          const [],
        ),
        'incomplete',
      );
      expect(
        classify('$_done\nException in thread "main"', 0, const []),
        'incomplete',
      );
    });

    test('a timeout or a parse error is incomplete', () {
      expect(classify(_done, null, const []), 'incomplete', reason: 'timeout');
      expect(
        classify('Parse Error: Unknown operator', 255, const []),
        'incomplete',
      );
      expect(classify('', 0, const []), 'incomplete', reason: 'interrupted');
    });
  });

  test('section reads the indented entries after a header', () {
    const cfg = 'INVARIANTS\n    TypeOK\n    Safe\nPROPERTIES\n    Live\n';
    expect(section(cfg, 'INVARIANTS'), ['TypeOK', 'Safe']);
    expect(section(cfg, 'PROPERTIES'), ['Live']);
    expect(section(cfg, 'CONSTANTS'), isEmpty);
  });

  group('scenarioStatus', () {
    test('compares outcomes structurally', () {
      expect(scenarioStatus('pass', 'pass'), 'ok');
      expect(scenarioStatus({'invariant': 'X'}, {'invariant': 'X'}), 'ok');
      expect(
        scenarioStatus({'invariant': 'Y'}, {'invariant': 'X'}),
        'unexpected',
      );
      expect(scenarioStatus('pass', {'invariant': 'X'}), 'unexpected');
      expect(scenarioStatus('incomplete', 'pass'), 'incomplete');
    });
  });

  group('reportProblems', () {
    test('a complete report with expected outcomes passes', () {
      final report = _report([
        _scenario(),
        _scenario(expected: {'invariant': 'X'}, observed: {'invariant': 'X'}),
      ]);
      expect(reportProblems(report), isEmpty);
    });

    test('a missing field is reported', () {
      expect(
        reportProblems(
          _report([
            _scenario(drop: ['configSha256']),
          ]),
        ),
        contains('M.tla/S: missing configSha256'),
      );
      expect(
        reportProblems(_report([_scenario()], tool: false)),
        contains('tool: missing tlcSha256'),
      );
    });

    test('an interrupted scenario does not pass', () {
      final problems = reportProblems(
        _report([_scenario(observed: 'incomplete', distinctStates: null)]),
      );
      expect(problems, isNotEmpty);
      expect(problems.first, contains('incomplete'));
    });

    test('a negative control that passes is unexpected', () {
      final problems = reportProblems(
        _report([
          _scenario(expected: {'invariant': 'X'}, observed: 'pass'),
        ]),
      );
      expect(problems.single, contains('unexpected'));
    });

    test('a status that disagrees with the outcomes is reported', () {
      final problems = reportProblems(
        _report([
          _scenario(
            expected: {'invariant': 'X'},
            observed: 'pass',
            status: 'ok',
          ),
        ]),
      );
      expect(problems, contains(contains('status ok should be unexpected')));
    });

    test('a passing scenario needs state counts', () {
      expect(reportProblems(_report([_scenario(distinctStates: null)])), [
        'M.tla/S: no state counts',
      ]);
    });

    test('an empty or failed report does not pass', () {
      expect(reportProblems(_report([])), contains('report: no scenario'));
      expect(
        reportProblems(_report([_scenario()], status: 'failed')),
        contains('report: status failed'),
      );
    });
  });

  test('missingScenarios names each requested scenario that did not run', () {
    expect(missingScenarios(['A', 'Missing', 'B'], ['A', 'B', 'C']), [
      'Missing',
    ]);
    expect(missingScenarios(const [], ['A']), isEmpty, reason: 'run all');
    expect(missingScenarios(['A'], ['A']), isEmpty);
  });
}
