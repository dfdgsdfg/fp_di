// Support library of the random lifecycle histories (V-T-VR-TEST-005).
//
// The harness, the graph descriptors, and the behavior that the fuzz test
// (`lifecycle_fuzz_test.dart`) and the defect controls
// (`lifecycle_fuzz_defect_test.dart`) share.
import 'dart:async';
import 'dart:math';

import 'package:fp_di/fp_di.dart';
import 'package:fp_di/tooling.dart';
import 'package:kiri_check/kiri_check.dart' show constantFrom, integer;
import 'package:kiri_check/stateful_test.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Graph descriptor
// ---------------------------------------------------------------------------

/// How a `create` or `dispose` callback settles.
enum CallbackMode {
  /// Registers a gate and waits. A `Resolve` completes the gate.
  gate,

  /// Returns or throws at once.
  synchronous,

  /// Returns a future that completes in a microtask.
  microtask,
}

/// The mode of one callback, and for a callback without a gate the
/// invocations that fail, by the number of the invocation of that callback.
final class CallbackDesc {
  const CallbackDesc(this.mode, [this.failing = const <int>{}]);

  final CallbackMode mode;

  /// The numbers of the failing invocations. Empty for a gate.
  final Set<int> failing;

  String describe() {
    if (mode == CallbackMode.gate) return 'gate';
    final fails = failing.toList()..sort();
    return fails.isEmpty ? mode.name : '${mode.name} fail${fails.join('+')}';
  }
}

/// What a component publishes.
enum PubKind {
  /// One plain key.
  key,

  /// A contribution to a set key.
  contribution,

  /// One entry of a map key.
  entry,
}

/// The publication of a component: a plain key, a contribution to a set key,
/// or an entry of a map key.
final class PubDesc {
  const PubDesc.key(this.name) : kind = PubKind.key, id = null;
  const PubDesc.contribution(this.name)
    : kind = PubKind.contribution,
      id = null;
  const PubDesc.entry(this.name, String this.id) : kind = PubKind.entry;

  final PubKind kind;

  /// The name of the plain key, of the set key, or of the map key.
  final String name;

  /// The id of an entry, else null.
  final String? id;

  /// The identity of the plain key or of the entry key, else null for a
  /// contribution. Two publications with one key identity shadow each other
  /// when two scopes of one chain hold them.
  String? get keyId => switch (kind) {
    PubKind.key => 'k:$name',
    PubKind.entry => 'e:$name/$id',
    PubKind.contribution => null,
  };

  /// The key that the component publishes, else null for a contribution.
  DiKey<int>? get key => switch (kind) {
    PubKind.key => plainKey(name),
    PubKind.entry => mapKeyOf(name).entryKey(id!),
    PubKind.contribution => null,
  };

  String describe() => switch (kind) {
    PubKind.key => name,
    PubKind.entry => '$name[$id]',
    PubKind.contribution => 'into $name',
  };
}

/// How a component reads one key.
enum ReadKind {
  /// `Dependency.require` of a plain key or of a map entry key.
  plain,

  /// `Dependency.maybe` of a plain key.
  optional,

  /// `Dependency.requireSet`.
  requireSet,

  /// `Dependency.maybeSet`.
  maybeSet,

  /// `Dependency.requireMap`.
  requireMap,

  /// `Dependency.maybeMap`.
  maybeMap,
}

/// One read of a component.
final class ReadDesc {
  const ReadDesc(this.kind, this.name, [this.id]);

  final ReadKind kind;

  /// The name of the plain key, of the set key, or of the map key.
  final String name;

  /// The id of the entry that a plain read names, else null.
  final String? id;

  bool get isSet => kind == ReadKind.requireSet || kind == ReadKind.maybeSet;
  bool get isMap => kind == ReadKind.requireMap || kind == ReadKind.maybeMap;
  bool get isCollection => isSet || isMap;

  /// Whether the read waits for its keys.
  bool get strict =>
      kind == ReadKind.plain ||
      kind == ReadKind.requireSet ||
      kind == ReadKind.requireMap;

  /// The identity of the plain key or of the entry key of a plain or an
  /// optional read.
  String get keyId => id == null ? 'k:$name' : 'e:$name/$id';

  /// The key of a plain or an optional read.
  DiKey<int> get key =>
      id == null ? plainKey(name) : mapKeyOf(name).entryKey(id!);

  /// The collection key of a set or a map read.
  DiCollectionKey<int> get collectionKey =>
      isSet ? setKeyOf(name) : mapKeyOf(name);

  /// The key whose reads two reads of one component MUST NOT repeat.
  String get slot => isCollection ? '${isSet ? 'set' : 'map'}:$name' : keyId;

  /// Whether this read selects [pub] as one of its publishers.
  bool readsPub(PubDesc pub) => switch (kind) {
    ReadKind.plain || ReadKind.optional => pub.keyId == keyId,
    ReadKind.requireSet ||
    ReadKind.maybeSet => pub.kind == PubKind.contribution && pub.name == name,
    ReadKind.requireMap ||
    ReadKind.maybeMap => pub.kind == PubKind.entry && pub.name == name,
  };

  /// The kind of the shape edge of this read.
  ShapeEdgeKind get edgeKind => switch (kind) {
    ReadKind.plain => ShapeEdgeKind.require,
    ReadKind.optional => ShapeEdgeKind.optional,
    ReadKind.requireSet || ReadKind.requireMap => ShapeEdgeKind.collection,
    ReadKind.maybeSet || ReadKind.maybeMap => ShapeEdgeKind.optionalCollection,
  };

  String describe() => switch (kind) {
    ReadKind.plain => 'require ${id == null ? name : '$name[$id]'}',
    ReadKind.optional => 'maybe $name',
    ReadKind.requireSet => 'requireSet $name',
    ReadKind.maybeSet => 'maybeSet $name',
    ReadKind.requireMap => 'requireMap $name',
    ReadKind.maybeMap => 'maybeMap $name',
  };
}

DiKey<int> plainKey(String name) => DiKey<int>(name: name);
DiMapKey<int> mapKeyOf(String name) => DiMapKey<int>(name: name);
DiSetKey<int> setKeyOf(String name) => DiSetKey<int>(name: name);

/// A component of the fixture graph.
final class NodeDesc {
  const NodeDesc(
    this.name,
    this.scope,
    this.pub,
    this.reads,
    this.steps, {
    this.creates = const [],
    this.disposes = const [],
  });

  /// The unique name and label of the component: `s<scope>n<order>`.
  final String name;

  /// The index of the scope that declares the component.
  final int scope;

  /// What the component publishes.
  final PubDesc pub;

  /// The reads of the component: zero to two, of components that come earlier
  /// in the dependency order, in its scope or in an ancestor scope.
  final List<ReadDesc> reads;

  /// The number of steps: one or two.
  final int steps;

  /// The `create` callback of each step.
  final List<CallbackDesc> creates;

  /// The `dispose` callback of each step.
  final List<CallbackDesc> disposes;

  NodeDesc withCallbacks(
    List<CallbackDesc> creates,
    List<CallbackDesc> disposes,
  ) => NodeDesc(
    name,
    scope,
    pub,
    reads,
    steps,
    creates: creates,
    disposes: disposes,
  );
}

/// One scope of the tree, with its module in declaration order.
final class ScopeDesc {
  const ScopeDesc(
    this.parent,
    this.nodes, {
    this.requiringKeys = const [],
    this.ancestorKeys = const [],
  });

  /// The index of the parent scope, or -1 for the root.
  final int parent;

  /// The components of the module, in declaration order.
  final List<NodeDesc> nodes;

  /// The identities of the `keys` of the `requiring` check: one or two keys
  /// that the module or an ancestor publishes. Empty when none is published.
  final List<String> requiringKeys;

  /// The identities of the `ancestorKeys` of the `requiring` check: zero or
  /// one published key.
  final List<String> ancestorKeys;
}

/// The call sites that a descriptor fixes. A site draws no random value at
/// call time. A target is a number: a site resolves it at the call, by the
/// remainder of the number over the targets that the harness state offers.
final class CallSites {
  const CallSites({
    this.creates = const {},
    this.disposes = const {},
    this.listeners = const {},
    this.subscriber,
    this.throwScope = -1,
    this.throwCall = -1,
  });

  /// The sites at the start of a `create`, by `node/step`. The target is -1
  /// for the scope of the node, else the number of a held member handle.
  final Map<String, int> creates;

  /// The sites at the start of a `dispose` callback, by `node/step`. The target
  /// is the number of a disposal that a command requested.
  final Map<String, int> disposes;

  /// The scopes whose listener has a site, with the target of its request.
  final Map<int, int> listeners;

  /// The target of the site of the `errors` subscriber, else null.
  final int? subscriber;

  /// The scope whose listener throws a tagged error, and the number of the
  /// call of that listener at which it throws. -1 for none.
  final int throwScope;
  final int throwCall;

  String describe(GraphDesc graph) {
    String target(int t) => t < 0 ? 'own scope' : 'target $t';
    String list(Map<Object, int> sites, String Function(Object) name) =>
        sites.isEmpty
        ? '-'
        : sites.entries
              .map((e) => '${name(e.key)} -> ${target(e.value)}')
              .join(', ');
    final throwing = throwScope < 0
        ? '-'
        : '${graph.scopeName(throwScope)} at call $throwCall';
    return 'call sites:\n'
        '  create starts: ${list(creates, (k) => '$k')}\n'
        '  dispose starts: ${list(disposes, (k) => '$k')}\n'
        '  listeners: ${list(listeners, (k) => graph.scopeName(k as int))}\n'
        '  errors subscriber: '
        '${subscriber == null ? '-' : target(subscriber!)}\n'
        '  throwing listener: $throwing';
  }
}

/// The graph of one case. The same descriptor serves every rerun and every
/// shrink candidate of the case.
final class GraphDesc {
  GraphDesc(
    this.seed,
    this.index,
    this.scopes, [
    this.sites = const CallSites(),
  ]) {
    for (var s = 0; s < scopes.length; s++) {
      for (var i = 0; i < scopes[s].nodes.length; i++) {
        final n = scopes[s].nodes[i];
        _byName[n.name] = n;
        _declIndex[n.name] = i;
      }
    }
  }

  final int seed;
  final int index;

  /// The scopes. A parent comes before its children.
  final List<ScopeDesc> scopes;

  /// The call sites and the throwing listener.
  final CallSites sites;

  final Map<String, NodeDesc> _byName = {};
  final Map<String, int> _declIndex = {};

  Iterable<NodeDesc> get all => scopes.expand((s) => s.nodes);

  NodeDesc node(String name) => _byName[name]!;

  /// The position of the component in the declaration order of its module.
  int declIndex(String name) => _declIndex[name]!;

  String scopeName(int s) => s == 0 ? 'root' : 'scope$s';

  /// The scope [s] and its ancestors, nearest first.
  List<int> chain(int s) => [for (var j = s; j >= 0; j = scopes[j].parent) j];

  /// The ancestors of [s], root first.
  List<int> ancestors(int s) => chain(s).skip(1).toList().reversed.toList();

  /// Whether [s] is the second child of the root.
  bool isSecondChild(int s) => s > 1 && scopes[s].parent == 0;

  /// Whether [s] is a child of a child.
  bool isGrandchild(int s) => s > 0 && scopes[s].parent > 0;

  /// The scopes below [s], at any depth.
  List<int> descendants(int s) => [
    for (var d = 0; d < scopes.length; d++)
      if (d != s && chain(d).contains(s)) d,
  ];

  /// The plain keys and the entry keys that a scope of the chain of [s]
  /// publishes, by key identity.
  Map<String, DiKey<int>> lookupKeys(int s) => {
    for (final j in chain(s))
      for (final n in scopes[j].nodes)
        if (n.pub.keyId != null) n.pub.keyId!: n.pub.key!,
  };

  /// The seed of the kiri_check property of this graph.
  int get propertySeed => (seed * 1000003 + index * 7919 + 1) & 0x3fffffff;

  String describe() {
    String line(NodeDesc n) {
      final modes = [
        for (var i = 0; i < n.steps; i++)
          's$i create ${n.creates[i].describe()}, '
              'dispose ${n.disposes[i].describe()}',
      ];
      final reads = n.reads.isEmpty
          ? '-'
          : n.reads.map((r) => r.describe()).join(', ');
      return '${n.name}(publishes: ${n.pub.describe()}; reads: $reads; '
          'steps: ${n.steps}; ${modes.join('; ')})';
    }

    final out = StringBuffer();
    for (var s = 0; s < scopes.length; s++) {
      final parent = scopes[s].parent;
      out.writeln(
        '${scopeName(s)} (index $s'
        '${parent < 0 ? '' : ', child of ${scopeName(parent)}'}) '
        'in declaration order:',
      );
      for (final n in scopes[s].nodes) {
        out.writeln('  ${line(n)}');
      }
      out.writeln(
        '  requiring keys: ${scopes[s].requiringKeys}, '
        'ancestor keys: ${scopes[s].ancestorKeys}',
      );
    }
    out.write(sites.describe(this));
    return out.toString().trimRight();
  }
}

final class _Draft {
  _Draft(this.scope, this.order, this.pub, this.steps);

  final int scope;
  final int order;
  final PubDesc pub;
  final int steps;

  /// The position in the dependency order of the whole graph. An ancestor is
  /// before each of its descendants.
  int global = 0;
  List<ReadDesc> reads = [];

  String get name => 's${scope}n$order';
}

