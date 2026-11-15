// Property-based law tests for the algebra of `fp_di_fpdart`.
//
// The shape laws (1-5) and the group laws (6-13) are pure: they read only the
// derived shape of a `Dependency`, a `Component`, or a list of components, and
// run no scope. The value laws (14-18) run a `Scope`. They hold for the
// published value of an activation that no cancellation interrupts. The holds
// laws (19) run trees of scopes.
//
// A `map` step is a cancellation checkpoint. When a cancellation arrives
// between two steps, `d.map((x) => x)` stops where `d` completes, so
// `d.map(id)` is not the same as `d`. The value laws state their condition
// ("no cancellation") and no test here cancels an activation.
//
// The group laws 9 and 10 of fp_di state that `+` of a `Module` is
// associative and has an identity, with the origins of the members. A list
// has no origin and its concatenation is the list concatenation of Dart, so
// the laws 9 and 10 have no counterpart here.
import 'dart:async';

import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';
import 'package:kiri_check/kiri_check.dart'
    show
        Arbitrary,
        boolean,
        combine2,
        combine3,
        combine4,
        combine5,
        constantFrom,
        forAll,
        integer,
        list,
        property,
        set;
import 'package:test/test.dart';

import 'support.dart';

// ---------------------------------------------------------------------------
// Key universe

const int _keyCount = 6;

/// The keys `k0` ... `k5`, all of one type.
final List<DiKey<int>> _keys = <DiKey<int>>[
  for (var i = 0; i < _keyCount; i++) DiKey<int>(name: 'k$i'),
];

/// The collection keys `s0` and `s1`.
final List<DiSetKey<int>> _sets = <DiSetKey<int>>[
  DiSetKey<int>(name: 's0'),
  DiSetKey<int>(name: 's1'),
];

/// The key that a value law reads the result from.
final DiKey<int> _outKey = DiKey<int>(name: 'out');

// ---------------------------------------------------------------------------
// Dependency descriptors

/// One step of a generated dependency: `(kind, index)`.
///
/// Kinds: 0 requires `k[index]`, 1 reads `k[index]` optionally, 2 requires
/// `s[index % 2]`, 3 reads `s[index % 2]` optionally, 4 is a `map` step.
typedef Atom = (int, int);

/// A generated dependency: `(atoms, published key or -1)`.
typedef MemberSpec = (List<Atom>, int);

/// A generated group: `(members, label index or -1)`. The label index has no
/// use here: a list of components has no label.
typedef GroupSpec = (List<MemberSpec>, int);

Dependency<int> _build(List<Atom> atoms) {
  var d = Dependency<int>(create: () => 0);
  for (final (kind, i) in atoms) {
    d = switch (kind) {
      0 => (
        d,
        Dependency.require<int>(key: _keys[i]),
      ).zip.map<int>((r) => r.$1 + r.$2),
      1 => (
        d,
        Dependency.option<int>(key: _keys[i]),
      ).zip.map<int>((r) => r.$1 + r.$2.getOrElse(() => 0)),
      2 => (
        d,
        Dependency.requireSet<int>(key: _sets[i % 2]),
      ).zip.map<int>((r) => r.$1 + r.$2.length),
      3 => (
        d,
        Dependency.optionSet<int>(key: _sets[i % 2]),
      ).zip.map<int>((r) => r.$1 + r.$2.length),
      _ => d.map<int>((x) => x + 1),
    };
  }
  return d;
}

Component<Object?> _member(MemberSpec spec) {
  final d = _build(spec.$1);
  final key = spec.$2;
  return key < 0
      ? Component<int>.effect(dependency: d)
      : Component<int>(dependency: d, key: _keys[key]);
}

List<Component<Object?>> _group(GroupSpec spec) => <Component<Object?>>[
  for (final m in spec.$1) _member(m),
];

// ---------------------------------------------------------------------------
// Shape helpers

/// The sorted names of [keys]. Each key prints its type and its name.
List<String> _names(Iterable<DiKeyBase> keys) =>
    (<String>{for (final key in keys) '$key'}.toList()..sort());

/// The four key sets of [d]: requires, optional, collection, optional
/// collection.
List<List<String>> _shape(Dependency<Object?> d) => <List<String>>[
  _names(d.requires),
  _names(d.optional),
  _names(d.collectionKeys),
  _names(d.optionalCollectionKeys),
];

/// The shape that [atoms] state, computed without a `Dependency`.
List<List<String>> _oracleShape(List<Atom> atoms) => <List<String>>[
  _names([
    for (final (kind, i) in atoms)
      if (kind == 0) _keys[i],
  ]),
  _names([
    for (final (kind, i) in atoms)
      if (kind == 1) _keys[i],
  ]),
  _names([
    for (final (kind, i) in atoms)
      if (kind == 2) _sets[i % 2],
  ]),
  _names([
    for (final (kind, i) in atoms)
      if (kind == 3) _sets[i % 2],
  ]),
];

/// The union of shapes, one key set at a time.
List<List<String>> _unionShape(Iterable<List<List<String>>> shapes) =>
    <List<String>>[
      for (var part = 0; part < 4; part++)
        (<String>{for (final shape in shapes) ...shape[part]}.toList()..sort()),
    ];

