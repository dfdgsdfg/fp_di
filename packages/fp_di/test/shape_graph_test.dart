// The shape export (R-UC-RT-LC-020), covered by V-T-RT-LC-022.
import 'dart:convert';

import 'package:fp_di/fp_di.dart';
import 'package:fp_di/tooling.dart';
import 'package:test/test.dart';

DiKey<int> _k(String name) => DiKey<int>(name: name);

const _plugins = DiSetKey<int>(name: 'plugins');
const _routes = DiMapKey<int>(name: 'routes');

void main() {
  group('shape export (V-T-RT-LC-022)', () {
    late List<String> created;
    late Module boot;
    late Module module;

    Component<int> member(String name, Dependency<int> dependency) =>
        Component<int>(
          key: _k(name),
          debugLabel: name,
          dependency: dependency.map((value) {
            created.add(name);
            return value;
          }),
        );

    setUp(() {
      created = <String>[];
      boot = Module(
        components: [Component<int>.value(value: 0, key: _k('config'))],
        debugLabel: 'boot',
      );
      module = Module(
        components: [
          // 0, 1, 2: a chain
          member('a', Dependency<int>(create: () => 1)),
          member('b', Dependency.require<int>(key: _k('a'))),
          member('c', Dependency.require<int>(key: _k('b'))),
          // 3, 4: independent members, one with an optional read
          member('d', Dependency<int>(create: () => 1)),
          member('e', Dependency.maybe<int>(key: _k('d')).map((v) => v ?? 0)),
          // 5, 6: two contributors to a set key, 7: its reader
          Component<int>.into(
            key: _plugins,
            debugLabel: 'p1',
            dependency: Dependency<int>(create: () => 1),
          ),
          Component<int>.into(
            key: _plugins,
            debugLabel: 'p2',
            dependency: Dependency<int>(create: () => 2),
          ),
          Component<int>(
            key: _k('pluginCount'),
            debugLabel: 'pluginCount',
            dependency: Dependency.requireSet(
              key: _plugins,
            ).map((set) => set.length),
          ),
          // 8: a map entry, 9: its optional reader
          Component<int>(
            key: _routes.entryKey('home'),
            dependency: Dependency<int>(create: () => 1),
          ),
          Component<int>(
            key: _k('routeCount'),
            debugLabel: 'routeCount',
            dependency: Dependency.maybeMap(
              key: _routes,
            ).map((map) => map.length),
          ),
          // 10: requires a key that only the ancestor publishes
          member('fromBoot', Dependency.require<int>(key: _k('config'))),
          // 11, 12: two members publish one key
          member('dup', Dependency<int>(create: () => 1)),
          member('dup', Dependency<int>(create: () => 2)),
          // 13: requires a key that nothing publishes
          member('lost', Dependency.require<int>(key: _k('nowhere'))),
          // 14, 15: two members that read each other optionally
          member('x', Dependency.maybe<int>(key: _k('y')).map((v) => v ?? 0)),
          member('y', Dependency.maybe<int>(key: _k('x')).map((v) => v ?? 0)),
        ],
        debugLabel: 'app',
      );
    });

    test('lists the members in declaration order with their reads and '
        'creates nothing', () {
      final graph = ShapeGraph.of(module, ancestorModules: [boot]);
      final json = graph.toJsonObject();
      expect(created, isEmpty);
      expect(json['format'], 'fp_di.shape');
      expect(json['version'], 1);
      expect(json['label'], 'app');

      final members = (json['members']! as List).cast<Map<String, Object?>>();
      expect(members, hasLength(16));
      expect([
        for (final m in members) m['index'],
      ], List.generate(16, (i) => i));
      expect(members[1]['label'], 'b');
      expect(members[1]['publishes'], 'DiKey<int>(b)');
      expect(members[1]['requires'], ['DiKey<int>(a)']);
      expect(members[4]['optional'], ['DiKey<int>(d)']);
      expect(members[5]['publishes'], isNull);
      expect(members[5]['contributesTo'], 'DiSetKey<int>(plugins)');
      expect(members[7]['collections'], ['DiSetKey<int>(plugins)']);
      expect(members[8]['publishes'], 'DiMapKey<int>(routes)[home]');
      expect(members[9]['optionalCollections'], ['DiMapKey<int>(routes)']);
      expect(json['contributes'], {'DiSetKey<int>(plugins)': 2});
      // The JSON text is valid and holds the same value.
      expect(jsonDecode(graph.toJson()), json);
    });

    test('each edge names the waiting member, the member it waits for, the '
        'key, and the kind', () {
      final graph = ShapeGraph.of(module, ancestorModules: [boot]);
      final edges = {
        for (final edge in graph.edges)
          (edge.from, edge.to, '${edge.key}', edge.kind),
      };
      expect(edges, {
        (1, 0, 'DiKey<int>(a)', ShapeEdgeKind.require),
        (2, 1, 'DiKey<int>(b)', ShapeEdgeKind.require),
        (4, 3, 'DiKey<int>(d)', ShapeEdgeKind.optional),
        (7, 5, 'DiSetKey<int>(plugins)', ShapeEdgeKind.collection),
        (7, 6, 'DiSetKey<int>(plugins)', ShapeEdgeKind.collection),
        (9, 8, 'DiMapKey<int>(routes)', ShapeEdgeKind.optionalCollection),
        (14, 15, 'DiKey<int>(y)', ShapeEdgeKind.optional),
        (15, 14, 'DiKey<int>(x)', ShapeEdgeKind.optional),
      });
      expect(
        graph.edges.where((edge) => edge.from == 10),
        isEmpty,
        reason: 'no edge to an ancestor member',
      );
    });

    test('depths follow the waits and the longest chain is the three '
        'members', () {
      final graph = ShapeGraph.of(module, ancestorModules: [boot]);
      expect(graph.depths.sublist(0, 10), [1, 2, 3, 1, 2, 1, 1, 2, 1, 2]);
      expect(graph.longestChain, [0, 1, 2]);
    });

    test('an ancestor key is undeclared only without the ancestor; a '
        'duplicate and an undeclared key are reported without an error', () {
      final withBoot = ShapeGraph.of(module, ancestorModules: [boot]);
      expect(withBoot.undeclared.map((key) => '$key'), ['DiKey<int>(nowhere)']);
      expect(withBoot.duplicates.map((key) => '$key'), ['DiKey<int>(dup)']);

      final alone = ShapeGraph.of(module);
      expect(alone.undeclared.map((key) => '$key'), [
        'DiKey<int>(config)',
        'DiKey<int>(nowhere)',
      ]);
      final json = alone.toJsonObject();
      expect(json['undeclared'], ['DiKey<int>(config)', 'DiKey<int>(nowhere)']);
      expect(json['duplicates'], ['DiKey<int>(dup)']);
      expect((json['ancestors']! as Map)['publishes'], isEmpty);
      expect((withBoot.toJsonObject()['ancestors']! as Map)['labels'], [
        'boot',
      ]);
    });

    test('two members that read each other form one cycle of one depth', () {
      final graph = ShapeGraph.of(module, ancestorModules: [boot]);
      expect(graph.cycles, [
        [14, 15],
      ]);
      expect(graph.depths[14], graph.depths[15]);
      expect(graph.toJsonObject()['cycles'], [
        [14, 15],
      ]);
    });

    test('an empty module has no member, edge, or chain', () {
      final graph = ShapeGraph.of(Module(components: const []));
      expect(graph.depths, isEmpty);
      expect(graph.edges, isEmpty);
      expect(graph.longestChain, isEmpty);
      expect(graph.toMermaid(), 'flowchart BT');
    });

    test('the Mermaid text has one node for each member and one line for '
        'each edge, and creates nothing', () {
      final graph = ShapeGraph.of(module);
      expect(graph.toMermaid().split('\n'), [
        'flowchart BT',
        '  m0["a"]',
        '  m1["b"]',
        '  m2["c"]',
        '  m3["d"]',
        '  m4["e"]',
        '  m5["p1"]',
        '  m6["p2"]',
        '  m7["pluginCount"]',
        // A member without a label has the text of its key.
        '  m8["DiMapKey#lt;int#gt;(routes)[home]"]',
        '  m9["routeCount"]',
        '  m10["fromBoot"]',
        // Two members of one label stay two nodes.
        '  m11["dup"]',
        '  m12["dup"]',
        '  m13["lost"]',
        '  m14["x"]',
        '  m15["y"]',
        '  m1 --> m0',
        '  m2 --> m1',
        '  m4 -.-> m3',
        '  m7 ==>|"DiSetKey#lt;int#gt;(plugins)"| m5',
        '  m7 ==>|"DiSetKey#lt;int#gt;(plugins)"| m6',
        '  m9 -.->|"DiMapKey#lt;int#gt;(routes)"| m8',
        '  m14 -.-> m15',
        '  m15 -.-> m14',
      ]);
      expect(created, isEmpty);
    });

    test('the Mermaid text with an ancestor has one subgraph for each scope '
        'and an arrow for the read that the ancestor answers', () {
      final lines = ShapeGraph.of(
        module,
        ancestorModules: [boot],
      ).toMermaid().split('\n');
      expect(lines.sublist(0, 5), [
        'flowchart BT',
        '  subgraph s0["boot"]',
        '    s0m0["DiKey#lt;int#gt;(config)"]',
        '  end',
        '  subgraph s1["app"]',
      ]);
      expect(lines.sublist(5, 21), [
        for (var i = 0; i < 16; i++) startsWith('    m$i["'),
      ]);
      expect(lines[21], '  end');
      // The eight edges of the module, then the read that crosses the scope.
      expect(lines, hasLength(31));
      expect(lines[22], '  m1 --> m0');
      expect(lines.last, '  m10 --> s0m0');
      expect(created, isEmpty);
    });

    test('the Mermaid text draws a read to the nearest scope that declares '
        'a publisher, and a collection read to every ancestor', () {
      Component<int> value(String name) =>
          Component<int>.value(value: 0, key: _k(name), debugLabel: name);
      Component<int> plugin(String label) => Component<int>.into(
        key: _plugins,
        debugLabel: label,
        dependency: Dependency<int>(create: () => 1),
      );
      Component<int> route(String id, String label) => Component<int>(
        key: _routes.entryKey(id),
        debugLabel: label,
        dependency: Dependency<int>(create: () => 1),
      );
      final root = Module(
        components: [
          value('far'),
          value('shadowed'),
          value('own'),
          plugin('rootPlugin'),
          route('home', 'rootHome'),
          route('about', 'rootAbout'),
          value('unread'),
        ],
        debugLabel: 'root "app"',
      );
      // No member of the module reads this scope, so it has no subgraph.
      final silent = Module(components: [value('other')]);
      final parent = Module(
        components: [
          value('shadowed'),
          plugin('parentPlugin'),
          route('home', 'parentHome'),
        ],
      );
      final child = Module(
        components: [
          value('own'),
          member(
            'reader',
            (
              Dependency.require<int>(key: _k('far')),
              Dependency.maybe<int>(key: _k('shadowed')),
              Dependency.require<int>(key: _k('own')),
            ).zip.map((_) => 0),
          ),
          plugin('childPlugin'),
          member(
            'collector',
            (
              Dependency.requireSet(key: _plugins),
              Dependency.maybeMap(key: _routes),
            ).zip.map((_) => 0),
          ),
        ],
      );
      final graph = ShapeGraph.of(
        child,
        ancestorModules: [root, silent, parent],
      );
      expect(graph.toMermaid().split('\n'), [
        'flowchart BT',
        '  subgraph s0["root #quot;app#quot;"]',
        '    s0m0["far"]',
        '    s0m3["rootPlugin"]',
        '    s0m5["rootAbout"]',
        '  end',
        '  subgraph s2["scope 2"]',
        '    s2m0["shadowed"]',
        '    s2m1["parentPlugin"]',
        '    s2m2["parentHome"]',
        '  end',
        '  subgraph s3["scope 3"]',
        '    m0["own"]',
        '    m1["reader"]',
        '    m2["childPlugin"]',
        '    m3["collector"]',
        '  end',
        '  m1 --> m0',
        '  m3 ==>|"DiSetKey#lt;int#gt;(plugins)"| m2',
        '  m1 --> s0m0',
        '  m1 -.-> s2m0',
        '  m3 ==>|"DiSetKey#lt;int#gt;(plugins)"| s0m3',
        '  m3 ==>|"DiSetKey#lt;int#gt;(plugins)"| s2m1',
        '  m3 -.->|"DiMapKey#lt;int#gt;(routes)"| s2m2',
        '  m3 -.->|"DiMapKey#lt;int#gt;(routes)"| s0m5',
      ]);
      // The reads that cross a scope are not waits of `initialize`.
      expect(graph.edges, hasLength(2));
      expect(created, isEmpty);
    });

    test('the Mermaid text draws the members of one origin as one subgraph '
        'in their scope, and the JSON states the origin', () {
      Component<int> value(String name) =>
          Component<int>.value(value: 0, key: _k(name), debugLabel: name);
      final root = Module.all(
        modules: [
          Module(components: [value('config')], debugLabel: 'core <boot>'),
          Module(components: [value('clock'), value('unread')]),
          Module(components: [value('http')], debugLabel: 'net'),
        ],
      );
      final child = Module.all(
        modules: [
          Module(
            components: [member('login', Dependency.require(key: _k('http')))],
            debugLabel: 'auth',
          ),
          Module(
            components: [member('free', Dependency.require(key: _k('clock')))],
          ),
          Module(
            components: [member('feed', Dependency.require(key: _k('login')))],
            debugLabel: 'feed',
          ),
          Module(
            components: [
              member('token', Dependency.require(key: _k('config'))),
            ],
            debugLabel: 'auth',
          ),
        ],
      );

      final alone = ShapeGraph.of(child);
      expect(
        [
          for (final m in alone.toJsonObject()['members']! as List)
            (m as Map)['origin'],
        ],
        ['auth', null, 'feed', 'auth'],
      );
      // Without an ancestor, the subgraphs of the origins are at the top.
      expect(alone.toMermaid().split('\n'), [
        'flowchart BT',
        '  m1["free"]',
        '  subgraph g0["auth"]',
        '    m0["login"]',
        '    m3["token"]',
        '  end',
        '  subgraph g1["feed"]',
        '    m2["feed"]',
        '  end',
        '  m2 --> m0',
      ]);

      expect(
        ShapeGraph.of(child, ancestorModules: [root]).toMermaid().split('\n'),
        [
          'flowchart BT',
          '  subgraph s0["scope 0"]',
          '    s0m1["clock"]',
          '    subgraph s0g0["core #lt;boot#gt;"]',
          '      s0m0["config"]',
          '    end',
          '    subgraph s0g1["net"]',
          '      s0m3["http"]',
          '    end',
          '  end',
          '  subgraph s1["scope 1"]',
          '    m1["free"]',
          '    subgraph g0["auth"]',
          '      m0["login"]',
          '      m3["token"]',
          '    end',
          '    subgraph g1["feed"]',
          '      m2["feed"]',
          '    end',
          '  end',
          '  m2 --> m0',
          '  m0 --> s0m3',
          '  m1 --> s0m1',
          '  m3 --> s0m0',
        ],
      );

      // Collapsed, each origin is one node with the id of its subgraph, and
      // the members without an origin are the node of the scope.
      expect(alone.toMermaid(collapsed: true).split('\n'), [
        'flowchart BT',
        '  r["scope 0<br/>1 member"]',
        '  g0["auth<br/>2 members"]',
        '  g1["feed<br/>1 member"]',
        '  g1 -->|"1"| g0',
      ]);
      // A node of an ancestor states every member of its origin: `unread`
      // counts in `s0r`, and no arrow reaches it.
      expect(
        ShapeGraph.of(
          child,
          ancestorModules: [root],
        ).toMermaid(collapsed: true).split('\n'),
        [
          'flowchart BT',
          '  subgraph s0["scope 0"]',
          '    s0r["scope 0<br/>2 members"]',
          '    s0g0["core #lt;boot#gt;<br/>1 member"]',
          '    s0g1["net<br/>1 member"]',
          '  end',
          '  subgraph s1["scope 1"]',
          '    r["scope 1<br/>1 member"]',
          '    g0["auth<br/>2 members"]',
          '    g1["feed<br/>1 member"]',
          '  end',
          '  g1 -->|"1"| g0',
          '  g0 -->|"1"| s0g1',
          '  r -->|"1"| s0r',
          '  g0 -->|"1"| s0g0',
        ],
      );

      // A member with the label of its own module is in no subgraph.
      final labeled = Module(components: [value('one')], debugLabel: 'app');
      expect(ShapeGraph.of(labeled).toMermaid().split('\n'), [
        'flowchart BT',
        '  m0["one"]',
      ]);
      expect(created, isEmpty);
    });

    test('the collapsed Mermaid text counts the reads between two origins '
        'and draws a dotted line when all of them are optional', () {
      Dependency<int> reads({
        List<String> require = const [],
        List<String> maybe = const [],
      }) => <Dependency<int>>[
        for (final name in require) Dependency.require<int>(key: _k(name)),
        for (final name in maybe)
          Dependency.maybe<int>(key: _k(name)).map((value) => value ?? 0),
      ].reduce((left, right) => (left, right).zip.map((_) => 0));
      final app = Module.all(
        modules: [
          Module(
            components: [
              member('a', Dependency<int>(create: () => 1)),
              // A read inside one origin has no arrow.
              member('b', reads(require: ['a'])),
            ],
            debugLabel: 'core',
          ),
          Module(
            components: [
              member('c', reads(maybe: ['a'])),
              member('d', reads(maybe: ['b'])),
            ],
            debugLabel: 'ui',
          ),
          // A part with the label of the composed module has no subgraph.
          Module(
            components: [
              member('e', reads(require: ['a'], maybe: ['b', 'c'])),
            ],
            debugLabel: 'app',
          ),
          Module(
            components: [
              member('f', reads(require: ['c'], maybe: ['a'])),
            ],
            debugLabel: 'data',
          ),
        ],
        debugLabel: 'app',
      );
      final graph = ShapeGraph.of(app);
      expect(graph.toJsonObject()['label'], 'app');
      expect(graph.edges, hasLength(8));
      expect(graph.toMermaid(collapsed: true).split('\n'), [
        'flowchart BT',
        '  r["app<br/>1 member"]',
        '  g0["core<br/>2 members"]',
        '  g1["ui<br/>2 members"]',
        '  g2["data<br/>1 member"]',
        '  g1 -.->|"2"| g0',
        // One required read makes the line solid.
        '  r -->|"2"| g0',
        '  r -.->|"1"| g1',
        '  g2 -->|"1"| g1',
        '  g2 -.->|"1"| g0',
      ]);
      // The full chart has the same ids for the subgraphs.
      expect(
        graph.toMermaid().split('\n').where((line) => line.contains('[')),
        [
          '  m4["e"]',
          '  subgraph g0["core"]',
          '    m0["a"]',
          '    m1["b"]',
          '  subgraph g1["ui"]',
          '    m2["c"]',
          '    m3["d"]',
          '  subgraph g2["data"]',
          '    m5["f"]',
        ],
      );
      // A module without origins collapses to one node, and an empty module
      // to none.
      expect(ShapeGraph.of(module).toMermaid(collapsed: true).split('\n'), [
        'flowchart BT',
        '  r["app<br/>16 members"]',
      ]);
      expect(
        ShapeGraph.of(Module(components: const [])).toMermaid(collapsed: true),
        'flowchart BT',
      );
      expect(created, isEmpty);
    });

    test('the Mermaid text keeps a label with markup characters in one '
        'quoted label', () {
      final graph = ShapeGraph.of(
        Module(
          components: [
            Component<int>(
              key: _k('a'),
              debugLabel: 'say "hi" <b> #1 & `x`\r\nnext [y] | (z)',
              dependency: Dependency<int>(create: () => 1),
            ),
          ],
        ),
      );
      expect(graph.toMermaid().split('\n'), [
        'flowchart BT',
        '  m0["say #quot;hi#quot; #lt;b#gt; #35;1 #amp; #96;x#96;<br/>'
            'next [y] | (z)"]',
      ]);
    });
  });
}