/// Builds the graph of [seed] and [index]. With [gatesOnly], every callback is
/// a gate without a failing invocation, so a fixed history that names gates
/// by position does not depend on the modes that the seed draws.
GraphDesc buildGraph(int seed, int index, {bool gatesOnly = false}) {
  final rnd = Random((seed * 1000003 + index * 104729 + 12345) & 0x3fffffff);

  // The tree: the root, its first child, and as drawn a second child of the
  // root and a child of the first child.
  final parents = <int>[-1, 0];
  if (rnd.nextInt(100) < 75) parents.add(0);
  if (rnd.nextInt(100) < 75) parents.add(1);
  final sizes = [
    for (var s = 0; s < parents.length; s++)
      s == 0 ? 3 + rnd.nextInt(3) : 1 + rnd.nextInt(3),
  ];
  List<int> chainOf(int s) => [for (var j = s; j >= 0; j = parents[j]) j];

  // The publications, in the dependency order of the whole graph.
  const mapIds = ['a', 'b', 'c', 'd'];
  var keyCounter = 0;
  final drafts = <_Draft>[];
  for (var s = 0; s < parents.length; s++) {
    final ancestorScopes = chainOf(s).skip(1).toSet();
    final used = <String>{};
    // A module MAY open with two contributions to one set, or with two
    // entries of one map, so a collection read has more than one value.
    final theme = rnd.nextInt(100);
    final themeIds = [...mapIds]..shuffle(rnd);
    for (var k = 0; k < sizes[s]; k++) {
      // A key or an entry that an ancestor publishes and this module does not.
      final shadowable = <PubDesc>[];
      final seen = <String>{};
      for (final d in drafts) {
        final id = d.pub.keyId;
        if (id == null || !ancestorScopes.contains(d.scope)) continue;
        if (used.contains(id) || !seen.add(id)) continue;
        shadowable.add(d.pub);
      }
      PubDesc plain() {
        final options = [
          for (final p in shadowable)
            if (p.kind == PubKind.key) p,
        ];
        if (options.isNotEmpty && rnd.nextInt(100) < 70) {
          return options[rnd.nextInt(options.length)];
        }
        return PubDesc.key('k${keyCounter++}');
      }

      PubDesc entry() {
        final options = [
          for (final p in shadowable)
            if (p.kind == PubKind.entry) p,
        ];
        if (options.isNotEmpty && rnd.nextInt(100) < 45) {
          return options[rnd.nextInt(options.length)];
        }
        final map = rnd.nextInt(100) < 70 ? 'M0' : 'M1';
        final free = [
          for (final id in mapIds)
            if (!used.contains('e:$map/$id')) id,
        ];
        if (free.isEmpty) return PubDesc.key('k${keyCounter++}');
        return PubDesc.entry(map, free[rnd.nextInt(free.length)]);
      }

      final roll = rnd.nextInt(100);
      PubDesc pub;
      final shadowKeys = [
        for (final p in shadowable)
          if (p.kind == PubKind.key || rnd.nextBool()) p,
      ];
      if (s > 0 && k == 0 && shadowKeys.isNotEmpty && rnd.nextInt(100) < 60) {
        // The first member of a module shadows a key of an ancestor.
        pub = shadowKeys[rnd.nextInt(shadowKeys.length)];
      } else if (k < 2 && sizes[s] >= 2 && theme >= 35) {
        pub = theme < 65
            ? const PubDesc.contribution('S0')
            : PubDesc.entry('M0', themeIds[k]);
      } else {
        pub = roll < 40
            ? plain()
            : roll < 72
            ? PubDesc.contribution(rnd.nextInt(100) < 75 ? 'S0' : 'S1')
            : entry();
      }
      // A module publishes each key and each entry once.
      if (pub.keyId != null && used.contains(pub.keyId)) {
        pub = PubDesc.key('k${keyCounter++}');
      }
      if (pub.keyId != null) used.add(pub.keyId!);
      drafts.add(_Draft(s, k, pub, 1 + rnd.nextInt(2)));
    }
  }
  for (var g = 0; g < drafts.length; g++) {
    drafts[g].global = g;
  }

  // The reads. A read selects every publisher of its key in the chain of the
  // reader, so each of those publishers MUST come earlier than the reader.
  // The reads then form no cycle.
  for (final x in drafts) {
    final chain = chainOf(x.scope).toSet();
    final others = [
      for (final d in drafts)
        if (chain.contains(d.scope) && !identical(d, x)) d,
    ];
    bool earlier(ReadDesc r) {
      final targets = [
        for (final d in others)
          if (r.readsPub(d.pub)) d,
      ];
      return targets.isNotEmpty && targets.every((d) => d.global < x.global);
    }

    final plain = <ReadDesc>[];
    final shadowed = <ReadDesc>[];
    final optional = <ReadDesc>[];
    final sets = <ReadDesc>[];
    final maps = <ReadDesc>[];
    final seenSlots = <String>{};
    for (final d in others) {
      final pub = d.pub;
      if (pub.keyId != null && pub.keyId != x.pub.keyId) {
        final r = pub.kind == PubKind.key
            ? ReadDesc(ReadKind.plain, pub.name)
            : ReadDesc(ReadKind.plain, pub.name, pub.id);
        if (seenSlots.add(r.slot) && earlier(r)) {
          plain.add(r);
          // A key that two scopes of the chain publish is read more often.
          final holders = others.where((o) => o.pub.keyId == pub.keyId).length;
          if (holders > 1) shadowed.add(r);
          if (pub.kind == PubKind.key) {
            optional.add(ReadDesc(ReadKind.optional, pub.name));
            // A key of another scope is read optionally more often: it is
            // absent while that scope is not initialized.
            if (d.scope != x.scope) {
              optional.add(ReadDesc(ReadKind.optional, pub.name));
            }
          }
        }
      } else if (pub.kind == PubKind.contribution) {
        final r = ReadDesc(ReadKind.requireSet, pub.name);
        if (seenSlots.add(r.slot) && earlier(r)) {
          sets.add(r);
          // A collection with two contributions is read more often.
          if (others.where((o) => r.readsPub(o.pub)).length > 1) sets.add(r);
        }
      }
      if (pub.kind == PubKind.entry) {
        final r = ReadDesc(ReadKind.requireMap, pub.name);
        if (seenSlots.add(r.slot) && earlier(r)) {
          maps.add(r);
          if (others.where((o) => r.readsPub(o.pub)).length > 1) maps.add(r);
        }
      }
    }
    final roll = rnd.nextInt(100);
    final count = roll < 20 ? 0 : (roll < 55 ? 1 : 2);
    final taken = <String>{};
    final reads = <ReadDesc>[];
    // A key that two scopes of the chain publish is read more often, so a
    // nearer scope shadows the read of a reader that sees both.
    final shadowRead = shadowed.isNotEmpty && rnd.nextInt(100) < 85;
    for (var i = 0; i < max(count, shadowRead ? 1 : 0); i++) {
      if (i == 0 && shadowRead) {
        final r = shadowed[rnd.nextInt(shadowed.length)];
        if (taken.add(r.slot)) reads.add(r);
        continue;
      }
      final options = <(int, List<ReadDesc>)>[
        if (plain.isNotEmpty) (34, plain),
        if (optional.isNotEmpty) (24, optional),
        if (sets.isNotEmpty) (20, sets),
        if (maps.isNotEmpty) (20, maps),
      ];
      if (options.isEmpty) break;
      final total = options.fold<int>(0, (sum, o) => sum + o.$1);
      var pick = rnd.nextInt(total);
      var chosen = options.first.$2;
      for (final o in options) {
        if (pick < o.$1) {
          chosen = o.$2;
          break;
        }
        pick -= o.$1;
      }
      var r = chosen[rnd.nextInt(chosen.length)];
      if (r.kind == ReadKind.requireSet && rnd.nextInt(100) < 38) {
        r = ReadDesc(ReadKind.maybeSet, r.name);
      } else if (r.kind == ReadKind.requireMap && rnd.nextInt(100) < 38) {
        r = ReadDesc(ReadKind.maybeMap, r.name);
      }
      if (taken.add(r.slot)) reads.add(r);
    }
    x.reads = reads;
  }
  // The graph reads something in the root, so the shuffle below has an edge
  // to invert.
  if (drafts.where((d) => d.scope == 0).every((d) => d.reads.isEmpty)) {
    final root = drafts.where((d) => d.scope == 0).toList();
    for (var i = root.length - 1; i > 0 && root[i].reads.isEmpty; i--) {
      final target = root.take(i).where((d) => d.pub.keyId != null).toList();
      if (target.isEmpty) continue;
      final t = target[rnd.nextInt(target.length)].pub;
      root[i].reads = [
        t.kind == PubKind.key
            ? ReadDesc(ReadKind.plain, t.name)
            : ReadDesc(ReadKind.plain, t.name, t.id),
      ];
    }
  }
  // The graph reads a key of the same scope optionally, so an optional read
  // also gives a value: a key of another scope is often absent. A separate
  // stream decides it, so the graphs that already have such a read keep their
  // draws. A graph of gates only keeps its reads.
  bool sameScopeKey(_Draft reader, ReadDesc r) => drafts.any(
    (d) =>
        d.scope == reader.scope &&
        d.pub.kind == PubKind.key &&
        d.pub.name == r.name &&
        d.global < reader.global,
  );
  final hasOptionalValue = drafts.any(
    (x) => x.reads.any(
      (r) => r.kind == ReadKind.optional && sameScopeKey(x, r),
    ),
  );
  if (!gatesOnly && !hasOptionalValue) {
    final candidates = <(_Draft, int)>[
      for (final x in drafts)
        for (var i = 0; i < x.reads.length; i++)
          if (x.reads[i].kind == ReadKind.plain &&
              x.reads[i].id == null &&
              sameScopeKey(x, x.reads[i]))
            (x, i),
    ];
    if (candidates.isNotEmpty) {
      final pick = Random(
        (seed * 1000003 + index * 104729 + 55667) & 0x3fffffff,
      );
      final (x, i) = candidates[pick.nextInt(candidates.length)];
      x.reads = [
        for (var j = 0; j < x.reads.length; j++)
          j == i ? ReadDesc(ReadKind.optional, x.reads[j].name) : x.reads[j],
      ];
    }
  }
  for (var s = 0; s < parents.length; s++) {
    final module = drafts.where((d) => d.scope == s).toList();
    if (s == 0 && module.every((d) => d.steps == 1)) {
      final last = module.last;
      drafts[last.global] = _Draft(last.scope, last.order, last.pub, 2)
        ..global = last.global
        ..reads = last.reads;
    }
  }

  // The descriptor MUST NOT rely on the shape check to find a wrong draw: a
  // module publishes each key once, and each publisher that a read selects in
  // the chain of the reader comes earlier than the reader.
  for (final x in drafts) {
    final chain = chainOf(x.scope).toSet();
    for (final y in drafts) {
      if (identical(x, y) || y.scope != x.scope) continue;
      if (x.pub.keyId != null && x.pub.keyId == y.pub.keyId) {
        throw StateError(
          'graph $seed/$index: ${x.name} and ${y.name} '
          'publish ${x.pub.keyId} in one module',
        );
      }
    }
    for (final r in x.reads) {
      final targets = [
        for (final y in drafts)
          if (chain.contains(y.scope) && !identical(x, y) && r.readsPub(y.pub))
            y,
      ];
      if (targets.any((y) => y.global >= x.global) ||
          (!r.isCollection && x.pub.keyId == r.keyId)) {
        throw StateError(
          'graph $seed/$index: ${x.name} reads ${r.describe()} '
          'from a later or an own publisher',
        );
      }
    }
  }

  // The declaration order of each module. A reader before its publisher makes
  // a release in reverse declaration order violate `DependentFirst`.
  bool inverted(List<_Draft> order) {
    final position = {for (var i = 0; i < order.length; i++) order[i]: i};
    return order.any(
      (x) => x.reads.any(
        (r) => order.any(
          (t) =>
              !identical(t, x) &&
              r.readsPub(t.pub) &&
              position[x]! < position[t]!,
        ),
      ),
    );
  }

  final declared = <List<_Draft>>[];
  for (var s = 0; s < parents.length; s++) {
    final module = [
      for (final d in drafts)
        if (d.scope == s) d,
    ];
    var order = [...module];
    var tries = 0;
    do {
      order.shuffle(rnd);
    } while (!inverted(order) && ++tries < 50);
    if (!inverted(order)) order = module.reversed.toList();
    declared.add(order);
  }

  // The callback modes come from a second source of the same seed and index,
  // so the shape of the graph above stays as it is. They are drawn in the
  // order of the names, never at the call of a callback.
  final modeRnd = Random(
    (seed * 1000003 + index * 104729 + 54321) & 0x3fffffff,
  );
  CallbackDesc drawCallback({required bool dispose}) {
    final m = modeRnd.nextInt(100);
    if (gatesOnly || m < 45) return const CallbackDesc(CallbackMode.gate);
    final mode = m < 72 ? CallbackMode.synchronous : CallbackMode.microtask;
    final f = modeRnd.nextInt(100);
    // A dispose fails a little more often than a create, so a successful
    // initialize stays frequent.
    final none = dispose ? 66 : 76;
    final failing = f < none
        ? <int>{}
        : f < none + 12
        ? <int>{0}
        : f < none + 18
        ? <int>{1}
        : <int>{0, 1};
    return CallbackDesc(mode, failing);
  }

  // A failed automatic activation needs a `create` that fails during a
  // reconciliation, not inside `initialize`: a failed `initialize` rolls back
  // and leaves no failed node. A member of a child scope that reads a strict
  // key of an ancestor waits when its scope initializes before the ancestor,
  // and activates when the ancestor does. The descriptor therefore marks up to
  // three such members, from a source of its own, and fixes their first
  // `create` invocation to fail. A member whose key an ancestor also publishes
  // is not marked, because a lookup of its key would read the ancestor. The
  // third mark MAY take a contribution, whose failure only a strict collection
  // reader shows. A graph that has no member to mark gains a plain read of an
  // ancestor key in a child member, as far as the member has fewer than two
  // reads.
  final failFirst = <String, CallbackMode>{};
  if (!gatesOnly) {
    final failRnd = Random(
      (seed * 1000003 + index * 104729 + 11223) & 0x3fffffff,
    );
    final waits = <_Draft, bool>{};
    bool waitsOnAncestor(_Draft d) => waits[d] ??= d.reads.any((r) {
      if (!r.strict) return false;
      final publishers = [
        for (final o in drafts)
          if (chainOf(d.scope).contains(o.scope) &&
              !identical(o, d) &&
              r.readsPub(o.pub))
            o,
      ];
      if (r.isCollection) {
        return publishers.any((o) => o.scope != d.scope || waitsOnAncestor(o));
      }
      final own = publishers.where((o) => o.scope == d.scope);
      final ancestor = publishers.where((o) => o.scope != d.scope);
      if (own.isEmpty) return ancestor.isNotEmpty;
      return ancestor.isEmpty && own.any(waitsOnAncestor);
    });
    bool shadows(_Draft d) =>
        d.pub.keyId != null &&
        chainOf(d.scope).skip(1).any(
          (j) => drafts.any((o) => o.scope == j && o.pub.keyId == d.pub.keyId),
        );
    for (final chance in const [85, 65, 45]) {
      List<_Draft> candidates() => [
        for (final d in drafts)
          if (d.scope > 0 &&
              !failFirst.containsKey(d.name) &&
              (d.pub.keyId != null || chance < 50) &&
              !shadows(d) &&
              waitsOnAncestor(d))
            d,
      ];
      final roll = failRnd.nextInt(100);
      final pick = failRnd.nextInt(1 << 20);
      final convert = failRnd.nextInt(1 << 20);
      final mode = failRnd.nextBool()
          ? CallbackMode.synchronous
          : CallbackMode.microtask;
      if (roll >= chance) continue;
      var options = candidates();
      if (options.isEmpty) {
        // A read of an ancestor key that this member does not publish and its
        // own scope does not publish.
        final convertible = <(_Draft, PubDesc)>[
          for (final d in drafts)
            if (d.scope > 0 &&
                d.pub.keyId != null &&
                d.reads.length < 2 &&
                !shadows(d) &&
                !failFirst.containsKey(d.name))
              for (final o in drafts)
                if (o.scope != d.scope &&
                    chainOf(d.scope).contains(o.scope) &&
                    o.pub.keyId != null &&
                    !drafts.any(
                      (m) => m.scope == d.scope && m.pub.keyId == o.pub.keyId,
                    ))
                  (d, o.pub),
        ];
        if (convertible.isEmpty) continue;
        final (d, pub) = convertible[convert % convertible.length];
        final read = pub.kind == PubKind.key
            ? ReadDesc(ReadKind.plain, pub.name)
            : ReadDesc(ReadKind.plain, pub.name, pub.id);
        if (d.reads.any((r) => r.slot == read.slot)) continue;
        d.reads = [...d.reads, read];
        waits.clear();
        options = candidates();
        if (options.isEmpty) continue;
      }
      final d = options[pick % options.length];
      failFirst[d.name] = mode;
    }
  }

  // Two contributions to one set key in a child scope may wait for an ancestor
  // key each and fail at their first `create`, with a keyed strict reader of
  // that set key. The reader then waits for two failed nodes at once, so a
  // lookup of its key lists two failed nodes in the order of the collection.
  if (!gatesOnly) {
    final pairRnd = Random(
      (seed * 1000003 + index * 104729 + 33445) & 0x3fffffff,
    );
    final roll = pairRnd.nextInt(100);
    final pickReader = pairRnd.nextInt(1 << 20);
    final pickAncestor = pairRnd.nextInt(1 << 20);
    if (roll < 90) {
      search:
      for (var sc = 1; sc < parents.length; sc++) {
        final ancestorScopes = chainOf(sc).skip(1).toSet();
        final ancestorKeys = [
          for (final o in drafts)
            if (ancestorScopes.contains(o.scope) &&
                o.pub.keyId != null &&
                !drafts.any(
                  (m) => m.scope == sc && m.pub.keyId == o.pub.keyId,
                ))
              o,
        ];
        if (ancestorKeys.isEmpty) continue;
        for (final name in const ['S0', 'S1']) {
          final contributors = [
            for (final d in drafts)
              if (d.scope == sc &&
                  d.pub.kind == PubKind.contribution &&
                  d.pub.name == name)
                d,
          ];
          if (contributors.length < 2) continue;
          final c1 = contributors[0];
          final c2 = contributors[1];
          if (c1.reads.length > 1 || c2.reads.length > 1) continue;
          final read = ReadDesc(ReadKind.requireSet, name);
          final readers = [
            for (final r in drafts)
              if (r.pub.keyId != null &&
                  chainOf(r.scope).contains(sc) &&
                  !identical(r, c1) &&
                  !identical(r, c2) &&
                  r.reads.length < 2 &&
                  !r.reads.any((x) => x.slot == read.slot) &&
                  drafts
                      .where(
                        (o) =>
                            chainOf(r.scope).contains(o.scope) &&
                            !identical(o, r) &&
                            read.readsPub(o.pub),
                      )
                      .every((o) => o.global < r.global))
                r,
          ];
          if (readers.isEmpty) continue;
          for (final (i, c) in [c1, c2].indexed) {
            final a = ancestorKeys[(pickAncestor + i) % ancestorKeys.length];
            final waiting = ReadDesc(
              ReadKind.plain,
              a.pub.name,
              a.pub.kind == PubKind.key ? null : a.pub.id,
            );
            if (!c.reads.any((x) => x.slot == waiting.slot)) {
              c.reads = [...c.reads, waiting];
            }
            failFirst[c.name] = i == 0
                ? CallbackMode.synchronous
                : CallbackMode.microtask;
          }
          final reader = readers[pickReader % readers.length];
          reader.reads = [...reader.reads, read];
          break search;
        }
      }
    }
  }

  final withModes = <String, NodeDesc>{};
  for (final d in drafts) {
    final creates = <CallbackDesc>[];
    final disposes = <CallbackDesc>[];
    for (var s = 0; s < d.steps; s++) {
      creates.add(drawCallback(dispose: false));
      disposes.add(drawCallback(dispose: true));
    }
    final marked = failFirst[d.name];
    if (marked != null) {
      final first = creates[0];
      creates[0] = CallbackDesc(
        first.mode == CallbackMode.gate ? marked : first.mode,
        {...first.failing, 0},
      );
    }
    withModes[d.name] = NodeDesc(
      d.name,
      d.scope,
      d.pub,
      d.reads,
      d.steps,
      creates: creates,
      disposes: disposes,
    );
  }

  // The call sites come from a third source of the same seed and index, so the
  // shape and the modes above stay as they are. They are drawn in the order of
  // the names, never at the call of a callback.
  final siteRnd = Random(
    (seed * 1000003 + index * 104729 + 98765) & 0x3fffffff,
  );
  var sites = const CallSites();
  if (!gatesOnly) {
    final creates = <String, int>{};
    final disposes = <String, int>{};
    for (final d in drafts) {
      for (var step = 0; step < d.steps; step++) {
        // A create requests the disposal of its own scope more often: the
        // runtime MUST reject it, and the scope has no request yet.
        if (siteRnd.nextInt(100) < 30) {
          creates['${d.name}/$step'] = siteRnd.nextInt(100) < 60
              ? -1
              : siteRnd.nextInt(8);
        }
        if (siteRnd.nextInt(100) < 30) {
          disposes['${d.name}/$step'] = siteRnd.nextInt(8);
        }
      }
    }
    final listeners = <int, int>{};
    for (var s = 0; s < parents.length; s++) {
      if (siteRnd.nextInt(100) < 60) listeners[s] = siteRnd.nextInt(8);
    }
    final subscriber = siteRnd.nextInt(100) < 70 ? siteRnd.nextInt(8) : null;
    sites = CallSites(
      creates: creates,
      disposes: disposes,
      listeners: listeners,
      subscriber: subscriber,
      throwScope: siteRnd.nextInt(parents.length),
      throwCall: siteRnd.nextInt(5),
    );
  }

  // The keys of the `requiring` check come from a fourth source of the same
  // seed and index, so the shape, the modes, and the sites above stay as they
  // are. For each module, one or two published keys of the module or of an
  // ancestor, and zero or one published key. Only a key that a member
  // plain-reads selects a member, so such a key comes up more often. The first
  // key is also the key that a member reads and that publishes a key that
  // another member reads, so a selection runs through two members. The
  // `ancestorKeys` key is also the key that a selected member publishes and
  // another member reads, so the ancestor keeps a reader.
  final partitionRnd = Random(
    (seed * 1000003 + index * 104729 + 24680) & 0x3fffffff,
  );
  List<String> plainKeysOf(_Draft d) => [
    for (final r in d.reads)
      if (r.kind == ReadKind.plain) r.keyId,
  ];
  final requiringKeys = <List<String>>[];
  final ancestorKeys = <List<String>>[];
  for (var s = 0; s < parents.length; s++) {
    final module = declared[s];
    final pool = <String>{
      for (final j in chainOf(s))
        for (final d in declared[j])
          if (d.pub.keyId != null) d.pub.keyId!,
    }.toList();
    final read = [
      for (final id in pool)
        if (module.any((d) => plainKeysOf(d).contains(id))) id,
    ];
    final heads = [
      for (final id in read)
        if (module.any(
          (a) =>
              a.pub.keyId != null &&
              plainKeysOf(a).contains(id) &&
              module.any(
                (b) => !identical(a, b) && plainKeysOf(b).contains(a.pub.keyId),
              ),
        ))
          id,
    ];
    String pick([List<String>? from]) {
      final options =
          from ??
          (read.isNotEmpty && partitionRnd.nextInt(100) < 75 ? read : pool);
      return options[partitionRnd.nextInt(options.length)];
    }

    final keys = <String>[];
    final ancestors = <String>[];
    if (pool.isNotEmpty) {
      keys.add(heads.isNotEmpty && partitionRnd.nextInt(100) < 60
          ? pick(heads)
          : pick());
      if (partitionRnd.nextInt(100) < 35) {
        final second = pick();
        if (!keys.contains(second)) keys.add(second);
      }
      // The members that the keys select, without an ancestor key.
      final absent = <String>{...keys};
      final selected = <_Draft>{};
      for (var changed = true; changed;) {
        changed = false;
        for (final d in module) {
          if (selected.contains(d) || !plainKeysOf(d).any(absent.contains)) {
            continue;
          }
          selected.add(d);
          changed = true;
          if (d.pub.keyId != null) absent.add(d.pub.keyId!);
        }
      }
      final kept = [
        for (final a in module)
          if (selected.contains(a) &&
              a.pub.keyId != null &&
              module.any((b) => plainKeysOf(b).contains(a.pub.keyId)))
            a.pub.keyId!,
      ];
      final roll = partitionRnd.nextInt(100);
      if (roll < 50 && kept.isNotEmpty) {
        ancestors.add(pick(kept));
      } else if (roll < 75) {
        ancestors.add(pick());
      }
    }
    requiringKeys.add(keys);
    ancestorKeys.add(ancestors);
  }
  return GraphDesc(seed, index, [
    for (var s = 0; s < parents.length; s++)
      ScopeDesc(
        parents[s],
        [for (final d in declared[s]) withModes[d.name]!],
        requiringKeys: requiringKeys[s],
        ancestorKeys: ancestorKeys[s],
      ),
  ], sites);
}

