// Pins the run of a `Dependency` step by step: the calls on the context, their
// order, and the number of microtasks that the run schedules before each call.
//
// A `Dependency` is a program of steps, and one runner interprets it. A step
// that gains or loses an `await` moves a call to another microtask turn, and
// a zone that stops running microtasks then sees another history. The trace
// below was recorded from the closure form of `Dependency` and must not
// change when the program form changes.
import 'dart:async';
import 'dart:io';

import 'package:fp_di/fp_di.dart';
import 'package:fp_di/src/model/cancellation.dart'
    show CancelReason, CancellationSource;
import 'package:fp_di/src/model/context.dart';
import 'package:fp_di/src/model/lease.dart'
    show DisposeFunction, createLease, runDependency;
import 'package:test/test.dart';

const _setKey = DiSetKey<int>(name: 'set');
const _mapKey = DiMapKey<int>(name: 'map');
const _a = DiKey<int>(name: 'a');
const _b = DiKey<String>(name: 'b');
const _c = DiKey<double>(name: 'c');
const _unbound = DiKey<int>(name: 'unbound');

/// A context that logs each call with the microtask count of the run so far.
final class _TraceContext implements DiContext {
  _TraceContext(this.log, this.ticks, {this.cancelOnRequire});

  final List<String> log;
  final int Function() ticks;
  final DiKeyBase? cancelOnRequire;

  final CancellationSource source = CancellationSource();
  final List<DisposeFunction> releases = <DisposeFunction>[];

  static final Map<DiKeyBase, Object?> values = <DiKeyBase, Object?>{
    _a: 1,
    _b: 'two',
    _c: 3.0,
    for (var i = 0; i < 8; i++) DiKey<int>(name: 'n$i'): i,
  };

  void _log(String text) => log.add('$text@${ticks()}');

  @override
  T require<T>({DiKey<T>? key}) {
    final actual = key ?? DiKey<T>();
    _log('require $actual');
    if (actual == cancelOnRequire) source.cancel(CancelReason.owner);
    final value = values[actual];
    if (!values.containsKey(actual)) throw UnavailableKeyException(actual);
    return value as T;
  }

  @override
  T? maybeGet<T>({DiKey<T>? key}) {
    final actual = key ?? DiKey<T>();
    _log('maybeGet $actual');
    return values[actual] as T?;
  }

  @override
  T publish<T>(T value, {required DiKey<T> key}) =>
      throw StateError('not used');

  @override
  Set<T> readSet<T>(DiSetKey<T> key, {required bool strict}) {
    _log('readSet $key strict=$strict');
    return <T>{};
  }

  @override
  Map<String, T> readMap<T>(DiMapKey<T> key, {required bool strict}) {
    _log('readMap $key strict=$strict');
    return <String, T>{};
  }

  @override
  void contribute(Object? value) => throw StateError('not used');

  @override
  CancellationToken get cancellation => source;

  @override
  bool get ownerDisposalRequested => false;

  @override
  void checkpoint() {
    _log('checkpoint');
    if (source.isCanceled) throw ActivationCanceledException();
  }

  @override
  Future<A> acquire<A>(
    FutureOr<A> Function() create, {
    FutureOr<void> Function(A value)? dispose,
  }) async {
    _log('acquire<$A>');
    final lease = await createLease(create, dispose);
    _log('acquired<$A>');
    releases.add(lease.dispose);
    return lease.value;
  }
}

/// Runs [dependency] in a zone that counts the microtasks it schedules.
Future<List<String>> _trace(
  Dependency<Object?> Function(List<String> log) build, {
  DiKeyBase? cancelOnRequire,
  Future<void> Function(Object? value, List<String> log)? after,
}) async {
  final log = <String>[];
  var scheduled = 0;
  final done = Completer<void>();
  unawaited(
    runZoned(
      () async {
        final context = _TraceContext(
          log,
          () => scheduled,
          cancelOnRequire: cancelOnRequire,
        );
        try {
          final value = await runDependency<Object?>(build(log), context);
          log.add('value ${value.runtimeType}:${_show(value)}@$scheduled');
          if (after != null) await after(value, log);
        } on Object catch (error) {
          log.add('error ${error.runtimeType}@$scheduled');
        }
        for (final release in context.releases.reversed) {
          try {
            await release();
            log.add('released@$scheduled');
          } on Object catch (error) {
            log.add('release error ${error.runtimeType}@$scheduled');
          }
        }
        log.add('end@$scheduled');
        done.complete();
      },
      zoneSpecification: ZoneSpecification(
        scheduleMicrotask: (self, parent, zone, f) {
          scheduled++;
          parent.scheduleMicrotask(zone, f);
        },
      ),
    ),
  );
  await done.future;
  return log;
}