/// The names in [a] that [b] does not hold.
List<String> _missing(Iterable<DiKeyBase> a, Iterable<DiKeyBase> b) {
  final held = _names(b).toSet();
  return _names(a).where((name) => !held.contains(name)).toList();
}

// ---------------------------------------------------------------------------
// Generators

final Arbitrary<Atom> _atom = combine2(
  integer(min: 0, max: 4),
  integer(min: 0, max: _keyCount - 1),
);

final Arbitrary<List<Atom>> _atoms = list(_atom, maxLength: 6);

final Arbitrary<MemberSpec> _memberSpec = combine2(
  list(_atom, maxLength: 4),
  integer(min: -1, max: _keyCount - 1),
);

final Arbitrary<GroupSpec> _groupSpec = combine2(
  list(_memberSpec, maxLength: 6),
  integer(min: -1, max: 2),
);

final Arbitrary<Set<int>> _keyIndexes = set(
  integer(min: 0, max: _keyCount - 1),
  maxLength: _keyCount,
);

// ---------------------------------------------------------------------------
// Law runner

final Map<String, int> _runs = <String, int>{};

/// Registers one law as a kiri_check property with [examples] cases.
void _law<T>(
  String name,
  Arbitrary<T> arbitrary,
  FutureOr<void> Function(T example) check, {
  int examples = 200,
}) {
  property(name, () {
    forAll(arbitrary, (T example) async {
      _runs[name] = (_runs[name] ?? 0) + 1;
      await check(example);
    }, maxExamples: examples);
  });
}

// ---------------------------------------------------------------------------
// Scope helpers for the value laws

/// A generated value case: the atoms plus the published values.
///
/// `values[i]` is the value of `k[i]`. `flags[i]` publishes `k[i]` even when
/// no atom requires it. A required key is always published.
typedef ValueCase = (List<Atom>, List<int>, List<bool>);

/// Atoms without collection reads: only kinds 0, 1, and 4.
final Arbitrary<List<Atom>> _valueAtoms = list(
  combine2(
    constantFrom<int>(<int>[0, 1, 4]),
    integer(min: 0, max: _keyCount - 1),
  ),
  maxLength: 6,
);

final Arbitrary<List<int>> _values = list(
  integer(min: -50, max: 50),
  minLength: _keyCount,
  maxLength: _keyCount,
);

final Arbitrary<List<bool>> _flags = list(
  boolean(),
  minLength: _keyCount,
  maxLength: _keyCount,
);

/// The published values for the atom lists: every required key, and the
/// flagged keys.
Map<int, int> _published(
  Iterable<List<Atom>> atomLists,
  List<int> values,
  List<bool> flags,
) {
  final required = <int>{
    for (final atoms in atomLists)
      for (final (kind, i) in atoms)
        if (kind == 0) i,
  };
  return <int, int>{
    for (var i = 0; i < _keyCount; i++)
      if (flags[i] || required.contains(i)) i: values[i],
  };
}

/// The value of the atoms, computed without a `Dependency`.
int _oracleValue(List<Atom> atoms, Map<int, int> published) {
  var acc = 0;
  for (final (kind, i) in atoms) {
    acc = switch (kind) {
      0 => acc + published[i]!,
      1 => acc + (published[i] ?? 0),
      _ => acc + 1,
    };
  }
  return acc;
}

/// Runs [d] in a scope next to the value components in [published], and
/// returns the value that the component of [d] publishes.
Future<T> _valueOf<T>(Dependency<T> d, Map<int, int> published) async {
  final key = DiKey<T>(name: 'out');
  final scope = Scope(
    components: <Component<Object?>>[
      for (final entry in published.entries)
        Component<int>.value(value: entry.value, key: _keys[entry.key]),
      Component<T>(dependency: d, key: key),
    ],
  );
  final T value;
  try {
    rightOf(await scope.run());
    value = rightOf(scope.get<T>(key: key));
  } finally {
    await scope.dispose();
  }
  return value;
}

// ---------------------------------------------------------------------------
// Chains for the release laws

final List<DiKey<int>> _chainKeys = <DiKey<int>>[
  for (var i = 0; i < 8; i++) DiKey<int>(name: 'c$i'),
];

/// One step of a chain: it logs its creation, and fails when [failAt] is
/// its index.
int _step(int index, int? failAt, List<int> created, int input) {
  created.add(index);
  if (failAt == index) throw StateError('step $index fails');
  return input + 1;
}

FutureOr<void> Function(int)? _release(
  int index,
  List<bool> hasDispose,
  List<int> disposed,
) => hasDispose[index] ? (_) => disposed.add(index) : null;

/// A chain of [n] steps inside one dependency: each step is a `map` of the
/// step before.
Dependency<int> _innerChain(
  int n,
  List<bool> hasDispose,
  int? failAt,
  List<int> created,
  List<int> disposed,
) {
  var d = Dependency<int>(
    create: () => _step(0, failAt, created, -1),
    dispose: _release(0, hasDispose, disposed),
  );
  for (var i = 1; i < n; i++) {
    d = d.map<int>(
      (x) => _step(i, failAt, created, x),
      dispose: _release(i, hasDispose, disposed),
    );
  }
  return d;
}