/// A `create` callback of a step. The values that the step received are the
/// values of its reads, or the value of the first step of its node.
typedef CreateHook =
    FutureOr<int> Function(String node, int step, List<Object?> received);
typedef ReleaseHook = FutureOr<void> Function(String node, int step, int acq);

Dependency<Object?> _readOf(ReadDesc r) => switch (r.kind) {
  ReadKind.plain => Dependency.require<int>(key: r.key),
  ReadKind.optional => Dependency.maybe<int>(key: r.key),
  ReadKind.requireSet => Dependency.requireSet<int>(key: setKeyOf(r.name)),
  ReadKind.maybeSet => Dependency.maybeSet<int>(key: setKeyOf(r.name)),
  ReadKind.requireMap => Dependency.requireMap<int>(key: mapKeyOf(r.name)),
  ReadKind.maybeMap => Dependency.maybeMap<int>(key: mapKeyOf(r.name)),
};

Component<int> _component(NodeDesc n, CreateHook create, ReleaseHook release) {
  final reads = [for (final r in n.reads) _readOf(r)];
  FutureOr<void> dispose0(int a) => release(n.name, 0, a);
  final Dependency<int> first = switch (reads.length) {
    0 => Dependency<int>(
      create: () => create(n.name, 0, const []),
      dispose: dispose0,
    ),
    1 => reads[0].map<int>((v) => create(n.name, 0, [v]), dispose: dispose0),
    _ => (
      reads[0],
      reads[1],
    ).zip.map<int>((v) => create(n.name, 0, [v.$1, v.$2]), dispose: dispose0),
  };
  final last = n.steps == 1
      ? first
      : first.map<int>(
          (v) => create(n.name, 1, [v]),
          dispose: (a) => release(n.name, 1, a),
        );
  return switch (n.pub.kind) {
    PubKind.contribution => Component<int>.into(
      key: setKeyOf(n.pub.name),
      debugLabel: n.name,
      dependency: last,
    ),
    _ => Component<int>(key: n.pub.key, debugLabel: n.name, dependency: last),
  };
}

/// The module of each scope of [graph], by scope index.
List<Module> buildModules(
  GraphDesc graph,
  CreateHook create,
  ReleaseHook release,
) => [
  for (var s = 0; s < graph.scopes.length; s++)
    Module(
      components: [
        for (final n in graph.scopes[s].nodes) _component(n, create, release),
      ],
      debugLabel: graph.scopeName(s),
    ),
];

/// The shape JSON of each module, for a report.
String shapeReport(GraphDesc graph) {
  final modules = buildModules(graph, (_, _, _) => 0, (_, _, _) {});
  final out = StringBuffer();
  for (var s = 0; s < modules.length; s++) {
    final json = ShapeGraph.of(
      modules[s],
      ancestorModules: [for (final a in graph.ancestors(s)) modules[a]],
    ).toJson();
    out.writeln('Shape (${graph.scopeName(s)} module):\n$json');
  }
  return out.toString().trimRight();
}

// ---------------------------------------------------------------------------
// Trace, gates, and held futures
// ---------------------------------------------------------------------------

enum Phase { start, end, fail }

final class TraceEvent {
  TraceEvent(
    this.seq,
    this.phase,
    this.kind,
    this.node,
    this.step,
    this.acq,
    this.mode,
  );

  final int seq;
  final Phase phase;
  final String kind;
  final String node;
  final int step;
  final int acq;
  final CallbackMode mode;

  @override
  String toString() =>
      '#$seq ${phase.name.padRight(5)} ${kind.padRight(7)} '
      '$node.s$step a$acq (${mode.name})';
}

/// One acquisition: a `create` callback and the `dispose` it owes.
///
/// The value of the acquisition is its number [id].
final class Acq {
  Acq(this.id, this.node, this.step, this.received, this.reads);

  final int id;
  final String node;
  final int step;

  /// The values that the `create` received: the values of the reads of a
  /// first step, or the value of the first step for a second step.
  final List<Object?> received;

  /// The acquisitions of other nodes that this acquisition reads: the numbers
  /// that its `create` received, in any set or map as well, and the ones that
  /// an earlier step of its node received.
  final Set<int> reads;

  /// A `create` that started and has not settled.
  bool createOpen = false;
  bool created = false;
  int createSeq = -1;
  int disposeStarts = 0;
  int firstDisposeSeq = -1;
  bool disposeFinished = false;
}

final class Gate {
  Gate(this.id, this.kind, this.node, this.step, this.acq);

  final int id;
  final String kind;
  final String node;
  final int step;
  final int acq;
  final Completer<void> completer = Completer<void>();
}

/// The error that a gate or a failing invocation of the descriptor throws.
final class TaggedError implements Exception {
  TaggedError(this.label, {required this.dispose});

  final String label;

  /// Whether a `dispose` gate threw it. Otherwise a `create` gate did.
  final bool dispose;

  @override
  String toString() => 'TaggedError($label)';
}

/// A future that a command returned, with its recorded result.
final class Held {
  Held(this.label, this.future, this.source, this.scope, {this.retry = false});

  final String label;
  final Future<Object?> future;

  /// `initialize` or `dispose`.
  final String source;

  /// The index of the scope that an `initialize` call started, else null.
  final int? scope;

  /// Whether this is a `RetryInitialize` call.
  final bool retry;
  bool explained = false;
  bool done = false;
  bool ok = false;
  Object? error;
}

/// One `dispose()` call: `first` starts the disposal of its owner, `join`
/// runs while the first disposal is in progress, and `late` runs after it
/// completed.
final class DisposeCall {
  DisposeCall(this.held, this.kind, this.owner);

  final Held held;
  final String kind;
  final String owner;
}

final class ScopeInfo {
  ScopeInfo(this.index, this.name, this.scope);

  final int index;
  final String name;
  final Scope scope;
  bool initializeCalled = false;
  bool initialized = false;
  Held? initFuture;
  List<(String, ComponentNode<Object?>)>? handles;

  /// The state of this scope that its listener kept at each call, with a copy
  /// of its members (V-T-RT-LC-032).
  final List<(ScopeState, String)> heard = [];

  /// The calls of the probe listener of this scope, and whether it threw. The
  /// probe is a second listener, so `heard` keeps its last value after the
  /// probe left.
  int probeCalls = 0;
  bool probeThrew = false;
}

/// A mutation request that a call site made, with its recorded result.
final class SiteCall {
  SiteCall(
    this.label,
    this.target,
    this.held, {
    required this.fromCreate,
    this.owner,
    this.late = false,
    this.disposedBefore = false,
  });

  /// The site, and the target of the request.
  final String label;
  final String target;

  /// The recorded result. Not a member of `Harness.held`.
  final Held held;

  /// Whether the site is the start of a `create`.
  final bool fromCreate;

  /// The owner of the disposal that the request joins, else null.
  final String? owner;