String _show(Object? value) => switch (value) {
  Lazy() => 'Lazy',
  _ => '$value',
};

final class _Boom implements Exception {}

Future<Map<String, List<String>>> _scenarios() async {
  final out = <String, List<String>>{};
  Future<void> run(
    String name,
    Dependency<Object?> Function(List<String> log) build, {
    DiKeyBase? cancelOnRequire,
    Future<void> Function(Object? value, List<String> log)? after,
  }) async => out[name] = await _trace(
    build,
    cancelOnRequire: cancelOnRequire,
    after: after,
  );

  await run('create', (l) => Dependency<int>(create: () => 7));
  await run('create async', (l) => Dependency<int>(create: () async => 7));
  await run(
    'create dispose',
    (l) =>
        Dependency<int>(create: () => 7, dispose: (v) => l.add('dispose $v')),
  );
  await run(
    'create dispose async',
    (l) => Dependency<int>(
      create: () async => 7,
      dispose: (v) async => l.add('dispose $v'),
    ),
  );
  await run(
    'create throws',
    (l) => Dependency<int>(create: () => throw _Boom()),
  );
  await run('cancellation', (l) => Dependency.cancellation());
  await run('require', (l) => Dependency.require<int>(key: _a));
  await run('require unbound', (l) => Dependency.require<int>(key: _unbound));
  await run('maybe', (l) => Dependency.maybe<int>(key: _a));
  await run('maybe unbound', (l) => Dependency.maybe<int>(key: _unbound));
  await run('requireSet', (l) => Dependency.requireSet<int>(key: _setKey));
  await run('maybeSet', (l) => Dependency.maybeSet<int>(key: _setKey));
  await run('requireMap', (l) => Dependency.requireMap<int>(key: _mapKey));
  await run('maybeMap', (l) => Dependency.maybeMap<int>(key: _mapKey));
  await run(
    'require2',
    (l) => Dependency.require2<int, String>(key1: _a, key2: _b),
  );
  await run(
    'require3',
    (l) =>
        Dependency.require3<int, String, double>(key1: _a, key2: _b, key3: _c),
  );
  const n = [
    DiKey<int>(name: 'n0'),
    DiKey<int>(name: 'n1'),
    DiKey<int>(name: 'n2'),
    DiKey<int>(name: 'n3'),
    DiKey<int>(name: 'n4'),
    DiKey<int>(name: 'n5'),
    DiKey<int>(name: 'n6'),
    DiKey<int>(name: 'n7'),
  ];
  await run(
    'require8',
    (l) => Dependency.require8<int, int, int, int, int, int, int, int>(
      key1: n[0],
      key2: n[1],
      key3: n[2],
      key4: n[3],
      key5: n[4],
      key6: n[5],
      key7: n[6],
      key8: n[7],
    ),
  );
  await run(
    'map',
    (l) => Dependency.require<int>(key: _a).map((v) {
      l.add('map $v');
      return v + 1;
    }),
  );
  await run(
    'map async',
    (l) => Dependency.require<int>(key: _a).map((v) async {
      l.add('map $v');
      return v + 1;
    }),
  );
  await run(
    'map dispose',
    (l) => Dependency.require<int>(key: _a).map((v) {
      l.add('map $v');
      return v + 1;
    }, dispose: (v) => l.add('dispose $v')),
  );
  await run(
    'map dispose async',
    (l) => Dependency.require<int>(key: _a).map((v) async {
      l.add('map $v');
      return v + 1;
    }, dispose: (v) async => l.add('dispose $v')),
  );
  await run(
    'map throws',
    (l) => Dependency.require<int>(key: _a).map<int>((v) => throw _Boom()),
  );
  await run(
    'map chain',
    (l) => Dependency.require<int>(key: _a)
        .map((v) => v + 1)
        .map((v) => v * 2, dispose: (v) => l.add('dispose $v'))
        .map((v) async => v - 1)
        .map((v) => '$v', dispose: (v) => l.add('dispose $v')),
  );
  await run(
    'map chain canceled',
    (l) => Dependency.require<int>(
      key: _a,
    ).map((v) => v + 1).map((v) => v * 2).map((v) => v - 1),
    cancelOnRequire: _a,
  );
  await run(
    'zip2',
    (l) => (
      Dependency.require<int>(key: _a),
      Dependency.require<String>(key: _b),
    ).zip,
  );
  await run(
    'zip2 canceled',
    (l) => (
      Dependency.require<int>(key: _a),
      Dependency.require<String>(key: _b),
    ).zip,
    cancelOnRequire: _a,
  );
  await run(
    'zip3 mapN',
    (l) => (
      Dependency.require<int>(key: _a),
      Dependency<String>(
        create: () => 'x',
        dispose: (v) => l.add('dispose $v'),
      ),
      Dependency.maybe<double>(key: _c),
    ).zip.mapN((x, y, z) => '$x$y$z', dispose: (v) => l.add('dispose $v')),
  );
  await run(
    'zip8 mapN',
    (l) => (
      Dependency.require<int>(key: n[0]),
      Dependency.require<int>(key: n[1]),
      Dependency.require<int>(key: n[2]),
      Dependency.require<int>(key: n[3]),
      Dependency.require<int>(key: n[4]),
      Dependency.require<int>(key: n[5]),
      Dependency.require<int>(key: n[6]),
      Dependency.require<int>(key: n[7]),
    ).zip.mapN((a, b, c, d, e, f, g, h) => a + b + c + d + e + f + g + h),
  );
  await run(
    'zip of collections',
    (l) => (
      Dependency.requireSet<int>(key: _setKey),
      Dependency.maybeMap<int>(key: _mapKey),
    ).zip,
  );
  await run(
    'Dependency1',
    (l) => Dependency1<int, String>(key1: _a, create: (a) => '$a'),
  );
  await run(
    'Dependency2 dispose',
    (l) => Dependency2<int, String, String>(
      key1: _a,
      key2: _b,
      create: (a, b) async => '$a$b',
      dispose: (v) => l.add('dispose $v'),
    ),
  );
  await run(
    'Dependency3',
    (l) => Dependency3<int, String, double, String>(
      key1: _a,
      key2: _b,
      key3: _c,
      create: (a, b, c) => '$a$b$c',
    ),
  );
  await run(
    'Dependency8',
    (l) => Dependency8<int, int, int, int, int, int, int, int, int>(
      key1: n[0],
      key2: n[1],
      key3: n[2],
      key4: n[3],
      key5: n[4],
      key6: n[5],
      key7: n[6],
      key8: n[7],
      create: (a, b, c, d, e, f, g, h) => a + h,
    ),
  );
  await run(
    'lazy not forced',
    (l) => Dependency.require<int>(key: _a).map((v) {
      l.add('lazy body $v');
      return v + 1;
    }).lazy(),
  );
  await run(
    'lazy forced',
    (l) => (
      Dependency.require<int>(key: _a),
      Dependency.maybe<String>(key: _b),
      Dependency.requireSet<int>(key: _setKey),
      Dependency.maybeMap<int>(key: _mapKey),
    ).zip.map((v) => v.$1 + 1, dispose: (v) => l.add('dispose $v')).lazy(),
    after: (value, log) async {
      final lazy = value! as Lazy<int>;
      log.add('force ${await lazy.force()}');
      log.add('force again ${await lazy.force()}');
    },
  );
  await run(
    'lazy forced throws',
    (l) => Dependency.require<int>(key: _a)
        .map((v) => v + 1, dispose: (v) => throw StateError('dispose failure'))
        .map<int>((v) => throw _Boom())
        .lazy(),
    after: (value, log) async {
      final lazy = value! as Lazy<int>;
      try {
        await lazy.force();
      } on Object catch (error) {
        log.add('force error ${error.runtimeType}');
        if (error is ActivationException) {
          log.add('rollback failures ${error.rollbackFailures.length}');
        }
      }
    },
  );
  await run(
    'lazy of lazy',
    (l) => Dependency.require<int>(key: _a).lazy().map((lz) => lz).lazy(),
    after: (value, log) async {
      final outer = value! as Lazy<Lazy<int>>;
      final inner = await outer.force();
      log.add('inner ${await inner.force()}');
    },
  );
  await run(
    'lazy with cancellation',
    (l) => (
      Dependency.cancellation(),
      Dependency.require<int>(key: _a),
    ).zip.map((v) => v.$2).lazy(),
    after: (value, log) async {
      final lazy = value! as Lazy<int>;
      log.add('force ${await lazy.force()}');
    },
  );
  return out;
}