/// A chain of [n] components: step `i` reads the key of step `i - 1`.
List<Component<Object?>> _componentChain(
  int n,
  List<bool> hasDispose,
  int? failAt,
  List<int> created,
  List<int> disposed,
) => <Component<Object?>>[
  Component<int>(
    dependency: Dependency<int>(
      create: () => _step(0, failAt, created, -1),
      dispose: _release(0, hasDispose, disposed),
    ),
    key: _chainKeys[0],
  ),
  for (var i = 1; i < n; i++)
    Component<int>(
      dependency: Dependency.require<int>(key: _chainKeys[i - 1]).map<int>(
        (x) => _step(i, failAt, created, x),
        dispose: _release(i, hasDispose, disposed),
      ),
      key: _chainKeys[i],
    ),
];

/// The indexes below [bound] that own a dispose function, newest first.
List<int> _reverseReleases(int bound, List<bool> hasDispose) => <int>[
  for (var i = bound - 1; i >= 0; i--)
    if (hasDispose[i]) i,
];

final Arbitrary<int> _chainLength = integer(min: 1, max: 8);

final Arbitrary<List<bool>> _chainFlags = list(
  boolean(),
  minLength: 8,
  maxLength: 8,
);

// ---------------------------------------------------------------------------
// Trees of scopes for the laws of the holds

/// A generated tree: `(size, parents, readsParent, failing)`.
///
/// The scope `i` below the root has the parent `parents[i - 1] % i`. Each
/// scope holds two components, `s{i}a` and `s{i}b`. `b` reads the `a` of its
/// scope, and also the `b` of the parent scope when `readsParent[i]` is true,
/// so the release order of the tree is not flat. When `failing` is not
/// negative, the component `failing % (2 * size)` throws from its dispose
/// function after it logs its release.
typedef TreeSpec = (int, List<int>, List<bool>, int);

/// A generated disposal with holds: `(tree, target, holds)`.
///
/// `holds` is `(holds, order, waitFirst)`. A hold is `(scope, labelled)`.
/// `order` ranks the closes of the holds, and `waitFirst` makes a law call
/// `dispose()` before it calls `dispose(ignoreHolds: true)`.
typedef HoldCase = (TreeSpec, int, (List<(int, bool)>, List<int>, bool));

final Arbitrary<TreeSpec> _treeSpec = combine4(
  integer(min: 1, max: 4),
  list(integer(min: 0, max: 2), minLength: 3, maxLength: 3),
  list(boolean(), minLength: 4, maxLength: 4),
  integer(min: -3, max: 7),
);

final Arbitrary<HoldCase> _holdCase = combine3(
  _treeSpec,
  integer(min: 0, max: 3),
  combine3(
    list(
      combine2(integer(min: 0, max: 3), boolean()),
      minLength: 1,
      maxLength: 5,
    ),
    list(integer(min: 0, max: 9), minLength: 5, maxLength: 5),
    boolean(),
  ),
);

/// A scope tree that logs the release of its components.
final class _HoldTree {
  _HoldTree(this.size, this.parents, this.scopes, this.log);

  final int size;

  /// The parent index of each scope, -1 for the root.
  final List<int> parents;
  final List<Scope> scopes;
  final List<String> log;

  /// Whether scope [i] is [ancestor] or one of its descendants.
  bool inSubtree(int i, int ancestor) {
    for (var at = i; at >= 0; at = parents[at]) {
      if (at == ancestor) return true;
    }
    return false;
  }
}

Future<_HoldTree> _holdTree(TreeSpec spec) async {
  final (size, rawParents, readsParent, failing) = spec;
  final log = <String>[];
  final parents = <int>[
    -1,
    for (var i = 1; i < size; i++) rawParents[i - 1] % i,
  ];
  final failIndex = failing < 0 ? -1 : failing % (2 * size);
  final keysA = <DiKey<String>>[
    for (var i = 0; i < size; i++) DiKey<String>(name: 's${i}a'),
  ];
  final keysB = <DiKey<String>>[
    for (var i = 0; i < size; i++) DiKey<String>(name: 's${i}b'),
  ];
  void Function(String) release(int member, String name) => (_) {
    log.add(name);
    if (member == failIndex) throw StateError('$name fails');
  };

  List<Component<Object?>> componentsOf(int i) {
    final parent = parents[i];
    return <Component<Object?>>[
      Component<String>(
        dependency: Dependency<String>(
          create: () => 's${i}a',
          dispose: release(2 * i, 's${i}a'),
        ),
        key: keysA[i],
      ),
      Component<String>(
        dependency: parent >= 0 && readsParent[i]
            ? Dependency.require2<String, String>(
                key1: keysA[i],
                key2: keysB[parent],
              ).map<String>(
                (r) => '${r.$1}.${r.$2}',
                dispose: release(2 * i + 1, 's${i}b'),
              )
            : Dependency.require<String>(key: keysA[i]).map<String>(
                (a) => '$a.b',
                dispose: release(2 * i + 1, 's${i}b'),
              ),
        key: keysB[i],
      ),
    ];
  }

  final scopes = <Scope>[];
  for (var i = 0; i < size; i++) {
    final scope = i == 0
        ? Scope(components: componentsOf(0))
        : scopes[parents[i]].kid(components: componentsOf(i));
    scopes.add(rightOf(await scope.run()));
  }
  return _HoldTree(size, parents, scopes, log);
}