  /// Whether the first disposal of [owner] was complete at the request.
  final bool late;

  /// Whether the member handle was in the phase `disposed` before the request.
  final bool disposedBefore;
  bool explained = false;
}

final class Teardown {
  Teardown(this.owner, this.nodes, this.fromSeq);

  final String owner;
  final Set<String> nodes;
  final int fromSeq;

  /// Whether a check counted this teardown for a release on a gate.
  bool countedGate = false;
}

/// A broken invariant, or a harness defect, with the evidence.
final class HistoryViolation implements Exception {
  HistoryViolation(this.report);

  final String report;

  @override
  String toString() => report;
}

final class FuzzStats {
  static int cycles = 0;
  static int initialized = 0;
  static int skipped = 0;
  static int overlapNodes = 0;
  static int commands = 0;
  static int teardowns = 0;
  static int joins = 0;

  /// The joining calls whose first disposal completed with an error.
  static int joinsOnFailure = 0;
  static int lateCalls = 0;
  static int memberCalls = 0;
  static int createFailures = 0;
  static int disposeFailures = 0;
  static int errorEvents = 0;
  static int transitions = 0;

  /// The calls of `initialize` that `RetryInitialize` made.
  static int retryCalls = 0;

  /// The retries of `initialize` that completed with success.
  static int retrySuccesses = 0;

  /// The teardowns that `ReleaseOverlap` checked while a release waited on a
  /// gate.
  static int overlapGateTeardowns = 0;

  /// The scopes that initialized: a child of a child, and a second child of
  /// the root.
  static int grandchildInitialized = 0;
  static int secondChildInitialized = 0;

  /// The plain reads, at the start of a `create`, whose key a nearer scope
  /// shadows: the value came from a scope that has an ancestor with a
  /// component of the same key.
  static int shadowedReads = 0;

  /// The optional reads that received `null`, and the ones that received a
  /// value.
  static int optionalNulls = 0;
  static int optionalValues = 0;

  /// The set reads and the map reads that received at least one value.
  static int setReadsWithValue = 0;
  static int mapReadsWithValue = 0;
  static int setReadsMany = 0;
  static int shadowedMapIds = 0;
  static int mapReadsMany = 0;

  /// The mutation requests of the call sites, the requests from a `create`
  /// that the runtime rejected, the requests from another site that it
  /// accepted (a join or a late success), the requests from another site that
  /// it rejected, and the reports of the listener that throws.
  static int siteRequests = 0;
  static int createRejected = 0;
  static int siteAccepted = 0;

  /// The accepted requests by site: `dispose`, `listener`, or `errors`, and
  /// by `join` or `late`.
  static final Map<String, int> acceptedBy = {};
  static int siteRejected = 0;
  static int listenerReports = 0;

  /// The `get` calls that `UnavailableCause` checked, the ones whose first
  /// node waits, the ones whose search reached a collection key, the ones with
  /// a non-empty `failedNodeStates`, and the ones with more than one element.
  static int getsChecked = 0;
  static int getsWaiting = 0;
  static int getsCollection = 0;
  static int getsWithFailedNodes = 0;
  static int getsWithManyFailedNodes = 0;

  /// The observations of a node in the phase `activationFailed`, after a
  /// command.
  static int failedNodeObservations = 0;

  /// The modules that `RequiringPartition` checked, the ones whose `requiring`
  /// holds a member, the ones with a member that only a key of another member
  /// selects, and the ones where `ancestorKeys` kept a reader.
  static int partitionsChecked = 0;
  static int partitionsSelecting = 0;
  static int partitionsTransitive = 0;
  static int partitionsAncestorKept = 0;

  /// The count of each explained result, by source and result type.
  static final Map<String, int> outcomes = {};

  /// The count of each settled callback, as `kind/mode/ok` or `kind/mode/fail`.
  static final Map<String, int> callbacks = {};
  static int acquisitions = 0;

  static void accepted(SiteCall call) {
    siteAccepted++;
    final key = '${call.label.split(' ').first}/${call.late ? 'late' : 'join'}';
    acceptedBy[key] = (acceptedBy[key] ?? 0) + 1;
  }

  static void callback(String kind, CallbackMode mode, {required bool ok}) {
    final key = '$kind/${mode.name}/${ok ? 'ok' : 'fail'}';
    callbacks[key] = (callbacks[key] ?? 0) + 1;
  }

  static String _text(Map<String, int> counts) {
    final keys = counts.keys.toList()..sort();
    return keys.map((k) => '$k:${counts[k]}').join(',');
  }

  /// The floors of this stage that the run did not reach.
  static List<String> missingFloors() => [
    for (final kind in const ['create', 'dispose'])
      for (final mode in CallbackMode.values)
        for (final ok in const [true, false])
          if ((callbacks['$kind/${mode.name}/${ok ? 'ok' : 'fail'}'] ?? 0) == 0)
            'a ${ok ? 'completed' : 'failed'} $kind of mode ${mode.name}',
    if (retrySuccesses == 0) 'a successful retry of initialize',
    if (overlapGateTeardowns == 0)
      'a teardown that ReleaseOverlap checked while a release waited on a gate',
    if (grandchildInitialized == 0) 'an initialized child of a child',
    if (secondChildInitialized == 0) 'an initialized second child of the root',
    if (shadowedReads == 0) 'a plain read that a nearer scope shadows',
    if (optionalNulls == 0) 'an optional read of null',
    if (optionalValues == 0) 'an optional read of a value',
    if (setReadsWithValue == 0) 'a set read with a value',
    if (mapReadsWithValue == 0) 'a map read with a value',
    if (createRejected == 0) 'a rejected mutation request from a create',
    if (siteAccepted == 0) 'an accepted request from another call site',
    if (listenerReports == 0) 'a report of the listener that throws',
    if (getsWithFailedNodes == 0) 'a get with a non-empty failedNodeStates',
  ];

  static String summary() =>
      'cycles=$cycles rootsInitialized=$initialized commands=$commands '
      'acquisitions=$acquisitions teardowns=$teardowns '
      'teardownsSkipped=$skipped teardownNodes=$overlapNodes '
      'joinCalls=$joins joinsOnFailure=$joinsOnFailure lateCalls=$lateCalls '
      'memberDisposeCalls=$memberCalls createFailures=$createFailures '
      'disposeFailures=$disposeFailures errorsEvents=$errorEvents '
      'transitions=$transitions retryCalls=$retryCalls '
      'retrySuccesses=$retrySuccesses '
      'overlapGateTeardowns=$overlapGateTeardowns '
      'grandchildInitialized=$grandchildInitialized '
      'secondChildInitialized=$secondChildInitialized '
      'shadowedReads=$shadowedReads optionalNulls=$optionalNulls '
      'optionalValues=$optionalValues setReadsWithValue=$setReadsWithValue '
      'mapReadsWithValue=$mapReadsWithValue setReadsMany=$setReadsMany '
      'mapReadsMany=$mapReadsMany shadowedMapIds=$shadowedMapIds '
      'siteRequests=$siteRequests createRejected=$createRejected '
      'siteAccepted=$siteAccepted(${_text(acceptedBy)}) '
      'siteRejected=$siteRejected '
      'listenerReports=$listenerReports '
      'getsChecked=$getsChecked getsWaiting=$getsWaiting '
      'getsCollection=$getsCollection '
      'getsWithFailedNodes=$getsWithFailedNodes '
      'getsWithManyFailedNodes=$getsWithManyFailedNodes '
      'failedNodeObservations=$failedNodeObservations '
      'partitionsChecked=$partitionsChecked '
      'partitionsSelecting=$partitionsSelecting '
      'partitionsTransitive=$partitionsTransitive '
      'partitionsAncestorKept=$partitionsAncestorKept '
      'callbacks=${_text(callbacks)} '
      'outcomes=${_text(outcomes)}';
}

// ---------------------------------------------------------------------------
// Harness (the System of the behavior)
// ---------------------------------------------------------------------------

/// Every acquisition number in [value]: a plain number, the numbers of a set,
/// and the values of a map. `null` has none.
void _collectNumbers(Object? value, Set<int> out) {
  switch (value) {
    case final int number:
      out.add(number);
    case final Iterable<Object?> items:
      for (final item in items) {
        _collectNumbers(item, out);
      }
    case final Map<Object?, Object?> map:
      for (final item in map.values) {
        _collectNumbers(item, out);
      }
    default:
  }
}

final class Harness {
  Harness(this.graph) {
    modules = buildModules(graph, _create, _release);
    scopes = List<ScopeInfo?>.filled(graph.scopes.length, null);
    _shapeCheck();
    _requiringCheck();
    _throwIfViolated();
    final rootScope = Scope(
      module: modules[0],
      slowMutationThreshold: const Duration(days: 1),
    );
    final info = ScopeInfo(0, graph.scopeName(0), rootScope);
    scopes[0] = info;
    _errorsSub = rootScope.errors.listen(_onError);
    _listen(info);
  }

  final GraphDesc graph;
  late final List<Module> modules;
  late final StreamSubscription<DiException> _errorsSub;

  /// The scopes by index. A scope that no `CreateChild` made is null.
  late final List<ScopeInfo?> scopes;
  final List<TraceEvent> trace = [];
  final List<Gate> gates = [];
  final Map<int, Acq> acqs = {};
  final Map<String, List<Acq>> acqsByNode = {};
  final List<Held> held = [];
  final List<DisposeCall> calls = [];
  final Map<String, Held> firstDisposal = {};
  final List<Object> errorEvents = [];
  final Set<String> withdrawn = {};

  /// The mutation requests of the call sites.
  final List<SiteCall> siteCalls = [];

  /// The site calls of the running command, whose late calls MUST complete
  /// with success at the end of the command.
  final List<SiteCall> _newSiteCalls = [];

  /// The ids of the disposals whose first call has not returned. A listener
  /// runs inside the `dispose` call, after the runtime recorded the disposal.
  final Set<String> _inFlight = {};

  /// The tagged error that the listener that throws threw, else null.
  TaggedError? listenerError;
  int _eventsChecked = 0;
  final List<TaggedError> failedDisposeErrors = [];
  final Set<String> failedCreate = {};
  final List<Teardown> teardowns = [];
  final List<String> violations = [];
  final List<(Held, int, String)> _pendingLate = [];
  int _nextAcq = 0;
  int _nextGate = 0;
  int _createSeq = 0;
  int disposeStartCount = 0;

  /// The revision and the state of each scope at the check before.
  int? _revisionBefore;
  final Map<int, ScopeState> _stateBefore = {};

  ScopeInfo get root => scopes[0]!;

  Iterable<ScopeInfo> get live => scopes.whereType<ScopeInfo>();

  /// One listener of [info] keeps the state of its scope at each call.
  void _listen(ScopeInfo info) {
    _guard('addListener(${info.name})', () {
      info.scope.addListener(() {
        final value = info.scope.state;
        info.heard.add((value, _printState(value)));
        FuzzStats.transitions++;
      });
    });
    _guard('addListener probe(${info.name})', () {
      info.scope.addListener(() => _probe(info));
    });
  }

  /// The second listener of a scope. It reads and requests at its site, and the
  /// listener that the descriptor names throws a tagged error at its call.
  void _probe(ScopeInfo info) {
    final call = info.probeCalls++;
    if (info.probeThrew) {
      _violate(
        'ListenerFailure: the listener of ${info.name} was called again '
        'after it threw (call $call)',
      );
    }
    final site = graph.sites.listeners[info.index];
    if (site != null) {
      final label = 'listener of ${info.name} call $call';
      _siteReads(label, info.index);
      _requestOther(label, site);
    }
    if (graph.sites.throwScope == info.index &&
        graph.sites.throwCall == call &&
        !info.probeThrew) {
      info.probeThrew = true;
      final error = TaggedError(
        'listener of ${info.name} call $call',
        dispose: false,
      );
      listenerError = error;
      throw error;
    }
  }

  void _onError(DiException event) {
    errorEvents.add(event);
    final site = graph.sites.subscriber;
    if (site != null) _requestOther('errors subscriber', site);
  }

  /// Every member of [state] as a text.
  static String _printState(ScopeState state, [String indent = '']) {
    final out = StringBuffer('$indent${state.phase.name}');
    for (final node in state.nodeStates) {
      out.write(
        '\n$indent  ${node.id} ${node.label} ${node.key} ${node.phase.name} '
        '${node.missing} ${identityHashCode(node.activationException)} '
        '${node.commits}',
      );
    }
    for (final child in state.childStates) {
      out.write('\n${_printState(child, '$indent  ')}');
    }
    return '$out';
  }

  Future<void> close() => _errorsSub.cancel();

  // -- shape check ----------------------------------------------------------

  /// The edges of each module are the reads of the descriptor between the
  /// members of that module, with the kind of the read. The members of an
  /// ancestor give no edge.
  void _shapeCheck() {
    for (var s = 0; s < graph.scopes.length; s++) {
      final nodes = graph.scopes[s].nodes;
      final expected = <String>[
        for (var i = 0; i < nodes.length; i++)
          for (final r in nodes[i].reads)
            for (var j = 0; j < nodes.length; j++)
              if (j != i && r.readsPub(nodes[j].pub))
                '$i>$j:${r.edgeKind.name}',
      ]..sort();
      final shape = ShapeGraph.of(
        modules[s],
        ancestorModules: [for (final a in graph.ancestors(s)) modules[a]],
      );
      final actual = <String>[
        for (final e in shape.edges) '${e.from}>${e.to}:${e.kind.name}',
      ]..sort();
      final name = graph.scopeName(s);
      if (expected.join(',') != actual.join(',')) {
        _violate(
          'ShapeCheck: $name edges $actual differ from the descriptor '
          '$expected',
        );
      }
      if (shape.undeclared.isNotEmpty) {
        _violate('ShapeCheck: $name undeclared ${shape.undeclared}');
      }
      if (shape.duplicates.isNotEmpty) {
        _violate('ShapeCheck: $name duplicates ${shape.duplicates}');
      }
      if (shape.cycles.isNotEmpty) {
        _violate('ShapeCheck: $name cycles ${shape.cycles}');
      }
    }
  }

  // -- callbacks ------------------------------------------------------------

  /// The number of the next invocation of each callback, by kind, node, step.
  final Map<String, int> _invocations = {};

  int _invocation(String kind, String node, int step) {
    final key = '$kind/$node/$step';
    final number = _invocations[key] ?? 0;
    _invocations[key] = number + 1;
    return number;
  }