void _expectShape(
  Dependency<Object?> dependency, {
  Set<DiKeyBase> requires = const {},
  Set<DiKeyBase> optional = const {},
  Set<DiKeyBase> collections = const {},
  Set<DiKeyBase> optionalCollections = const {},
}) {
  expect(dependency.requires, requires);
  expect(dependency.optional, optional);
  expect(dependency.collectionKeys, collections);
  expect(dependency.optionalCollectionKeys, optionalCollections);
}

void main() {
  group('the shape derived from the program', () {
    const keys = [
      DiKey<int>(name: 'n0'),
      DiKey<int>(name: 'n1'),
      DiKey<int>(name: 'n2'),
      DiKey<int>(name: 'n3'),
      DiKey<int>(name: 'n4'),
      DiKey<int>(name: 'n5'),
      DiKey<int>(name: 'n6'),
      DiKey<int>(name: 'n7'),
    ];

    test('a leaf reads what its constructor names', () {
      _expectShape(Dependency<int>(create: () => 1));
      _expectShape(Dependency<int>(create: () => 1, dispose: (_) {}));
      _expectShape(Dependency.cancellation());
      _expectShape(Dependency.require<int>(key: _a), requires: {_a});
      _expectShape(Dependency.maybe<int>(key: _a), optional: {_a});
      _expectShape(
        Dependency.requireSet<int>(key: _setKey),
        collections: {_setKey},
      );
      _expectShape(
        Dependency.maybeSet<int>(key: _setKey),
        optionalCollections: {_setKey},
      );
      _expectShape(
        Dependency.requireMap<int>(key: _mapKey),
        collections: {_mapKey},
      );
      _expectShape(
        Dependency.maybeMap<int>(key: _mapKey),
        optionalCollections: {_mapKey},
      );
    });

    test('require2 to require8 read their keys', () {
      _expectShape(
        Dependency.require2<int, String>(key1: _a, key2: _b),
        requires: {_a, _b},
      );
      _expectShape(
        Dependency.require3<int, String, double>(key1: _a, key2: _b, key3: _c),
        requires: {_a, _b, _c},
      );
      _expectShape(
        Dependency.require8<int, int, int, int, int, int, int, int>(
          key1: keys[0],
          key2: keys[1],
          key3: keys[2],
          key4: keys[3],
          key5: keys[4],
          key6: keys[5],
          key7: keys[6],
          key8: keys[7],
        ),
        requires: {...keys},
      );
      // Equal keys are one key.
      _expectShape(
        Dependency.require2<int, int>(key1: _a, key2: _a),
        requires: {_a},
      );
    });

    test('map, mapN, and lazy keep the shape', () {
      final base = Dependency.require<int>(key: _a);
      _expectShape(base.map((v) => v), requires: {_a});
      _expectShape(base.map((v) => v, dispose: (_) {}), requires: {_a});
      _expectShape(base.lazy(), requires: {_a});
      _expectShape(base.map((v) => v).lazy().map((v) => v), requires: {_a});
      _expectShape(
        (base, base).zip.mapN((x, y) => x + y).lazy(),
        requires: {_a},
      );
    });

    test('zip is the union of the shapes', () {
      final mixed = (
        Dependency.require<int>(key: _a),
        Dependency.maybe<String>(key: _b),
        Dependency.requireSet<int>(key: _setKey),
        Dependency.maybeMap<int>(key: _mapKey),
        Dependency.cancellation(),
        Dependency.require<double>(key: _c),
        Dependency<int>(create: () => 1),
        Dependency.require<int>(key: _a),
      ).zip;
      _expectShape(
        mixed,
        requires: {_a, _c},
        optional: {_b},
        collections: {_setKey},
        optionalCollections: {_mapKey},
      );
      _expectShape(
        (
          Dependency.require<int>(key: _a),
          Dependency.require<int>(key: _a),
        ).zip,
        requires: {_a},
      );
    });

    test('Dependency1 to Dependency8 read their keys', () {
      _expectShape(
        Dependency1<int, int>(key1: _a, create: (a) => a),
        requires: {_a},
      );
      _expectShape(
        Dependency3<int, String, double, int>(
          key1: _a,
          key2: _b,
          key3: _c,
          create: (a, b, c) => a,
        ),
        requires: {_a, _b, _c},
      );
      _expectShape(
        Dependency8<int, int, int, int, int, int, int, int, int>(
          key1: keys[0],
          key2: keys[1],
          key3: keys[2],
          key4: keys[3],
          key5: keys[4],
          key6: keys[5],
          key7: keys[6],
          key8: keys[7],
          create: (a, b, c, d, e, f, g, h) => a,
        ),
        requires: {...keys},
      );
    });

    test('a default key is the key of the type', () {
      _expectShape(
        Dependency.require<Duration>(),
        requires: {const DiKey<Duration>()},
      );
      _expectShape(
        Dependency.maybe<Duration>(),
        optional: {const DiKey<Duration>()},
      );
    });
  });

  test('every combinator runs the recorded history', () async {
    final scenarios = await _scenarios();
    final actual = StringBuffer();
    for (final entry in scenarios.entries) {
      actual.writeln('# ${entry.key}');
      entry.value.forEach(actual.writeln);
    }
    final dump = Platform.environment['DEPENDENCY_PROGRAM_DUMP'];
    if (dump != null) File(dump).writeAsStringSync(actual.toString());
    expect(actual.toString(), _golden);
  });
}