/// One `dispose` call: how often it completed, and with which result.
final class _Call {
  _Call(Future<Exit<DiFailure, Unit>> future) {
    future.then<void>((exit) {
      completions++;
      outcome = exit.isRight() ? 'ok' : 'fail';
    });
  }

  int completions = 0;
  String? outcome;
}

/// The release trace and the result of the same disposal without a hold.
Future<(List<String>, String)> _withoutHolds(TreeSpec spec, int target) async {
  final tree = await _holdTree(spec);
  final call = _Call(tree.scopes[target].dispose());
  await _settle(tree.scopes[target].dispose());
  await pumpEventQueue();
  expect(call.completions, 1);
  final trace = List<String>.of(tree.log);
  await _settle(tree.scopes[0].dispose());
  return (trace, call.outcome!);
}

/// Takes the holds of [holds] in order, and returns them by index.
List<DisposeHold> _takeHolds(_HoldTree tree, List<(int, bool)> holds) => [
  for (var h = 0; h < holds.length; h++)
    rightOf(
      tree.scopes[holds[h].$1 % tree.size].disposeHold(
        debugLabel: holds[h].$2 ? 'hold$h' : null,
      ),
    ),
];

/// The indexes of the holds in the generated close order. The rank decides,
/// and the index breaks a tie.
List<int> _closeOrder(int count, List<int> ranks) =>
    (<int>[for (var h = 0; h < count; h++) h]..sort((a, b) {
      final byRank = ranks[a].compareTo(ranks[b]);
      return byRank != 0 ? byRank : a.compareTo(b);
    }));

const Duration _holdTimeout = Duration(seconds: 5);

/// Waits for [future] up to the time limit. A law compares the result through
/// a [_Call].
Future<void> _settle(Future<Exit<DiFailure, Unit>> future) =>
    future.timeout(_holdTimeout).then<void>((_) {});

/// The parent index of scope [i] in the tree of [spec].
int _parentOf(TreeSpec spec, int i) => spec.$2[i - 1] % i;

// ---------------------------------------------------------------------------

/// A value type with a core-free key, to test the default key.
final class _Tag {
  const _Tag(this.value);
  final int value;
}