  FutureOr<int> _create(String node, int step, List<Object?> received) {
    final desc = graph.node(node).creates[step];
    final invocation = _invocation('create', node, step);
    final id = _nextAcq++;
    final Set<int> reads;
    if (step == 0) {
      reads = {};
      _collectNumbers(received, reads);
    } else {
      final first = received.isEmpty ? null : received.first;
      final earlier = first is int ? acqs[first] : null;
      if (earlier == null || earlier.node != node || earlier.step != step - 1) {
        _violate(
          'HarnessDefect: the second step of $node received $received, '
          'not the value of its first step',
        );
      }
      reads = {...?earlier?.reads};
    }
    final a = Acq(id, node, step, [...received], reads);
    acqs[id] = a;
    acqsByNode.putIfAbsent(node, () => []).add(a);
    a.createOpen = true;
    _record(Phase.start, 'create', a, desc.mode);
    if (step == 0) _checkReadsCurrent(a);
    final createSite = graph.sites.creates['$node/$step'];
    if (createSite != null) _createSite(a, createSite);
    final fail = desc.failing.contains(invocation);
    switch (desc.mode) {
      case CallbackMode.gate:
        final g = Gate(_nextGate++, 'create', node, step, id);
        gates.add(g);
        return g.completer.future.then((_) => id);
      case CallbackMode.synchronous:
        final error = _finish(a, 'create', desc.mode, fail: fail);
        if (error != null) throw error;
        return id;
      case CallbackMode.microtask:
        return Future<int>.microtask(() {
          final error = _finish(a, 'create', desc.mode, fail: fail);
          if (error != null) throw error;
          return id;
        });
    }
  }

  FutureOr<void> _release(String node, int step, int acq) {
    final desc = graph.node(node).disposes[step];
    final invocation = _invocation('dispose', node, step);
    final a = acqs[acq]!;
    final seq = _record(Phase.start, 'dispose', a, desc.mode);
    _disposeStart(a, seq);
    final disposeSite = graph.sites.disposes['$node/$step'];
    if (disposeSite != null) {
      final label = 'dispose ${a.node}.s${a.step} a${a.id}';
      _siteReads(label, graph.node(node).scope);
      _requestOther(label, disposeSite);
    }
    final fail = desc.failing.contains(invocation);
    switch (desc.mode) {
      case CallbackMode.gate:
        final g = Gate(_nextGate++, 'dispose', node, step, acq);
        gates.add(g);
        return g.completer.future;
      case CallbackMode.synchronous:
        final error = _finish(a, 'dispose', desc.mode, fail: fail);
        if (error != null) throw error;
        return null;
      case CallbackMode.microtask:
        return Future<void>.microtask(() {
          final error = _finish(a, 'dispose', desc.mode, fail: fail);
          if (error != null) throw error;
        });
    }
  }

  // -- call sites (NestedCall) -----------------------------------------------

  /// The reads of a site: `revision`, `state`, and `maybeGet`, `findNode`, and
  /// `get` of each plain key that the graph declares for the scope chain of
  /// [s]. A read throws nothing but a `DisposedScopeError` after a disposal of
  /// the scope or of an ancestor was requested, and `get` may throw an
  /// `UnavailableKeyException`. The reads leave `revision` as it was.
  void _siteReads(String label, int s) {
    final info = scopes[s]!;
    final scope = info.scope;
    final disposalRequested = _effectivelyRequested(s);
    final before = scope.revision;
    void attempt(
      String what,
      void Function() read, {
      bool unavailable = false,
    }) {
      try {
        read();
      } on DisposedScopeError {
        if (!disposalRequested) {
          _violate(
            'NestedCall: $what at $label threw DisposedScopeError, and no '
            'disposal of ${info.name} or of an ancestor was requested',
          );
        }
      } on UnavailableKeyException {
        if (!unavailable) {
          _violate('NestedCall: $what at $label threw UnavailableKeyException');
        }
      } on Object catch (error) {
        _violate('NestedCall: $what at $label threw ${_show(error)}');
      }
    }

    attempt('revision', () => scope.revision);
    attempt('state', () => scope.state);
    for (final MapEntry(key: keyId, value: key)
        in graph.lookupKeys(s).entries) {
      attempt('maybeGet($keyId)', () => scope.maybeGet<int>(key: key));
      attempt('findNode($keyId)', () => scope.findNode<int>(key: key));
      attempt(
        'get($keyId)',
        () => scope.get<int>(key: key),
        unavailable: true,
      );
    }
    final after = scope.revision;
    if (after != before) {
      _violate(
        'NestedCall: the reads at $label changed revision from $before to '
        '$after',
      );
    }
  }

  /// Records the result of the request [future] of a site, with handlers
  /// that run at once.
  SiteCall _watchSite(
    String label,
    String target,
    Future<void> future, {
    required bool fromCreate,
    String? owner,
    bool late = false,
    bool disposedBefore = false,
  }) {
    FuzzStats.siteRequests++;
    final h = Held(label, future, 'dispose', null);
    unawaited(
      future.then<void>(
        (_) {
          h
            ..done = true
            ..ok = true;
        },
        onError: (Object error, StackTrace _) {
          h
            ..done = true
            ..error = error;
        },
      ),
    );
    final call = SiteCall(
      label,
      target,
      h,
      fromCreate: fromCreate,
      owner: owner,
      late: late,
      disposedBefore: disposedBefore,
    );
    siteCalls.add(call);
    _newSiteCalls.add(call);
    return call;
  }

  /// The request at the start of a `create`: `dispose()` of its own scope, or
  /// of a held member handle that the target selects. The runtime MUST reject
  /// it with `ReentrantMutationError`, add no event to the trace, and leave
  /// `revision` as it was. A handle in the phase `disposed` MAY complete with
  /// success.
  void _createSite(Acq a, int target) {
    final s = graph.node(a.node).scope;
    final label = 'create ${a.node}.s${a.step} a${a.id}';
    _siteReads(label, s);
    final scope = scopes[s]!.scope;
    final handles = [
      for (final info in live) ...?info.handles,
    ];
    (String, ComponentNode<Object?>)? member;
    if (target >= 0 && handles.isNotEmpty) {
      member = handles[target % handles.length];
    }
    final disposedBefore =
        member != null && member.$2.state.phase == NodePhase.disposed;
    final what = member == null
        ? 'dispose(${graph.scopeName(s)})'
        : 'member dispose(${member.$1})';
    final revisionBefore = scope.revision;
    final traceBefore = trace.length;
    final Future<void> future;
    try {
      future = member == null ? scope.dispose() : member.$2.dispose();
    } on Object catch (error) {
      _violate('NestedCall: $what at $label threw ${_show(error)}');
      return;
    }
    _watchSite(
      label,
      what,
      future,
      fromCreate: true,
      disposedBefore: disposedBefore,
    );
    if (scope.revision != revisionBefore) {
      _violate(
        'NestedCall: $what at $label changed revision from $revisionBefore '
        'to ${scope.revision}',
      );
    }
    if (trace.length != traceBefore) {
      _violate('NestedCall: $what at $label added an event to the trace');
    }
  }

  /// The disposals that a command requested, as targets of a site: each
  /// existing scope that a request covers, and each held member handle whose
  /// withdrawal a `DisposeMember` command requested.
  List<(String, List<String>, Future<void> Function())> _requestedTargets() => [
    for (final info in live)
      if (_effectivelyRequested(info.index))
        (
          'dispose(${info.name})',
          [for (final j in graph.chain(info.index)) 'scope:$j'],
          info.scope.dispose,
        ),
    for (final info in live)
      for (final (name, node) in info.handles ??
          const <(String, ComponentNode<Object?>)>[])
        if (firstDisposal.containsKey('node:$name') ||
            _inFlight.contains('node:$name'))
          ('member dispose($name)', ['node:$name'], node.dispose),
  ];

  /// The request at a `dispose` callback, a listener, or the `errors`
  /// subscriber: `dispose()` of a scope or a member whose disposal a command
  /// already requested. Without such a disposal, the site does nothing. The
  /// runtime MAY reject the call, MUST complete a call before the end of the
  /// first disposal with the result of that disposal, and MUST complete a
  /// later call with success at once.
  void _requestOther(String label, int target) {
    final targets = _requestedTargets();
    if (targets.isEmpty) return;
    final (what, chain, call) = targets[target % targets.length];
    final owner = _ownerOf(chain);
    if (owner == null) {
      _violate('HarnessDefect: the target of $label has no requested disposal');
      return;
    }
    final first = firstDisposal[owner];
    final late = first != null && first.done;
    final Future<void> future;
    try {
      future = call();
    } on Object catch (error) {
      _violate('NestedCall: $what at $label threw ${_show(error)}');
      return;
    }
    _watchSite(
      label,
      what,
      future,
      fromCreate: false,
      owner: owner,
      late: late,
    );
  }

  /// Checks the result of each site call that completed.
  void _checkSiteCalls() {
    for (final c in siteCalls) {
      if (c.explained || !c.held.done) continue;
      final error = c.held.error;
      final result = error == null ? 'success' : _show(error);
      if (c.fromCreate) {
        c.explained = true;
        if (error is ReentrantMutationError) {
          FuzzStats.createRejected++;
        } else if (error != null || !c.disposedBefore) {
          _violate(
            'NestedCall: ${c.target} at ${c.label} completed with $result, '
            'not with ReentrantMutationError',
          );
        }
      } else if (error is ReentrantMutationError) {
        c.explained = true;
        FuzzStats.siteRejected++;
      } else if (c.late) {
        c.explained = true;
        if (error != null) {
          _violate(
            'NestedCall: ${c.target} at ${c.label} came after the disposal of '
            '${c.owner} finished, and completed with $result, not with '
            'success',
          );
        } else {
          FuzzStats.accepted(c);
        }
      }
      // A joining call completes with the result of the first disposal. The
      // final checks compare the two.
    }
  }

  int _record(Phase phase, String kind, Acq a, CallbackMode mode) {
    final seq = trace.length;
    trace.add(TraceEvent(seq, phase, kind, a.node, a.step, a.id, mode));
    return seq;
  }

  void _disposeStart(Acq a, int seq) {
    disposeStartCount++;
    a.disposeStarts++;
    if (a.disposeStarts == 1) a.firstDisposeSeq = seq;
    if (a.disposeStarts > 1) {
      _violate(
        'ReleaseAtMostOnce: a${a.id} (${a.node}.s${a.step}) '
        'has ${a.disposeStarts} dispose starts',
      );
    }
    for (final b in acqsByNode[a.node]!) {
      if (!b.created || b.createSeq <= a.createSeq) continue;
      if (b.disposeStarts == 0) {
        _violate(
          'StepOrder: dispose of a${a.id} (${a.node}.s${a.step}) starts '
          'before dispose of the later acquisition a${b.id} '
          '(${b.node}.s${b.step})',
        );
      } else if (!b.disposeFinished) {
        _violate(
          'StepSerial: dispose of a${a.id} (${a.node}.s${a.step}) starts '
          'while the dispose of the later acquisition a${b.id} '
          '(${b.node}.s${b.step}) has not finished',
        );
      }
    }
    // The readers are the acquisitions of other nodes whose `create` received
    // the value of `a` (also inside a set or a map), or whose node received it
    // in an earlier step.
    for (final b in acqs.values) {
      if (b.node == a.node || !b.reads.contains(a.id)) continue;
      if (b.createOpen) {
        _violate(
          'DependentFirst: dispose of a${a.id} (${a.node}.s${a.step}, '
          '#$seq) starts while reader a${b.id} (${b.node}.s${b.step}) has '
          'an open create',
        );
      } else if (b.created && !b.disposeFinished) {
        _violate(
          'DependentFirst: dispose of a${a.id} (${a.node}.s${a.step}, '
          '#$seq) starts while reader a${b.id} (${b.node}.s${b.step}) '
          'is not yet released',
        );
      }
    }
  }

  /// Settles a callback that [a] owns: appends its end or failure event and
  /// updates the record. Returns the tagged error of a failure, else null.
  TaggedError? _finish(
    Acq a,
    String kind,
    CallbackMode mode, {
    required bool fail,
  }) {
    FuzzStats.callback(kind, mode, ok: !fail);
    if (fail) {
      final err = TaggedError(
        '$kind ${a.node}.s${a.step} a${a.id}',
        dispose: kind == 'dispose',
      );
      _record(Phase.fail, kind, a, mode);
      if (kind == 'dispose') {
        a.disposeFinished = true;
        failedDisposeErrors.add(err);
        FuzzStats.disposeFailures++;
      } else {
        a.createOpen = false;
        failedCreate.add(a.node);
        FuzzStats.createFailures++;
      }
      return err;
    }
    _record(Phase.end, kind, a, mode);
    if (kind == 'dispose') {
      a.disposeFinished = true;
    } else {
      a.createOpen = false;
      a.created = true;
      a.createSeq = _createSeq++;
      FuzzStats.acquisitions++;
      if (a.step == graph.node(a.node).steps - 1) failedCreate.remove(a.node);
    }
    return null;
  }

  /// Completes the gate [g] with a value or a tagged error.
  void _settle(Gate g, {required bool fail}) {
    gates.remove(g);
    final error = _finish(acqs[g.acq]!, g.kind, CallbackMode.gate, fail: fail);
    if (error != null) {
      g.completer.completeError(error);
    } else {
      g.completer.complete();
    }
  }

  // -- the state of the nodes of the descriptor -------------------------------

  /// The `NodeState` of the component [n] of scope [s], or null while the
  /// scope has no nodes.
  NodeState? _stateOfNode(int s, NodeDesc n) {
    final info = scopes[s];
    if (info == null) return null;
    final states = info.scope.state.nodeStates;
    if (states.length != graph.scopes[s].nodes.length) return null;
    return states[graph.declIndex(n.name)];
  }

  bool _isActive(int s, NodeDesc n) =>
      _stateOfNode(s, n)?.phase == NodePhase.active;

  /// The nearest scope from the scope of [reader] up to the root that holds
  /// an active node of [keyId], other than [reader], with that node.
  (int, NodeDesc)? _nearestActive(NodeDesc reader, String keyId) {
    for (final s in graph.chain(reader.scope)) {
      for (final n in graph.scopes[s].nodes) {
        if (n.name == reader.name || n.pub.keyId != keyId) continue;
        if (_isActive(s, n)) return (s, n);
      }
    }
    return null;
  }

  /// The visible contributions of [reader] to the set or the map of [read]:
  /// the members of the scope of [reader] other than [reader], and of its
  /// ancestors, that contribute to the collection and are not disposed. The
  /// ancestors come first, then the declaration order. A map keeps the first
  /// position of each id.
  List<(int, NodeDesc)> _visible(NodeDesc reader, ReadDesc read) {
    final out = <(int, NodeDesc)>[];
    final ids = <String>{};
    for (final s in graph.chain(reader.scope).reversed) {
      for (final n in graph.scopes[s].nodes) {
        if (n.name == reader.name) continue;
        final contributes = read.isSet
            ? n.pub.kind == PubKind.contribution && n.pub.name == read.name
            : n.pub.kind == PubKind.entry && n.pub.name == read.name;
        if (!contributes) continue;
        // A contribution leaves the collection when its node is disposed by
        // a withdrawal. A node that the rollback of a failed `initialize`
        // removed is still declared, and the scope declares it again.
        if (withdrawn.contains(n.name) &&
            _stateOfNode(s, n)?.phase == NodePhase.disposed) {
          continue;
        }
        if (read.isMap && !ids.add(n.pub.id!)) continue;
        out.add((s, n));
      }
    }
    return out;
  }

  // -- ReadsCurrent -----------------------------------------------------------

  /// The acquisition [number] as a last step whose release has not started,
  /// else a violation line.
  String? _notLive(Object? number) {
    if (number is! int) return 'is not a number';
    final value = acqs[number];
    if (value == null) {
      return 'is a$number, and no acquisition has that number';
    }
    if (value.step != graph.node(value.node).steps - 1) {
      return 'is a$number (${value.node}.s${value.step}), not a last step';
    }
    if (!value.created || value.disposeStarts != 0) {
      return 'is a$number (${value.node}.s${value.step}), which is not live '
          '(created: ${value.created}, dispose starts: ${value.disposeStarts})';
    }
    return null;
  }