const String _golden = r'''
# create
checkpoint@0
value int:7@1
end@1
# create async
checkpoint@0
value int:7@1
end@1
# create dispose
checkpoint@0
acquire<int>@0
acquired<int>@1
value int:7@1
dispose 7
released@2
end@2
# create dispose async
checkpoint@0
acquire<int>@0
acquired<int>@1
value int:7@1
dispose 7
released@2
end@2
# create throws
checkpoint@0
error _Boom@1
end@1
# cancellation
value CancellationSource:Instance of 'CancellationSource'@1
end@1
# require
require DiKey<int>(a)@0
value int:1@1
end@1
# require unbound
require DiKey<int>(unbound)@0
error UnavailableKeyException@1
end@1
# maybe
maybeGet DiKey<int>(a)@0
value int:1@1
end@1
# maybe unbound
maybeGet DiKey<int>(unbound)@0
value Null:null@1
end@1
# requireSet
readSet DiSetKey<int>(set) strict=true@0
value _Set<int>:{}@1
end@1
# maybeSet
readSet DiSetKey<int>(set) strict=false@0
value _Set<int>:{}@1
end@1
# requireMap
readMap DiMapKey<int>(map) strict=true@0
value _Map<String, int>:{}@1
end@1
# maybeMap
readMap DiMapKey<int>(map) strict=false@0
value _Map<String, int>:{}@1
end@1
# require2
require DiKey<int>(a)@0
require DiKey<String>(b)@0
value (int, String):(1, two)@1
end@1
# require3
require DiKey<int>(a)@0
require DiKey<String>(b)@0
require DiKey<double>(c)@0
value (int, String, double):(1, two, 3.0)@1
end@1
# require8
require DiKey<int>(n0)@0
require DiKey<int>(n1)@0
require DiKey<int>(n2)@0
require DiKey<int>(n3)@0
require DiKey<int>(n4)@0
require DiKey<int>(n5)@0
require DiKey<int>(n6)@0
require DiKey<int>(n7)@0
value (int, int, int, int, int, int, int, int):(0, 1, 2, 3, 4, 5, 6, 7)@1
end@1
# map
require DiKey<int>(a)@0
checkpoint@1
map 1
value int:2@1
end@1
# map async
require DiKey<int>(a)@0
checkpoint@1
map 1
value int:2@2
end@2
# map dispose
require DiKey<int>(a)@0
checkpoint@1
acquire<Object?>@1
map 1
acquired<Object?>@2
value int:2@2
dispose 2
released@3
end@3
# map dispose async
require DiKey<int>(a)@0
checkpoint@1
acquire<Object?>@1
map 1
acquired<Object?>@2
value int:2@2
dispose 2
released@3
end@3
# map throws
require DiKey<int>(a)@0
checkpoint@1
error _Boom@1
end@1
# map chain
require DiKey<int>(a)@0
checkpoint@1
checkpoint@1
acquire<int>@1
acquired<int>@2
checkpoint@2
checkpoint@3
acquire<Object?>@3
acquired<Object?>@4
value String:3@4
dispose 3
released@5
dispose 4
released@6
end@6
# map chain canceled
require DiKey<int>(a)@0
checkpoint@1
error ActivationCanceledException@1
end@1
# zip2
require DiKey<int>(a)@0
checkpoint@1
require DiKey<String>(b)@1
value (int, String):(1, two)@2
end@2
# zip2 canceled
require DiKey<int>(a)@0
checkpoint@1
error ActivationCanceledException@1
end@1
# zip3 mapN
require DiKey<int>(a)@0
checkpoint@1
checkpoint@1
acquire<String>@1
acquired<String>@2
checkpoint@2
maybeGet DiKey<double>(c)@2
checkpoint@3
checkpoint@3
acquire<Object?>@3
acquired<Object?>@4
value String:1x3.0@4
dispose 1x3.0
released@5
dispose x
released@6
end@6
# zip8 mapN
require DiKey<int>(n0)@0
checkpoint@1
require DiKey<int>(n1)@1
checkpoint@2
require DiKey<int>(n2)@2
checkpoint@3
checkpoint@3
require DiKey<int>(n3)@3
checkpoint@4
checkpoint@4
require DiKey<int>(n4)@4
checkpoint@5
checkpoint@5
require DiKey<int>(n5)@5
checkpoint@6
checkpoint@6
require DiKey<int>(n6)@6
checkpoint@7
checkpoint@7
require DiKey<int>(n7)@7
checkpoint@8
checkpoint@8
value int:28@8
end@8
# zip of collections
readSet DiSetKey<int>(set) strict=true@0
checkpoint@1
readMap DiMapKey<int>(map) strict=false@1
value (_Set<int>, _Map<String, int>):({}, {})@2
end@2
# Dependency1
require DiKey<int>(a)@0
checkpoint@1
value String:1@1
end@1
# Dependency2 dispose
require DiKey<int>(a)@0
require DiKey<String>(b)@0
checkpoint@1
acquire<String>@1
acquired<String>@2
value String:1two@2
dispose 1two
released@3
end@3
# Dependency3
require DiKey<int>(a)@0
require DiKey<String>(b)@0
require DiKey<double>(c)@0
checkpoint@1
value String:1two3.0@1
end@1
# Dependency8
require DiKey<int>(n0)@0
require DiKey<int>(n1)@0
require DiKey<int>(n2)@0
require DiKey<int>(n3)@0
require DiKey<int>(n4)@0
require DiKey<int>(n5)@0
require DiKey<int>(n6)@0
require DiKey<int>(n7)@0
checkpoint@1
value int:7@1
end@1
# lazy not forced
require DiKey<int>(a)@0
acquire<Lazy<int>>@0
acquired<Lazy<int>>@1
value Lazy<int>:Lazy@1
released@2
end@2
# lazy forced
require DiKey<int>(a)@0
maybeGet DiKey<String>(b)@0
readSet DiSetKey<int>(set) strict=true@0
readMap DiMapKey<int>(map) strict=false@0
acquire<Lazy<int>>@0
acquired<Lazy<int>>@1
value Lazy<int>:Lazy@1
force 2
force again 2
dispose 2
released@9
end@9
# lazy forced throws
require DiKey<int>(a)@0
acquire<Lazy<int>>@0
acquired<Lazy<int>>@1
value Lazy<int>:Lazy@1
force error ActivationException
rollback failures 1
released@5
end@5
# lazy of lazy
require DiKey<int>(a)@0
acquire<Lazy<Lazy<int>>>@0
acquired<Lazy<Lazy<int>>>@1
value Lazy<Lazy<int>>:Lazy@1
inner 1
released@6
end@6
# lazy with cancellation
require DiKey<int>(a)@0
acquire<Lazy<int>>@0
acquired<Lazy<int>>@1
value Lazy<int>:Lazy@1
force 1
released@5
end@5
''';