void main() {
  tearDownAll(() {
    final names = _runs.keys.toList()..sort();
    // ignore: avoid_print
    print(
      'laws: examples per law: '
      '${[for (final name in names) '$name=${_runs[name]}'].join('; ')}',
    );
  });

  group('shape laws', () {
    _law<(List<Atom>, List<Atom>)>(
      // from: laws_test.dart: 1a shape of (d1, d2).zip is the union of the two
      // shapes
      '1a shape of (d1, d2).zip is the union of the two shapes',
      combine2(_atoms, _atoms),
      (c) {
        final d1 = _build(c.$1);
        final d2 = _build(c.$2);
        expect(
          _shape((d1, d2).zip),
          equals(_unionShape([_shape(d1), _shape(d2)])),
        );
      },
    );

    _law<(List<Atom>, List<Atom>, List<Atom>)>(
      // from: laws_test.dart: 1b shape of (d1, d2, d3).zip is the union of the
      // three shapes
      '1b shape of (d1, d2, d3).zip is the union of the three shapes',
      combine3(_atoms, _atoms, _atoms),
      (c) {
        final d1 = _build(c.$1);
        final d2 = _build(c.$2);
        final d3 = _build(c.$3);
        expect(
          _shape((d1, d2, d3).zip),
          equals(_unionShape([_shape(d1), _shape(d2), _shape(d3)])),
        );
      },
    );

    _law<(List<Atom>, int, int)>(
      // from: laws_test.dart: 2 map, map with dispose, and lazy keep the shape
      '2 map, map with dispose, and lazy keep the shape',
      combine3(_atoms, integer(min: -9, max: 9), integer(min: -9, max: 9)),
      (c) {
        final d = _build(c.$1);
        final a = c.$2;
        final b = c.$3;
        final shape = _shape(d);
        expect(_shape(d.map<int>((x) => x * a + b)), equals(shape));
        expect(
          _shape(d.map<int>((x) => x * a + b, dispose: (_) {})),
          equals(shape),
        );
        expect(_shape(d.lazy()), equals(shape));
      },
    );

    _law<(List<Atom>, List<Atom>, List<Atom>)>(
      // from: laws_test.dart: 3 zip reassociation keeps the shape
      '3 zip reassociation keeps the shape',
      combine3(_atoms, _atoms, _atoms),
      (c) {
        final a = _build(c.$1);
        final b = _build(c.$2);
        final x = _build(c.$3);
        expect(
          _shape(((a, b).zip, x).zip),
          equals(_shape((a, (b, x).zip).zip)),
        );
      },
    );

    _law<List<Atom>>(
      // from: laws_test.dart: 4 generated dependency has exactly the requires
      // and optional it was built from
      '4 generated dependency has exactly the requires and optional it '
      'was built from',
      _atoms,
      (atoms) {
        expect(_shape(_build(atoms)), equals(_oracleShape(atoms)));
      },
    );
  });

  group('component laws', () {
    _law<(List<Atom>, int)>(
      // from: laws_test.dart: 5 component reports the shape of its dependency,
      // its key, and its reads
      '5 component reports the shape of its dependency, its key, and its '
      'reads',
      combine2(_atoms, integer(min: -1, max: _keyCount - 1)),
      (c) {
        final d = _build(c.$1);
        final keyIndex = c.$2;
        final Component<Object?> component = keyIndex < 0
            ? Component<int>.effect(dependency: d)
            : Component<int>(dependency: d, key: _keys[keyIndex]);
        expect(_names(component.requires), equals(_names(d.requires)));
        expect(_names(component.optional), equals(_names(d.optional)));
        expect(
          _names(component.collectionKeys),
          equals(_names(d.collectionKeys)),
        );
        expect(
          _names(component.optionalCollectionKeys),
          equals(_names(d.optionalCollectionKeys)),
        );
        if (keyIndex < 0) {
          expect(component.hasKey, isFalse);
        } else {
          expect(component.key, equals(_keys[keyIndex]));
        }
        expect(
          _names(component.reads),
          equals(
            (<String>{for (final part in _oracleShape(c.$1)) ...part}.toList()
              ..sort()),
          ),
        );
      },
    );

    test('without a key, a component of a core-free type publishes '
        'DiKey<T>()', () {
      // from: laws_test.dart: 5 without a key, a component of a core-free type
      // publishes DiKey<T>()
      final component = Component<_Tag>(
        dependency: Dependency<int>(create: () => 1).map<_Tag>(_Tag.new),
      );
      expect(component.key, equals(DiKey<_Tag>()));
    });

    test('without a key, a component of a core type needs a name', () async {
      // from: laws_test.dart: 5 without a key, a component of a core type
      // needs a name
      final scope = Scope(
        components: [
          Component<int>(dependency: Dependency<int>(create: () => 1)),
        ],
      );
      expect(await failureOfRun(scope), isA<UnnamedKeyFailure>());
    });
  });

  group('group laws', () {
    _law<GroupSpec>(
      // from: laws_test.dart: 6 publishes(m) is the union of the member keys
      '6 publishes(m) is the union of the member keys',
      _groupSpec,
      (spec) {
        final m = _group(spec);
        final expected = <DiKeyBase>{
          for (final member in spec.$1)
            if (member.$2 >= 0) _keys[member.$2],
        };
        expect(_names(m.publishes), equals(_names(expected)));
      },
    );

    _law<GroupSpec>(
      // from: laws_test.dart: 7 requires(m) is the union of the member
      // requires that no other member publishes
      '7 requires(m) is the union of the member requires that no other '
      'member publishes',
      _groupSpec,
      (spec) {
        final m = _group(spec);
        final expected = <DiKeyBase>{};
        for (var i = 0; i < spec.$1.length; i++) {
          for (final (kind, index) in spec.$1[i].$1) {
            if (kind != 0) continue;
            var publishedElsewhere = false;
            for (var j = 0; j < spec.$1.length; j++) {
              if (j != i && spec.$1[j].$2 == index) publishedElsewhere = true;
            }
            if (!publishedElsewhere) expected.add(_keys[index]);
          }
        }
        expect(_names(m.requires), equals(_names(expected)));
      },
    );

    _law<GroupSpec>(
      // from: laws_test.dart: 8 requires(m) is a subset of reads(m)
      '8 requires(m) is a subset of reads(m)',
      _groupSpec,
      (spec) {
        final m = _group(spec);
        expect(_missing(m.requires, m.reads), isEmpty);
      },
    );

    _law<(GroupSpec, GroupSpec)>(
      // from: laws_test.dart: 11 publishes(m1 + m2) is publishes(m1) union
      // publishes(m2)
      '11 publishes(m1 + m2) is publishes(m1) union publishes(m2)',
      combine2(_groupSpec, _groupSpec),
      (c) {
        final m1 = _group(c.$1);
        final m2 = _group(c.$2);
        expect(
          _names([...m1, ...m2].publishes),
          equals(_names(<DiKeyBase>{...m1.publishes, ...m2.publishes})),
        );
      },
    );

    _law<(GroupSpec, GroupSpec)>(
      // from: laws_test.dart: 12 requires(m1 + m2) is a subset of requires(m1)
      // union requires(m2)
      '12 requires(m1 + m2) is a subset of requires(m1) union requires(m2)',
      combine2(_groupSpec, _groupSpec),
      (c) {
        final m1 = _group(c.$1);
        final m2 = _group(c.$2);
        expect(
          _missing([...m1, ...m2].requires, <DiKeyBase>{
            ...m1.requires,
            ...m2.requires,
          }),
          isEmpty,
        );
      },
    );

    _law<(GroupSpec, Set<int>, Set<int>)>(
      // from: laws_test.dart: 13 requiring and withoutRequiring partition the
      // members in declaration order
      '13 requiring and withoutRequiring partition the members in '
      'declaration order',
      combine3(_groupSpec, _keyIndexes, _keyIndexes),
      (c) {
        final m = _group(c.$1);
        final keys = <DiKeyBase>[for (final i in c.$2) _keys[i]];
        final ancestors = <DiKeyBase>[for (final i in c.$3) _keys[i]];
        final membersBefore = List<Component<Object?>>.of(m);
        final requiresBefore = _names(m.requires);

        final with_ = m.requiring(keys: keys, ancestorKeys: ancestors);
        final without = m.withoutRequiring(keys: keys, ancestorKeys: ancestors);

        List<int> indexes(List<Component<Object?>> part) => <int>[
          for (final member in part) m.indexWhere((x) => identical(x, member)),
        ];
        final inWith = indexes(with_);
        final inWithout = indexes(without);
        expect(inWith, orderedEquals(<int>[...inWith]..sort()));
        expect(inWithout, orderedEquals(<int>[...inWithout]..sort()));
        expect(inWith, isNot(contains(-1)));
        expect(inWithout, isNot(contains(-1)));
        expect(
          <int>[...inWith, ...inWithout]..sort(),
          orderedEquals(<int>[for (var i = 0; i < m.length; i++) i]),
        );

        final keyNames = _names(keys).toSet();
        for (final member in without) {
          expect(
            _names(member.requires).where(keyNames.contains),
            isEmpty,
            reason: 'a member of withoutRequiring reads a key of K',
          );
        }
        expect(
          _missing(without.requires, <DiKeyBase>{...m.requires, ...ancestors}),
          isEmpty,
        );

        expect(m, orderedEquals(membersBefore));
        expect(_names(m.requires), equals(requiresBefore));
      },
    );
  });

  group('value laws (no cancellation)', () {
    _law<ValueCase>(
      // from: laws_test.dart: 4v generated dependency computes the value it
      // was built from
      '4v generated dependency computes the value it was built from',
      combine3(_valueAtoms, _values, _flags),
      (c) async {
        final published = _published([c.$1], c.$2, c.$3);
        expect(
          await _valueOf<int>(_build(c.$1), published),
          equals(_oracleValue(c.$1, published)),
        );
      },
      examples: 50,
    );

    _law<ValueCase>(
      // from: laws_test.dart: 14 functor identity: d.map(id) has the value of
      // d
      '14 functor identity: d.map(id) has the value of d',
      combine3(_valueAtoms, _values, _flags),
      (c) async {
        final published = _published([c.$1], c.$2, c.$3);
        final d = _build(c.$1);
        expect(
          await _valueOf<int>(d.map<int>((x) => x), published),
          equals(await _valueOf<int>(d, published)),
        );
      },
      examples: 50,
    );

    _law<(ValueCase, (int, int), (int, int))>(
      // from: laws_test.dart: 15 functor composition: d.map(f).map(g) is
      // d.map(g after f)
      '15 functor composition: d.map(f).map(g) is d.map(g after f)',
      combine3(
        combine3(_valueAtoms, _values, _flags),
        combine2(integer(min: -9, max: 9), integer(min: -9, max: 9)),
        combine2(integer(min: -9, max: 9), integer(min: -9, max: 9)),
      ),
      (c) async {
        final (value, (a, b), (p, q)) = c;
        final published = _published([value.$1], value.$2, value.$3);
        final d = _build(value.$1);
        int f(int x) => x * a + b;
        int g(int x) => x * p + q;
        expect(
          await _valueOf<int>(d.map<int>(f).map<int>(g), published),
          equals(await _valueOf<int>(d.map<int>((x) => g(f(x))), published)),
        );
      },
      examples: 50,
    );

    _law<(List<Atom>, List<Atom>, List<Atom>, List<int>, List<bool>)>(
      // from: laws_test.dart: 16 zip reassociation: ((a, b), c) and (a, (b,
      // c)) hold the same values
      '16 zip reassociation: ((a, b), c) and (a, (b, c)) hold the same '
      'values',
      combine5(_valueAtoms, _valueAtoms, _valueAtoms, _values, _flags),
      (c) async {
        final (a, b, x, values, flags) = c;
        final published = _published([a, b, x], values, flags);
        final da = _build(a);
        final db = _build(b);
        final dx = _build(x);
        final left = await _valueOf<((int, int), int)>(
          ((da, db).zip, dx).zip,
          published,
        );
        final right = await _valueOf<(int, (int, int))>(
          (da, (db, dx).zip).zip,
          published,
        );
        expect((
          left.$1.$1,
          left.$1.$2,
          left.$2,
        ), equals((right.$1, right.$2.$1, right.$2.$2)));
        expect(left.$1.$1, equals(_oracleValue(a, published)));
        expect(left.$1.$2, equals(_oracleValue(b, published)));
        expect(left.$2, equals(_oracleValue(x, published)));
      },
      examples: 50,
    );

    _law<(int, List<bool>)>(
      // from: laws_test.dart: 17a reverse release: a chain of components
      // disposes in reverse creation order
      '17a reverse release: a chain of components disposes in reverse '
      'creation order',
      combine2(_chainLength, _chainFlags),
      (c) async {
        final (n, hasDispose) = c;
        final created = <int>[];
        final disposed = <int>[];
        final scope = Scope(
          components: _componentChain(n, hasDispose, null, created, disposed),
        );
        rightOf(await scope.run());
        expect(created, orderedEquals(<int>[for (var i = 0; i < n; i++) i]));
        expect(disposed, isEmpty);
        rightOf(await scope.dispose());
        expect(disposed, orderedEquals(_reverseReleases(n, hasDispose)));
      },
      examples: 50,
    );

    _law<(int, List<bool>)>(
      // from: laws_test.dart: 17b reverse release: a chain of steps in one
      // dependency disposes in reverse creation order
      '17b reverse release: a chain of steps in one dependency disposes in '
      'reverse creation order',
      combine2(_chainLength, _chainFlags),
      (c) async {
        final (n, hasDispose) = c;
        final created = <int>[];
        final disposed = <int>[];
        await _valueOfChain(n, hasDispose, null, created, disposed);
        expect(created, orderedEquals(<int>[for (var i = 0; i < n; i++) i]));
        expect(disposed, orderedEquals(_reverseReleases(n, hasDispose)));
      },
      examples: 50,
    );

    _law<(int, List<bool>, int)>(
      // from: laws_test.dart: 18a rollback: a failing member of a component
      // chain rolls back the earlier members in reverse before initialize
      // throws
      '18a rollback: a failing member of a component chain rolls back the '
      'earlier members in reverse before initialize throws',
      combine3(_chainLength, _chainFlags, integer(min: 0, max: 7)),
      (c) async {
        final (n, hasDispose, raw) = c;
        final j = raw % n;
        final created = <int>[];
        final disposed = <int>[];
        final scope = Scope(
          components: _componentChain(n, hasDispose, j, created, disposed),
        );
        expect(
          leftOf(await scope.run()).failures.first,
          isA<ActivationFailure>(),
        );
        expect(created, orderedEquals(<int>[for (var i = 0; i <= j; i++) i]));
        // The failed run rolled the scope back before it returned.
        expect(disposed, orderedEquals(_reverseReleases(j, hasDispose)));
        rightOf(await scope.dispose());
        expect(disposed, orderedEquals(_reverseReleases(j, hasDispose)));
      },
      examples: 50,
    );

    _law<(int, List<bool>, int)>(
      // from: laws_test.dart: 18b rollback: a failing step inside one
      // dependency releases the earlier steps in reverse order
      '18b rollback: a failing step inside one dependency releases the '
      'earlier steps in reverse order',
      combine3(_chainLength, _chainFlags, integer(min: 0, max: 7)),
      (c) async {
        final (n, hasDispose, raw) = c;
        final j = raw % n;
        final created = <int>[];
        final disposed = <int>[];
        final scope = Scope(
          components: <Component<Object?>>[
            Component<int>(
              dependency: _innerChain(n, hasDispose, j, created, disposed),
              key: _outKey,
            ),
          ],
        );
        expect(
          leftOf(await scope.run()).failures.first,
          isA<ActivationFailure>(),
        );
        expect(created, orderedEquals(<int>[for (var i = 0; i <= j; i++) i]));
        expect(disposed, orderedEquals(_reverseReleases(j, hasDispose)));
        rightOf(await scope.dispose());
        expect(disposed, orderedEquals(_reverseReleases(j, hasDispose)));
      },
      examples: 50,
    );
  });

  group('holds laws', () {
    _law<HoldCase>(
      // from: laws_test.dart: 19a close order and delay: every close order
      // gives the trace of the disposal without holds, and each waiting call
      // completes once
      '19a close order and delay: every close order gives the trace of the '
      'disposal without holds, and each waiting call completes once',
      _holdCase,
      (c) async {
        final (spec, rawTarget, (holds, ranks, _)) = c;
        final target = rawTarget % spec.$1;
        final (trace, outcome) = await _withoutHolds(spec, target);

        final tree = await _holdTree(spec);
        final taken = _takeHolds(tree, holds);
        final open = <int>{
          for (var h = 0; h < holds.length; h++)
            if (tree.inSubtree(holds[h].$1 % tree.size, target)) h,
        };
        expect(tree.scopes[target].openHolds, hasLength(open.length));
        final calls = <_Call>[
          _Call(tree.scopes[target].dispose()),
          _Call(tree.scopes[target].dispose()),
          // A call of a descendant joins the disposal of the target.
          for (var i = target + 1; i < tree.size; i++)
            if (tree.inSubtree(i, target)) _Call(tree.scopes[i].dispose()),
        ];

        for (final h in _closeOrder(holds.length, ranks)) {
          taken[h].close();
          taken[h].close();
          open.remove(h);
          await pumpEventQueue();
          expect(
            tree.scopes[target].openHolds,
            hasLength(open.length),
            reason: 'the holds of the subtree only shrink',
          );
          if (open.isNotEmpty) {
            expect(tree.log, isEmpty, reason: 'a hold is open: no release');
            expect(
              calls.map((call) => call.completions),
              everyElement(0),
              reason: 'a hold is open: no waiting call completes',
            );
          }
        }

        await _settle(tree.scopes[target].dispose());
        await pumpEventQueue();
        expect(tree.log, orderedEquals(trace));
        for (final call in calls) {
          expect(call.completions, 1);
          expect(call.outcome, outcome);
        }
        await _settle(tree.scopes[0].dispose());
      },
      examples: 50,
    );

    _law<HoldCase>(
      // from: laws_test.dart: 19b absorption: dispose(ignoreHolds: true)
      // releases while holds are open, and a waiting call completes with it
      '19b absorption: dispose(ignoreHolds: true) releases while holds are '
      'open, and a waiting call completes with it',
      _holdCase,
      (c) async {
        final (spec, rawTarget, (holds, _, waitFirst)) = c;
        final target = rawTarget % spec.$1;
        final (trace, outcome) = await _withoutHolds(spec, target);

        final tree = await _holdTree(spec);
        final taken = _takeHolds(tree, holds);
        final waiting = waitFirst ? _Call(tree.scopes[target].dispose()) : null;
        final ignoring = _Call(tree.scopes[target].dispose(ignoreHolds: true));
        await _settle(tree.scopes[target].dispose());
        await pumpEventQueue();
        // No hold closed, and the disposal completed.
        expect(tree.log, orderedEquals(trace));
        expect(ignoring.completions, 1);
        expect(ignoring.outcome, outcome);
        if (waiting != null) {
          expect(waiting.completions, 1);
          expect(waiting.outcome, outcome);
        }
        // A close after the disposal changes nothing, and never throws.
        for (final hold in taken) {
          hold.close();
        }
        await pumpEventQueue();
        expect(tree.log, orderedEquals(trace));
        await _settle(tree.scopes[0].dispose());
      },
      examples: 50,
    );

    _law<(TreeSpec, int, bool, bool)>(
      // from: laws_test.dart: 19c union: the holds of a child delay the
      // disposal of its parent
      '19c union: the holds of a child delay the disposal of its parent',
      combine4(_treeSpec, integer(min: 0, max: 2), boolean(), boolean()),
      (c) async {
        final (spec, rawChild, labelled, two) = c;
        // A tree of one scope has no child: the disposal of the root then
        // waits for a hold of the root itself.
        final child = spec.$1 > 1 ? 1 + rawChild % (spec.$1 - 1) : 0;
        final parent = spec.$1 > 1 ? _parentOf(spec, child) : 0;
        final (trace, outcome) = await _withoutHolds(spec, parent);

        final tree = await _holdTree(spec);
        final held = <DisposeHold>[
          rightOf(
            tree.scopes[child].disposeHold(
              debugLabel: labelled ? 'page' : null,
            ),
          ),
          if (two) rightOf(tree.scopes[child].disposeHold()),
        ];
        expect(tree.scopes[parent].openHolds, hasLength(held.length));
        final call = _Call(tree.scopes[parent].dispose());
        await pumpEventQueue();
        expect(tree.log, isEmpty);
        expect(call.completions, 0);
        for (var h = 0; h < held.length; h++) {
          held[h].close();
          await pumpEventQueue();
          if (h < held.length - 1) {
            expect(tree.log, isEmpty, reason: 'a hold of the child is open');
            expect(call.completions, 0);
          }
        }
        await _settle(tree.scopes[parent].dispose());
        await pumpEventQueue();
        expect(tree.log, orderedEquals(trace));
        expect(call.completions, 1);
        expect(call.outcome, outcome);
        await _settle(tree.scopes[0].dispose());
      },
      examples: 50,
    );

    _law<HoldCase>(
      // from: laws_test.dart: 19d no hold opens after the request: disposeHold
      // throws DisposedScopeError in the subtree
      '19d no hold opens after the request: disposeHold throws '
      'DisposedScopeError in the subtree',
      _holdCase,
      (c) async {
        final (spec, rawTarget, (holds, ranks, _)) = c;
        final target = rawTarget % spec.$1;
        final tree = await _holdTree(spec);
        final taken = _takeHolds(tree, holds);
        final open = <int>{
          for (var h = 0; h < holds.length; h++)
            if (tree.inSubtree(holds[h].$1 % tree.size, target)) h,
        };
        final call = _Call(tree.scopes[target].dispose());
        final outside = <DisposeHold>[];
        for (var i = 0; i < tree.size; i++) {
          if (tree.inSubtree(i, target)) {
            expect(
              leftOf(tree.scopes[i].disposeHold()),
              isA<DisposedScopeFailure>(),
            );
            expect(
              leftOf(tree.scopes[i].disposeHold(debugLabel: 'late')),
              isA<DisposedScopeFailure>(),
            );
          } else {
            // A scope outside the subtree still takes a hold.
            outside.add(rightOf(tree.scopes[i].disposeHold()));
          }
        }
        // The rejected calls left no hold behind.
        expect(tree.scopes[target].openHolds, hasLength(open.length));
        await pumpEventQueue();
        expect(call.completions, open.isEmpty ? anyOf(0, 1) : 0);

        for (final h in _closeOrder(holds.length, ranks)) {
          taken[h].close();
        }
        await _settle(tree.scopes[target].dispose());
        // After the disposal, the request of the scope still stands.
        expect(
          leftOf(tree.scopes[target].disposeHold()),
          isA<DisposedScopeFailure>(),
        );
        expect(call.completions, 1);
        for (final hold in outside) {
          hold.close();
        }
        await _settle(tree.scopes[0].dispose());
      },
      examples: 50,
    );
  });
}

/// Runs the inner chain to the end, then disposes the scope.
Future<void> _valueOfChain(
  int n,
  List<bool> hasDispose,
  int? failAt,
  List<int> created,
  List<int> disposed,
) async {
  final scope = Scope(
    components: <Component<Object?>>[
      Component<int>(
        dependency: _innerChain(n, hasDispose, failAt, created, disposed),
        key: _outKey,
      ),
    ],
  );
  rightOf(await scope.run());
  await scope.dispose();
}