  /// At the start of the `create` of a first step, each value that it received
  /// is the value of the last step of a node that the reader may read, whose
  /// release has not started.
  void _checkReadsCurrent(Acq a) {
    final reader = graph.node(a.node);
    final chain = graph.chain(reader.scope);
    if (a.received.length != reader.reads.length) {
      _violate(
        'ReadsCurrent: the create of a${a.id} (${a.node}.s0) received '
        '${a.received.length} values for ${reader.reads.length} reads',
      );
      return;
    }
    for (var i = 0; i < reader.reads.length; i++) {
      final read = reader.reads[i];
      final got = a.received[i];
      String what() =>
          'the create of a${a.id} (${a.node}.s0) received $got for '
          '${read.describe()}';
      if (read.isSet) {
        _checkSetRead(reader, read, got, what);
      } else if (read.isMap) {
        _checkMapRead(reader, read, got, what);
      } else {
        final found = _nearestActive(reader, read.keyId);
        if (got == null) {
          if (read.kind != ReadKind.optional) {
            _violate('ReadsCurrent: ${what()}, null for a required read');
          } else if (found != null) {
            _violate(
              'ReadsCurrent: ${what()}, and ${graph.scopeName(found.$1)} '
              'holds an active node of the key (${found.$2.name})',
            );
          } else {
            FuzzStats.optionalNulls++;
          }
          continue;
        }
        final why = _notLive(got);
        if (why != null) {
          _violate('ReadsCurrent: ${what()}, which $why');
          continue;
        }
        if (read.kind == ReadKind.optional) FuzzStats.optionalValues++;
        final value = acqs[got as int]!;
        if (found == null) {
          _violate(
            'ReadsCurrent: ${what()} (${value.node}), and no scope from the '
            'reader to the root holds an active node of the key',
          );
        } else if (found.$2.name != value.node) {
          _violate(
            'ReadsCurrent: ${what()} (${value.node}), and the nearest active '
            'node of the key is ${found.$2.name} in '
            '${graph.scopeName(found.$1)}',
          );
        } else if (chain
            .skipWhile((s) => s != found.$1)
            .skip(1)
            .any(
              (s) =>
                  graph.scopes[s].nodes.any((n) => n.pub.keyId == read.keyId),
            )) {
          FuzzStats.shadowedReads++;
        }
      }
    }
  }

  void _checkSetRead(
    NodeDesc reader,
    ReadDesc read,
    Object? got,
    String Function() what,
  ) {
    if (got is! Set<int>) {
      _violate('ReadsCurrent: ${what()}, not a Set<int>');
      return;
    }
    final expected = [
      for (final (s, n) in _visible(reader, read))
        if (read.strict || _isActive(s, n)) n.name,
    ];
    final actual = [for (final v in got) acqs[v]?.node ?? 'a$v'];
    if (expected.join(',') != actual.join(',')) {
      _violate(
        'ReadsCurrent: ${what()}, from the nodes $actual; the visible '
        'contributions give $expected',
      );
    }
    for (final v in got) {
      final why = _notLive(v);
      if (why != null) _violate('ReadsCurrent: ${what()}, and $v $why');
    }
    if (got.isNotEmpty) FuzzStats.setReadsWithValue++;
    if (got.length > 1) FuzzStats.setReadsMany++;
  }

  void _checkMapRead(
    NodeDesc reader,
    ReadDesc read,
    Object? got,
    String Function() what,
  ) {
    if (got is! Map<String, int>) {
      _violate('ReadsCurrent: ${what()}, not a Map<String, int>');
      return;
    }
    final expected = <String>[];
    for (final (_, n) in _visible(reader, read)) {
      final id = n.pub.id!;
      final nearest = _nearestActive(reader, n.pub.keyId!);
      if (nearest != null) {
        expected.add('$id=${nearest.$2.name}');
        if (graph
            .chain(reader.scope)
            .skipWhile((j) => j != nearest.$1)
            .skip(1)
            .any(
              (j) =>
                  graph.scopes[j].nodes.any((m) => m.pub.keyId == n.pub.keyId),
            )) {
          FuzzStats.shadowedMapIds++;
        }
      } else if (read.strict) {
        expected.add('$id=none');
      }
    }
    final actual = [
      for (final e in got.entries) '${e.key}=${acqs[e.value]?.node ?? e.value}',
    ];
    if (expected.join(',') != actual.join(',')) {
      _violate(
        'ReadsCurrent: ${what()}, as entries $actual; the visible entries '
        'give $expected',
      );
    }
    for (final v in got.values) {
      final why = _notLive(v);
      if (why != null) _violate('ReadsCurrent: ${what()}, and $v $why');
    }
    if (got.isNotEmpty) FuzzStats.mapReadsWithValue++;
    if (got.length > 1) FuzzStats.mapReadsMany++;
  }

  // -- helpers --------------------------------------------------------------

  void _violate(String message) => violations.add(message);

  T _guard<T>(String what, T Function() call) {
    try {
      return call();
    } on DisposedScopeError {
      violations.add(
        'HarnessDefect: $what threw DisposedScopeError synchronously '
        '(a precondition admitted a call on a disposed scope)',
      );
      _throwIfViolated();
      rethrow;
    }
  }

  Held _hold(
    String label,
    Future<Object?> future, {
    required String source,
    int? scope,
    bool retry = false,
  }) {
    final h = Held(label, future, source, scope, retry: retry);
    held.add(h);
    unawaited(
      future.then<void>(
        (_) {
          h
            ..done = true
            ..ok = true;
        },
        onError: (Object error, StackTrace _) {
          h
            ..done = true
            ..error = error;
        },
      ),
    );
    return h;
  }

  /// Whether a disposal of scope [s] or of an ancestor was requested.
  bool _effectivelyRequested(int s) => graph
      .chain(s)
      .any(
        (j) =>
            firstDisposal.containsKey('scope:$j') ||
            _inFlight.contains('scope:$j'),
      );

  String _report(String headline) {
    final buffer = StringBuffer()
      ..writeln(headline)
      ..writeln('seed=${graph.seed} graph=${graph.index}');
    for (final v in violations) {
      buffer.writeln('  - $v');
    }
    buffer
      ..writeln(graph.describe())
      ..writeln(shapeReport(graph))
      ..writeln('Acquisitions (value = number; received values):');
    for (final a in acqs.values) {
      buffer.writeln(
        '  a${a.id} ${a.node}.s${a.step} received ${a.received} '
        'reads ${(a.reads.toList()..sort())}',
      );
    }
    buffer.writeln('Trace:');
    for (final e in trace) {
      buffer.writeln('  $e');
    }
    final open = [
      for (final g in gates) '${g.kind} ${g.node}.s${g.step} a${g.acq}',
    ];
    buffer.writeln('Open gates: $open');
    return buffer.toString();
  }

  void _throwIfViolated() {
    if (violations.isEmpty) return;
    throw HistoryViolation(_report('Lifecycle history violation'));
  }

  // -- commands -------------------------------------------------------------

  Future<void> _end() async {
    FuzzStats.commands++;
    await pumpEventQueue();
    for (final (h, before, label) in _pendingLate) {
      if (!h.done || !h.ok) {
        _violate(
          'LateCallNoop: late call "$label" did not complete with '
          'success at once',
        );
      }
      if (disposeStartCount != before) {
        _violate('LateCallNoop: late call "$label" added a dispose start');
      }
    }
    _pendingLate.clear();
    for (final c in _newSiteCalls) {
      if (c.late && !c.held.done) {
        _violate(
          'NestedCall: ${c.target} at ${c.label} came after the disposal of '
          '${c.owner} finished, and did not complete at once',
        );
        c.explained = true;
      }
    }
    _newSiteCalls.clear();
    _refresh();
    _throwIfViolated();
  }

  Future<void> initializeScope(int s) async {
    final info = scopes[s]!;
    info.initializeCalled = true;
    final f = _guard('initialize(${info.name})', () => info.scope.initialize());
    info.initFuture = _hold(
      'initialize(${info.name})',
      f,
      source: 'initialize',
      scope: s,
    );
    await _end();
  }

  /// Calls `initialize()` again when the last call of [s] completed with
  /// an error and the scope is not initialized. Otherwise does nothing.
  Future<void> retryInitialize(int s) async {
    final info = scopes[s]!;
    final last = info.initFuture;
    if (last != null && last.done && last.error != null && !info.initialized) {
      final f = _guard(
        'retry initialize(${info.name})',
        () => info.scope.initialize(),
      );
      info.initFuture = _hold(
        'retry initialize(${info.name})',
        f,
        source: 'initialize',
        scope: s,
        retry: true,
      );
      FuzzStats.retryCalls++;
    }
    await _end();
  }

  /// Creates scope [s] when it does not exist, and calls `initialize()` on it
  /// before its parent calls `initialize()`. Its nodes wait for the keys of the
  /// ancestors, and activate automatically when an ancestor initializes.
  Future<void> initializeBeforeParent(int s) async {
    if (scopes[s] == null) await createChild(s);
    await initializeScope(s);
  }

  /// Calls `child(module:)` on the parent of scope [s].
  Future<void> createChild(int s) async {
    final parent = scopes[graph.scopes[s].parent]!;
    final c = _guard(
      'child(${graph.scopeName(s)})',
      () => parent.scope.child(module: modules[s]),
    );
    final info = ScopeInfo(s, graph.scopeName(s), c);
    scopes[s] = info;
    _listen(info);
    await _end();
  }

  Future<void> startDispose(int s) => _disposeScope(s, 'StartDispose');

  Future<void> disposeAgain(int s) => _disposeScope(s, 'DisposeAgain');

  /// Calls `dispose()` on scope [s].
  Future<void> _disposeScope(int s, String command) async {
    final info = scopes[s]!;
    final chain = [for (final j in graph.chain(s)) 'scope:$j'];
    final owner = _ownerOf(chain);
    final startsBefore = disposeStartCount;
    if (owner == null) _takeTeardown(s);
    // The listeners run inside this call, after the runtime recorded the
    // disposal. A site then calls into a disposal that a command requested.
    if (owner == null) _inFlight.add(chain.first);
    final Future<void> f;
    try {
      f = _guard('$command dispose(${info.name})', () => info.scope.dispose());
    } finally {
      _inFlight.remove(chain.first);
    }
    final h = _hold('$command dispose(${info.name})', f, source: 'dispose');
    await _recordCall(h, chain, owner, startsBefore);
    await _end();
  }

  /// Calls `dispose()` on the handle of member [i] of scope [s].
  Future<void> disposeMember(int s, int i) async {
    final handles = scopes[s % graph.scopes.length]?.handles;
    if (handles == null || handles.isEmpty) {
      await _end();
      return;
    }
    final (name, node) = handles[i % handles.length];
    final chain = ['node:$name'];
    final owner = _ownerOf(chain);
    final startsBefore = disposeStartCount;
    final f = _guard('member dispose($name)', () => node.dispose());
    final h = _hold('DisposeMember dispose($name)', f, source: 'dispose');
    withdrawn.add(name);
    FuzzStats.memberCalls++;
    await _recordCall(h, chain, owner, startsBefore);
    await _end();
  }

  String? _ownerOf(List<String> chain) {
    for (final id in chain) {
      if (firstDisposal.containsKey(id) || _inFlight.contains(id)) return id;
    }
    return null;
  }

  Future<void> _recordCall(
    Held h,
    List<String> chain,
    String? owner,
    int startsBefore,
  ) async {
    if (owner == null) {
      firstDisposal[chain.first] = h;
      calls.add(DisposeCall(h, 'first', chain.first));
      return;
    }
    final isLate = firstDisposal[owner]!.done;
    calls.add(DisposeCall(h, isLate ? 'late' : 'join', owner));
    if (isLate) {
      FuzzStats.lateCalls++;
      // A late call completes before any timer runs.
      await Future<void>.delayed(Duration.zero);
      _pendingLate.add((h, startsBefore, h.label));
    } else {
      FuzzStats.joins++;
    }
  }

  void _takeTeardown(int s) {
    // Every lifecycle mutation of a runtime shares one queue. A disposal
    // that waits behind an earlier unfinished mutation (an initialize or a
    // member withdrawal) starts its releases at a time that the trace does
    // not show. The ReleaseOverlap check skips such a teardown.
    if (!held.every((h) => h.done)) {
      FuzzStats.skipped++;
      return;
    }
    final nodes = <String>{};
    void add(ScopeInfo? info) {
      for (final (n, node)
          in info?.handles ?? const <(String, ComponentNode<Object?>)>[]) {
        if (node.isActive) nodes.add(n);
      }
    }

    add(scopes[s]);
    // A descendant whose disposal an earlier call requested is not part of
    // this teardown.
    for (final d in graph.descendants(s)) {
      var earlier = false;
      for (var j = d; j != s; j = graph.scopes[j].parent) {
        if (firstDisposal.containsKey('scope:$j')) earlier = true;
      }
      if (!earlier) add(scopes[d]);
    }
    FuzzStats.overlapNodes += nodes.length;
    teardowns.add(Teardown(graph.scopeName(s), nodes, trace.length));
    FuzzStats.teardowns++;
  }

  Future<void> resolve(String kind, String outcome, int i) async {
    final open = [
      for (final g in gates)
        if (g.kind == kind) g,
    ];
    if (open.isNotEmpty) {
      _settle(open[i % open.length], fail: outcome == 'fail');
    }
    await _end();
  }

  // -- online checks --------------------------------------------------------

  void _refresh() {
    for (final info in live) {
      final f = info.initFuture;
      if (f != null && f.done && f.ok && !info.initialized) {
        info.initialized = true;
        if (info.index == 0) FuzzStats.initialized++;
        if (graph.isSecondChild(info.index)) {
          FuzzStats.secondChildInitialized++;
        }
        if (graph.isGrandchild(info.index)) FuzzStats.grandchildInitialized++;
      }
      if (info.initialized &&
          !_effectivelyRequested(info.index) &&
          info.handles == null) {
        final nodes = graph.scopes[info.index].nodes;
        info.handles = [
          for (var i = 0; i < nodes.length; i++)
            (
              nodes[i].name,
              _guard('node(${nodes[i].name})', () {
                final key = nodes[i].pub.key;
                return key != null
                    ? info.scope.node<int>(key: key)
                    : info.scope.nodes[i];
              }),
            ),
        ];
      }
    }
    _checkOutcomes();
    _checkSiteCalls();
    _checkOverlap();
    _checkAtomicPublication();
    _checkRuntimeState();
    _checkUnavailableCause();
  }

  // -- RuntimeState (V-T-RT-LC-032) ------------------------------------------

  /// The keys that [node] of [info] expects in `missing`: the plain keys that
  /// a required read cannot resolve, and each strict collection key with a
  /// visible contribution that does not resolve.
  Set<DiKeyBase> _expectedMissing(ScopeInfo info, NodeDesc node) {
    final expected = <DiKeyBase>{};
    for (final read in node.reads) {
      switch (read.kind) {
        case ReadKind.plain:
          if (info.scope.maybeGet<int>(key: read.key) == null) {
            expected.add(read.key);
          }
        case ReadKind.requireSet:
          if (_visible(node, read).any((c) => !_isActive(c.$1, c.$2))) {
            expected.add(read.collectionKey);
          }
        case ReadKind.requireMap:
          if (_visible(
            node,
            read,
          ).any((c) => _nearestActive(node, c.$2.pub.keyId!) == null)) {
            expected.add(read.collectionKey);
          }
        case ReadKind.optional || ReadKind.maybeSet || ReadKind.maybeMap:
      }
    }
    return expected;
  }

  void _checkRuntimeState() {
    final revision = root.scope.revision;
    for (final info in live) {
      final state = info.scope.state;
      // The listener is called at each transition, so the value that it kept
      // last is the current value.
      if (info.heard.isNotEmpty && !identical(state, info.heard.last.$1)) {
        _violate(
          'RuntimeState: the state of ${info.name} is not the value of the '
          'last listener call, at revision $revision',
        );
      }
      final before = _stateBefore[info.index];
      if (before != null &&
          revision == _revisionBefore &&
          !identical(state, before)) {
        _violate(
          'RuntimeState: ${info.name} returned a new state object without a '
          'transition',
        );
      }
      _stateBefore[info.index] = state;
      if (info.scope.isInitialized) {
        final members = info.scope.nodes;
        for (var i = 0; i < members.length; i++) {
          if (members[i].state != state.nodeStates[i]) {
            _violate(
              'RuntimeState: member $i of ${info.name} reads '
              '${members[i].state}, and the state holds ${state.nodeStates[i]}',
            );
          }
        }
      }
      final rejects =
          state.phase == ScopePhase.disposing ||
          state.phase == ScopePhase.disposed;
      for (final MapEntry(key: keyId, value: key)
          in graph.lookupKeys(info.index).entries) {
        try {
          final value = info.scope.maybeGet<int>(key: key);
          final node = info.scope.findNode<int>(key: key);
          if (rejects) {
            _violate(
              'RuntimeState: a lookup of ${info.name} answers in the phase '
              '${state.phase.name}',
            );
          } else if ((value != null) !=
              (node?.state.phase == NodePhase.active)) {
            _violate(
              'RuntimeState: $keyId reads $value in ${info.name}, and its '
              'node has the phase ${node?.state.phase.name}',
            );
          } else if (value != null) {
            final owner = acqs[value]?.node;
            if (node!.value != value || owner != node.state.label) {
              _violate(
                'RuntimeState: $keyId reads $value (of $owner) in '
                '${info.name}, and its node ${node.state.label} holds '
                '${node.value}',
              );
            }
          }
        } on DisposedScopeError {
          if (!rejects || !_effectivelyRequested(info.index)) {
            _violate(
              'RuntimeState: a lookup of ${info.name} throws '
              'DisposedScopeError in the phase ${state.phase.name}',
            );
          }
        }
      }
      // The missing keys of each node are the required keys that `maybeGet`
      // does not answer, and the strict collection keys with a visible
      // contribution that does not resolve. The lookup reads the bindings,
      // not the state.
      final own = graph.scopes[info.index].nodes;
      if (rejects || state.nodeStates.length != own.length) continue;
      for (var i = 0; i < own.length; i++) {
        final node = state.nodeStates[i];
        final settled =
            node.phase == NodePhase.active || node.phase == NodePhase.disposed;
        final expected = settled
            ? <DiKeyBase>{}
            : _expectedMissing(info, own[i]);
        final waits = node.phase == NodePhase.waiting;
        final rests =
            node.phase == NodePhase.inactive ||
            node.phase == NodePhase.activationFailed;
        if (node.missing.toSet().length != expected.length ||
            !node.missing.every(expected.contains) ||
            (waits && expected.isEmpty) ||
            (rests && expected.isNotEmpty)) {
          _violate(
            'RuntimeState: ${own[i].name} of ${info.name} has the state '
            '$node, and the lookups do not answer $expected',
          );
        }
      }
    }
    _revisionBefore = revision;
  }

  // -- RequiringPartition (V-T-RT-LC-036) ------------------------------------

  /// The check of `Module.requiring` and `Module.withoutRequiring` for the
  /// keys that the descriptor fixes for each module. The expected members come
  /// from a fixed point over `requires` and `key` of each member: a member is
  /// selected when its `requires` holds an absent key, and the key that a
  /// selected member publishes is absent unless `ancestorKeys` holds it.
  void _requiringCheck() {
    for (var s = 0; s < graph.scopes.length; s++) {
      final desc = graph.scopes[s];
      final lookup = graph.lookupKeys(s);
      final keys = <DiKeyBase>[
        for (final id in desc.requiringKeys) lookup[id]!,
      ];
      final ancestorKeys = <DiKeyBase>[
        for (final id in desc.ancestorKeys) lookup[id]!,
      ];
      final source = modules[s];
      final members = source.components;
      final name = graph.scopeName(s);
      final absent = <DiKeyBase>{...keys};
      final selected = List<bool>.filled(members.length, false);
      var changed = true;
      while (changed) {
        changed = false;
        for (var i = 0; i < members.length; i++) {
          if (selected[i] || !members[i].requires.any(absent.contains)) {
            continue;
          }
          selected[i] = true;
          changed = true;
          final published = members[i].key;
          if (published != null && !ancestorKeys.contains(published)) {
            absent.add(published);
          }
        }
      }
      final requiring = source.requiring(
        keys: keys,
        ancestorKeys: ancestorKeys,
      );
      final without = source.withoutRequiring(
        keys: keys,
        ancestorKeys: ancestorKeys,
      );
      void compare(String call, Module actual, bool value) {
        final expected = [
          for (var i = 0; i < members.length; i++)
            if (selected[i] == value) i,
        ];
        final same =
            actual.components.length == expected.length &&
            [
              for (var j = 0; j < expected.length; j++)
                identical(actual.components[j], members[expected[j]]),
            ].every((b) => b) &&
            actual.origins.length == expected.length &&
            [
              for (var j = 0; j < expected.length; j++)
                actual.origins[j] == source.origins[expected[j]],
            ].every((b) => b);
        if (!same) {
          _violate(
            'RequiringPartition: $call of the module of $name for keys '
            '$keys and ancestor keys $ancestorKeys holds '
            '${[for (final c in actual.components) c.label]}, and the fixed '
            'point gives ${[for (final i in expected) members[i].label]}',
          );
        }
        if (actual.debugLabel != source.debugLabel) {
          _violate(
            'RequiringPartition: $call of the module of $name has the label '
            '${actual.debugLabel}, not ${source.debugLabel}',
          );
        }
      }

      compare('requiring', requiring, true);
      compare('withoutRequiring', without, false);
      for (final member in without.components) {
        final hit = member.requires.where(keys.contains).toList();
        if (hit.isNotEmpty) {
          _violate(
            'RequiringPartition: ${member.label} of withoutRequiring of the '
            'module of $name requires $hit of the keys $keys',
          );
        }
      }
      for (final key in without.requires) {
        if (!source.requires.contains(key) && !ancestorKeys.contains(key)) {
          _violate(
            'RequiringPartition: withoutRequiring of the module of $name '
            'requires $key, which is neither in requires of the source nor '
            'in the ancestor keys $ancestorKeys',
          );
        }
      }
      FuzzStats.partitionsChecked++;
      if (selected.any((b) => b)) FuzzStats.partitionsSelecting++;
      if ([
        for (var i = 0; i < members.length; i++)
          if (selected[i] && !members[i].requires.any(keys.contains)) i,
      ].isNotEmpty) {
        FuzzStats.partitionsTransitive++;
      }
      if ([
        for (var i = 0; i < members.length; i++)
          if (!selected[i] &&
              members[i].requires.any(
                (k) =>
                    ancestorKeys.contains(k) &&
                    [
                      for (var j = 0; j < members.length; j++)
                        if (selected[j] && members[j].key == k) j,
                    ].isNotEmpty,
              ))
            i,
      ].isNotEmpty) {
        FuzzStats.partitionsAncestorKept++;
      }
    }
  }

  // -- UnavailableCause (V-T-RT-LC-035) ---------------------------------------

  /// Whether the component [n] of scope [s] has a node that a lookup finds: its
  /// scope has nodes, and the node is not disposed.
  bool _hasNode(int s, NodeDesc n) {
    final state = _stateOfNode(s, n);
    return state != null && state.phase != NodePhase.disposed;
  }

  /// The nearest component that publishes [keyId] and has a node, from scope
  /// [from] to the root, other than the component named [except].
  (int, NodeDesc)? _publisherBehind(int from, String keyId, {String? except}) {
    for (final s in graph.chain(from)) {
      for (final n in graph.scopes[s].nodes) {
        if (n.pub.keyId != keyId || n.name == except || !_hasNode(s, n)) {
          continue;
        }
        return (s, n);
      }
    }
    return null;
  }

  /// The search of R-UC-RT-LC-030 from the node of [keyId] that a lookup in
  /// scope [s] finds. `failed` holds the names of the failed nodes in the order
  /// of a depth-first search, and `path` each visited node with its phase.
  ({
    String? first,
    List<String> failed,
    List<String> path,
    bool waits,
    bool collection,
  })
  _searchCause(int s, String keyId) {
    final start = _publisherBehind(s, keyId);
    final failed = <String>[];
    final path = <String>[];
    final seen = <String>{};
    var collection = false;
    void visit(int scope, NodeDesc node) {
      if (!seen.add(node.name)) return;
      final state = _stateOfNode(scope, node)!;
      path.add('${node.name}:${state.phase.name}');
      if (state.phase == NodePhase.activationFailed) {
        failed.add(node.name);
        return;
      }
      if (state.phase != NodePhase.waiting) return;
      for (final key in state.missing) {
        if (key is DiCollectionKey<Object?>) {
          collection = true;
          final reads = [
            for (final r in node.reads)
              if (r.isCollection && r.collectionKey == key) r,
          ];
          if (reads.length != 1) {
            _violate(
              'HarnessDefect: ${node.name} misses $key, and it has '
              '${reads.length} reads of that collection',
            );
            continue;
          }
          final read = reads.single;
          for (final (cs, cn) in _visible(node, read)) {
            if (read.isSet) {
              if (!_isActive(cs, cn) && _hasNode(cs, cn)) visit(cs, cn);
            } else {
              final id = cn.pub.keyId!;
              if (_nearestActive(node, id) != null) continue;
              final behind = _publisherBehind(
                node.scope,
                id,
                except: node.name,
              );
              if (behind != null) visit(behind.$1, behind.$2);
            }
          }
        } else {
          final ids = [
            for (final e in graph.lookupKeys(node.scope).entries)
              if (e.value == key) e.key,
          ];
          if (ids.length != 1) {
            _violate(
              'HarnessDefect: ${node.name} misses $key, which the graph '
              'does not publish once in its scope chain',
            );
            continue;
          }
          final behind = _publisherBehind(
            node.scope,
            ids.single,
            except: node.name,
          );
          if (behind != null) visit(behind.$1, behind.$2);
        }
      }
    }

    if (start != null) visit(start.$1, start.$2);
    return (
      first: start?.$2.name,
      failed: failed,
      path: path,
      waits:
          start != null &&
          _stateOfNode(start.$1, start.$2)!.phase == NodePhase.waiting,
      collection: collection,
    );
  }

  /// After each command, for each declared plain key of each initialized scope
  /// without a disposal request whose `maybeGet` gives null: `get` throws an
  /// `UnavailableKeyException` with the key and leaves `revision` as it was,
  /// and `failedNodeStates` is the list that a harness search over the reads
  /// and the node states gives.
  void _checkUnavailableCause() {
    for (final info in live) {
      if (!info.initialized || _effectivelyRequested(info.index)) continue;
      final scope = info.scope;
      for (final state in scope.state.nodeStates) {
        if (state.phase == NodePhase.activationFailed) {
          FuzzStats.failedNodeObservations++;
        }
      }
      for (final MapEntry(key: keyId, value: key)
          in graph.lookupKeys(info.index).entries) {
        if (scope.maybeGet<int>(key: key) != null) continue;
        final what = 'get($keyId) of ${info.name}';
        final revision = scope.revision;
        UnavailableKeyException? thrown;
        try {
          final value = scope.get<int>(key: key);
          _violate(
            'UnavailableCause: $what returned $value, and maybeGet gives null',
          );
        } on UnavailableKeyException catch (error) {
          thrown = error;
        } on Object catch (error) {
          _violate('UnavailableCause: $what threw ${_show(error)}');
        }
        if (scope.revision != revision) {
          _violate(
            'UnavailableCause: $what changed revision from $revision to '
            '${scope.revision}',
          );
        }
        if (thrown == null) continue;
        FuzzStats.getsChecked++;
        if (thrown.key != key) {
          _violate(
            'UnavailableCause: $what threw for the key ${thrown.key}',
          );
        }
        final cause = _searchCause(info.index, keyId);
        final found = scope.findNode<int>(key: key);
        if (found?.state.label != cause.first) {
          _violate(
            'UnavailableCause: $what finds the node ${found?.state.label}, '
            'and the harness finds ${cause.first}',
          );
        }
        final actual = thrown.failedNodeStates;
        final labels = [for (final e in actual) e.label];
        if (labels.join(',') != cause.failed.join(',')) {
          _violate(
            'UnavailableCause: $what gives failedNodeStates $labels, and the '
            'search over the reads gives ${cause.failed} (visited '
            '${cause.path})',
          );
        } else {
          for (var i = 0; i < actual.length; i++) {
            final node = graph.node(cause.failed[i]);
            final expected = _stateOfNode(node.scope, node)!;
            if (actual[i].phase != NodePhase.activationFailed ||
                actual[i] != expected ||
                actual[i].activationException == null ||
                !identical(
                  actual[i].activationException,
                  expected.activationException,
                )) {
              _violate(
                'UnavailableCause: $what gives ${actual[i]} for ${node.name}, '
                'and the state of the node is $expected',
              );
            }
          }
        }
        if (labels.toSet().length != labels.length) {
          _violate(
            'UnavailableCause: $what lists a failed node more than once: '
            '$labels',
          );
        }
        if (cause.waits) FuzzStats.getsWaiting++;
        if (cause.collection) FuzzStats.getsCollection++;
        if (actual.isNotEmpty) FuzzStats.getsWithFailedNodes++;
        if (actual.length > 1) FuzzStats.getsWithManyFailedNodes++;
      }
    }
  }

  // -- ExplainedOutcome -----------------------------------------------------

  static String _show(Object? e) => '${e.runtimeType}: $e';

  static bool _tagged(Object? e, {required bool dispose}) =>
      e is TaggedError && e.dispose == dispose;

  static String? _disposeFailuresProblem(List<DisposeFailure> disposeFailures) {
    for (final i in disposeFailures) {
      if (!_tagged(i.error, dispose: true)) {
        return 'the dispose failure of ${i.owner} holds ${_show(i.error)}, '
            'not a tagged dispose error';
      }
    }
    return null;
  }

  /// Whether a disposal of scope [s] or an ancestor, or a withdrawal of a
  /// member of [s] or of a publisher that a member reads, was requested.
  bool _cancelAllowed(int s) {
    if (_effectivelyRequested(s)) return true;
    final names = <String>{};
    for (final n in graph.scopes[s].nodes) {
      names.add(n.name);
      for (final read in n.reads) {
        for (final j in graph.chain(s)) {
          for (final p in graph.scopes[j].nodes) {
            if (read.readsPub(p.pub)) names.add(p.name);
          }
        }
      }
    }
    return withdrawn.any(names.contains);
  }

  /// The reason that [error] is not an allowed result, or null.
  String? _problem(Object error, {required String source, int? scope}) {
    if (source == 'dispose') {
      if (error is DisposeException) {
        return _disposeFailuresProblem(error.disposeFailures);
      }
      return '${_show(error)} is not a DisposeException';
    }
    // An initialize result, or an errors event (scope is null).
    switch (error) {
      case ActivationException(:final cause, :final rollbackFailures):
        if (!_tagged(cause, dispose: false)) {
          return 'the cause is ${_show(cause)}, not a tagged create error';
        }
        return _disposeFailuresProblem(rollbackFailures);
      case ActivationCanceledException(:final cause, :final rollbackFailures)
          when scope != null:
        if (!_cancelAllowed(scope)) {
          return 'a cancellation without a request for the disposal of '
              '${graph.scopeName(scope)} or a withdrawal of a publisher it '
              'reads';
        }
        if (cause != null && !_tagged(cause, dispose: false)) {
          return 'the cancellation cause is ${_show(cause)}, '
              'not a tagged create error';
        }
        return _disposeFailuresProblem(rollbackFailures);
      case DisposeException(:final disposeFailures) when scope == null:
        return _disposeFailuresProblem(disposeFailures);
      case DiListenerException(:final cause) when scope == null:
        if (!identical(cause, listenerError)) {
          return 'the listener error is ${_show(cause)}, not the tagged '
              'error of the listener that throws';
        }
        FuzzStats.listenerReports++;
        return null;
      default:
        return '${_show(error)} is not allowed here';
    }
  }

  void _checkOutcomes() {
    for (final h in held) {
      final error = h.error;
      if (!h.done || h.explained) continue;
      h.explained = true;
      final key = '${h.source}/${error?.runtimeType ?? 'ok'}';
      FuzzStats.outcomes[key] = (FuzzStats.outcomes[key] ?? 0) + 1;
      if (error == null) {
        if (h.retry) FuzzStats.retrySuccesses++;
        continue;
      }
      final why = _problem(error, source: h.source, scope: h.scope);
      if (why != null) {
        _violate('ExplainedOutcome: "${h.label}" failed: $why');
      }
    }
    for (; _eventsChecked < errorEvents.length; _eventsChecked++) {
      final event = errorEvents[_eventsChecked];
      final key = 'event/${event.runtimeType}';
      FuzzStats.outcomes[key] = (FuzzStats.outcomes[key] ?? 0) + 1;
      final why = _problem(event, source: 'event');
      if (why != null) {
        _violate('ExplainedOutcome: errors event #$_eventsChecked: $why');
      }
    }
  }

  /// Whether [b] is released: it holds no created acquisition without a
  /// finished `dispose`, and it has no open `create`.
  static bool _acqReleased(Acq b) =>
      !b.createOpen && (!b.created || b.disposeFinished);

  bool _unstarted(String node) {
    final created = [
      for (final a in acqsByNode[node] ?? const <Acq>[])
        if (a.created) a,
    ];
    return created.isNotEmpty && created.every((a) => a.disposeStarts == 0);
  }

  /// The acquisitions of other nodes that read an acquisition of [node].
  Iterable<Acq> _readersOfNode(String node) {
    final ids = {
      for (final a in acqsByNode[node] ?? const <Acq>[])
        if (a.created) a.id,
    };
    return acqs.values.where(
      (b) => b.node != node && b.reads.any(ids.contains),
    );
  }

  void _checkOverlap() {
    for (final t in teardowns) {
      final started = t.nodes.any(
        (n) => (acqsByNode[n] ?? const <Acq>[]).any(
          (a) => a.firstDisposeSeq >= t.fromSeq,
        ),
      );
      if (!started) continue;
      if (!t.countedGate &&
          gates.any((g) => g.kind == 'dispose' && t.nodes.contains(g.node))) {
        t.countedGate = true;
        FuzzStats.overlapGateTeardowns++;
      }
      for (final n in t.nodes) {
        if (_unstarted(n) && _readersOfNode(n).every(_acqReleased)) {
          _violate(
            'ReleaseOverlap: in the teardown of ${t.owner} (from '
            '#${t.fromSeq}) node $n has every reader released and its '
            'release has not started',
          );
        }
      }
    }
  }

  /// After a `create` of a member failed, the member is not `active`, and
  /// `maybeGet` of its scope returns no value of that member, until its last
  /// step completes again. An ancestor MAY answer the key.
  void _checkAtomicPublication() {
    for (final name in failedCreate) {
      final node = graph.node(name);
      final info = scopes[node.scope];
      if (info == null || _effectivelyRequested(node.scope)) continue;
      final state = _stateOfNode(node.scope, node);
      if (state != null && state.phase == NodePhase.active) {
        _violate(
          'AtomicPublication: $name reports a failed create but its node is '
          'active',
        );
      }
      final key = node.pub.key;
      if (key == null) continue;
      final value = info.scope.maybeGet<int>(key: key);
      if (value != null && acqs[value]?.node == name) {
        _violate(
          'AtomicPublication: $name reports a failed create but its key '
          'reads its own value $value',
        );
      }
    }
  }

  // -- terminal phase -------------------------------------------------------

  Future<void> terminal() async {
    if (!firstDisposal.containsKey('scope:0')) {
      await _disposeScope(0, 'Terminal');
    }
    var guard = 0;
    while (gates.isNotEmpty) {
      if (++guard > 5000) {
        _violate('Terminal: gates keep opening (more than 5000 completions)');
        break;
      }
      _settle(gates.first, fail: false);
      await _end();
    }
    await _end();
    _finalChecks();
    _throwIfViolated();
  }

  void _finalChecks() {
    // RuntimeState: no value that a listener kept has changed.
    for (final info in live) {
      for (final (value, copy) in info.heard) {
        if (_printState(value) != copy) {
          _violate(
            'RuntimeState: a state kept for ${info.name} changed after its '
            'listener call',
          );
          break;
        }
      }
    }
    // HeldFuturesComplete: a flag check, with no timeout.
    for (final h in held) {
      if (!h.done) {
        _violate('HeldFuturesComplete: "${h.label}" never completed');
      }
    }
    // LeaseAccounted.
    for (final a in acqs.values) {
      if (a.created && a.disposeStarts != 1) {
        _violate(
          'LeaseAccounted: a${a.id} (${a.node}.s${a.step}) completed create '
          'and has ${a.disposeStarts} dispose starts',
        );
      }
    }
    // CallersAgree.
    for (final c in calls) {
      if (c.kind != 'join') continue;
      final first = firstDisposal[c.owner]!;
      if (first.done && first.error != null) FuzzStats.joinsOnFailure++;
      if (c.held.done &&
          first.done &&
          (c.held.ok != first.ok || !identical(c.held.error, first.error))) {
        _violate(
          'CallersAgree: "${c.held.label}" joined ${c.owner} and got '
          '${c.held.error ?? 'success'}, the first call got '
          '${first.error ?? 'success'}',
        );
      }
    }
    // The calls from the call sites: HeldFuturesComplete, and CallersAgree for
    // the calls that join a disposal in progress.
    for (final c in siteCalls) {
      if (!c.held.done) {
        _violate('HeldFuturesComplete: "${c.label}" never completed');
        continue;
      }
      final error = c.held.error;
      if (c.fromCreate || c.late || error is ReentrantMutationError) continue;
      final first = firstDisposal[c.owner!]!;
      if (first.done &&
          (c.held.ok != first.ok || !identical(error, first.error))) {
        _violate(
          'CallersAgree: ${c.target} at ${c.label} joined ${c.owner} and got '
          '${error ?? 'success'}, the first call got '
          '${first.error ?? 'success'}',
        );
      } else {
        FuzzStats.accepted(c);
      }
    }
    // ListenerFailure: one report, of the tagged error of the listener that
    // threw, and no report without a throw.
    final reports = [
      for (final e in errorEvents)
        if (e is DiListenerException) e,
    ];
    final thrown = listenerError;
    if (thrown == null) {
      if (reports.isNotEmpty) {
        _violate(
          'ListenerFailure: ${reports.length} DiListenerException events, and '
          'no listener threw',
        );
      }
    } else if (reports.length != 1 ||
        !identical(reports.single.cause, thrown)) {
      _violate(
        'ListenerFailure: $thrown threw, and Scope.errors reports '
        '${reports.map((e) => e.cause).toList()} (expected exactly one '
        'DiListenerException with that error)',
      );
    }
    // NoLostDisposeFailure.
    final carriers = <Object>[];
    final seen = <Future<Object?>>[];
    for (final h in held) {
      final error = h.error;
      if (error == null || seen.any((f) => identical(f, h.future))) continue;
      seen.add(h.future);
      carriers.add(error);
    }
    carriers.addAll(errorEvents);
    FuzzStats.errorEvents += errorEvents.length;
    for (final e in failedDisposeErrors) {
      final n = carriers.where((c) => _carries(c, e)).length;
      if (n != 1) {
        _violate(
          'NoLostDisposeFailure: $e appears in $n mutation results '
          '(expected exactly 1)',
        );
      }
    }
  }

  static bool _carries(Object? carrier, Object tagged) {
    bool inDisposeFailures(List<DisposeFailure> disposeFailures) =>
        disposeFailures.any((i) => identical(i.error, tagged));
    return switch (carrier) {
      DisposeException(:final disposeFailures) => inDisposeFailures(
        disposeFailures,
      ),
      ActivationException(:final rollbackFailures, :final cause) =>
        inDisposeFailures(rollbackFailures) || _carries(cause, tagged),
      ActivationCanceledException(:final rollbackFailures, :final cause) =>
        inDisposeFailures(rollbackFailures) || _carries(cause, tagged),
      _ => false,
    };
  }
}

// ---------------------------------------------------------------------------
// Behavior (the State is the model that the preconditions read)
// ---------------------------------------------------------------------------

/// The flags that a command sequence fixes by itself: for each scope, whether
/// it exists, whether `initialize` was called, and whether its own disposal
/// was requested. A request on a scope also counts for each descendant. The
/// generator and the runner both evolve them through `nextState`, so a
/// precondition gives the same answer at generation, at run, and in every
/// shrink candidate. The flags that depend on gate completions
/// (`initialized`, `disposeCompleted`) stay in the harness, and no
/// precondition reads them.
final class FuzzModel {
  FuzzModel(this.graph)
    : exists = [for (var s = 0; s < graph.scopes.length; s++) s == 0],
      initializeCalled = List<bool>.filled(graph.scopes.length, false),
      disposeRequested = List<bool>.filled(graph.scopes.length, false);

  final GraphDesc graph;
  final List<bool> exists;
  final List<bool> initializeCalled;

  /// Whether the disposal of the scope itself was requested.
  final List<bool> disposeRequested;

  /// Whether the disposal of scope [s] or of an ancestor was requested.
  bool requested(int s) => graph.chain(s).any((j) => disposeRequested[j]);
}

final class FuzzBehavior extends Behavior<FuzzModel, Harness> {
  FuzzBehavior(this.graph);

  final GraphDesc graph;

  @override
  FuzzModel initialState() => FuzzModel(graph);

  @override
  Harness createSystem(FuzzModel state) {
    FuzzStats.cycles++;
    return Harness(state.graph);
  }

  @override
  Future<void> destroySystem(Harness system) => system.close();

  @override
  List<Command<FuzzModel, Harness>> generateCommands(FuzzModel state) {
    final commands = <Command<FuzzModel, Harness>>[];
    for (var s = 0; s < graph.scopes.length; s++) {
      final name = graph.scopeName(s);
      final initialize = Action0<FuzzModel, Harness, void>(
        'InitializeScope($name)',
        precondition: (m) =>
            m.exists[s] && !m.initializeCalled[s] && !m.requested(s),
        nextState: (m) => m.initializeCalled[s] = true,
        run: (h) => h.initializeScope(s),
      );
      final retry = Action0<FuzzModel, Harness, void>(
        'RetryInitialize($name)',
        precondition: (m) =>
            m.exists[s] && m.initializeCalled[s] && !m.requested(s),
        nextState: (m) {},
        run: (h) => h.retryInitialize(s),
      );
      final startDispose = Action0<FuzzModel, Harness, void>(
        'StartDispose($name)',
        precondition: (m) => m.exists[s] && !m.requested(s),
        nextState: (m) => m.disposeRequested[s] = true,
        run: (h) => h.startDispose(s),
      );
      final disposeAgain = Action0<FuzzModel, Harness, void>(
        'DisposeAgain($name)',
        precondition: (m) => m.exists[s] && m.requested(s),
        nextState: (m) {},
        run: (h) => h.disposeAgain(s),
      );
      for (var k = 0; k < (s == 0 ? 4 : 3); k++) {
        commands.add(initialize);
      }
      commands
        ..add(retry)
        ..add(startDispose)
        ..add(disposeAgain);
      if (s == 0) commands.add(retry);
      if (s > 0) {
        final parent = graph.scopes[s].parent;
        final createChild = Action0<FuzzModel, Harness, void>(
          'CreateChild($name)',
          precondition: (m) =>
              !m.exists[s] && m.exists[parent] && !m.requested(parent),
          nextState: (m) => m.exists[s] = true,
          run: (h) => h.createChild(s),
        );
        commands
          ..add(createChild)
          ..add(createChild)
          ..add(createChild);
        final early = Action0<FuzzModel, Harness, void>(
          'InitializeBeforeParent($name)',
          precondition: (m) =>
              m.exists[parent] &&
              !m.initializeCalled[s] &&
              !m.initializeCalled[parent] &&
              !m.requested(s),
          nextState: (m) {
            m.exists[s] = true;
            m.initializeCalled[s] = true;
          },
          run: (h) => h.initializeBeforeParent(s),
        );
        commands.add(early);
      }
    }
    final disposeMember = Action2<FuzzModel, Harness, int, int, void>(
      'DisposeMember',
      integer(min: 0, max: 3),
      integer(min: 0, max: 7),
      nextState: (m, s, i) {},
      run: (h, s, i) => h.disposeMember(s, i),
    );
    final resolve = Action3<FuzzModel, Harness, String, String, int, void>(
      'Resolve',
      constantFrom<String>(['create', 'create', 'dispose']),
      constantFrom<String>([...List.filled(9, 'complete'), 'fail']),
      integer(min: 0, max: 15),
      nextState: (s, kind, outcome, i) {},
      run: (h, kind, outcome, i) => h.resolve(kind, outcome, i),
    );
    final terminal = Finalize<FuzzModel, Harness>(
      Action0<FuzzModel, Harness, void>(
        'Terminal',
        nextState: (s) {},
        run: (h) => h.terminal(),
      ),
    );
    return [
      ...commands,
      disposeMember,
      disposeMember,
      for (var k = 0; k < 40; k++) resolve,
      terminal,
    ];
  }
}
