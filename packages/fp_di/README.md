# fp_di - Algebraic dependency injection for Dart

**Automatic ordering. Safe release. Composed like functions and their
inverses.**

Each dependency is a pair: `create` makes a value from the keys that it reads,
and `dispose` releases that value. Pairs combine like functions with their
inverses. The `create` functions run forward, and the `dispose` functions run
backward:

```text
(c₂, d₂) · (c₁, d₁)  =  (c₂ ∘ c₁ ,  d₁ ∘ d₂)
```

A `Dependency` is such a pair. A `Component` publishes its value under a key. A
`Module` is a list of components that you combine, edit, and inspect before
anything runs. A `Scope` runs a module. The order of activation, the members
that start at the same time, the work that a failure rolls back, and the order
of release all follow from the keys that each component reads and publishes.

```dart
final database = Component<Database>(
  dependency: Dependency<Database>(
    create: () => Database('postgres://local'), // runs on each activation
    dispose: (db) => db.close(),
  ),
);

final repository = Component<UserRepository>(
  dependency: Dependency1<Database, UserRepository>(
    create: UserRepository.new,
  ),
);

// Declared in any order. Nothing is created yet.
final app = Scope(module: Module(components: [repository, database]));

await app.initialize();   // the database first, then the repository
app.get<UserRepository>();
await app.dispose();      // the repository first, then the database
```

The repository reads `Database`, so the runtime creates the database first and
releases it last. The list order does not matter.

## Why fp_di

- **The order is computed.** A component states the keys that it reads. The
  runtime orders creation, release, and rollback by those keys, so you write
  no registration order and no teardown sequence.
- **A declaration is data.** A module is a value. A test or a variant of the
  application edits it before a scope exists, and a script exports its graph
  as JSON or Mermaid.
- **Mistakes fail early.** `initialize` rejects a key that no declaration
  publishes and a key that two members publish, before it creates anything.
- **Setup is atomic.** A failed `initialize` releases everything that it
  created, in reverse order, and the scope can try again.
- **A missing key waits.** A component whose key is not there yet does not
  fail. It activates when a publisher appears, and it releases when the
  publisher goes away.
- **Release is ordered.** A component releases while the values that it read
  are still alive. Members that do not read each other activate and release at
  the same time.

The core package has no dependencies and does not import Flutter.
[`fp_di_flutter`](https://github.com/dfdgsdfg/fp_di/tree/main/packages/fp_di_flutter) publishes a scope to the widget tree.

## Dependencies are values

A `Dependency<T>` is a pair of functions: `create` makes a `T` from the keys
that it reads, and `dispose` releases that `T`. Building or combining a
`Dependency` runs nothing; a scope runs it when its component activates.

```dart
// (open, close): a pool that the scope closes when it releases the component.
final pool = Dependency1<Config, Pool>(
  create: (config) => Pool.open(config.url),
  dispose: (pool) => pool.close(),
);

// (lease, release) after (open, close): create runs open, then lease;
// dispose runs release, then close.
final session = pool.map((pool) => pool.lease(), dispose: (s) => s.release());
```

[Pairs](#pairs) states how pairs combine. The other forms:

```dart
// No input.
Dependency<Clock>(create: SystemClock.new);

// One to eight inputs, the common case: like ProxyProvider2 of provider.
Dependency2<Config, HttpClient, Api>(create: Api.new);

// A chain: several steps, optional reads, and lazy values.
Dependency.require<Config>()
    .map((config) => HttpClient(config.baseUrl), dispose: (http) => http.close());
Dependency.maybe<Analytics>();          // null while no member publishes it
Dependency.require<Database>().lazy();  // created at the first force()

// A record of dependencies is one dependency of a record.
(Dependency.require<Config>(), Dependency.maybe<Analytics>()).zip
    .mapN((config, analytics) => Tracker(config, analytics));
```

Each `Dependency` has a **shape**: the keys that it requires and the keys that
it reads optionally. The shape is computed from the expression, never written
by hand. [The algebra](#the-algebra) states the rules.

A step without `dispose` is a pair whose `dispose` does nothing.

## Modules are values

A `Component<T>` publishes the value of its `Dependency` under `DiKey<T>()`,
or under a named key. Its shape adds that key to the reads of its
`Dependency`. `Component.effect` publishes no key, and `Component.value` wraps
an existing value.

A `Module` lists components. A package exports a module, and the application
composes modules with `Module.all` or `+`. The shape of a module is computed
from its members:

```dart
final infrastructure = Module(components: [database, cache], debugLabel: 'infra');
final features = Module(components: [repository, checkout]);
final all = infrastructure + features;

all.publishes;   // every key that a member publishes
all.requires;    // the required keys that no other member publishes
all.reads;       // requires plus the keys read optionally
```

`requires` of a module is what an ancestor scope must publish. A member that
requires the key that it publishes itself still needs another publisher.

Each edit returns a new module and keeps the position of every remaining
member:

```dart
// A test replaces real members with fakes. A fake whose key no member
// publishes is an error, so a moved or misspelled key fails.
final underTest = all.overriddenBy(
  Module(components: [Component<Api>.value(value: FakeApi())]),
);

// A web build has no camera. Remove each member that requires it, directly
// or through the key of another removed member.
final absent = {const DiKey<Camera>()};
final web = all.withoutRequiring(keys: absent);
final removed = all.requiring(keys: absent);   // a test compares the list
```

`replacing`, `without`, and `where` edit one member or a selection. The
application chooses members with plain Dart conditionals: `fp_di` has no
profile concept.

`package:fp_di/tooling.dart` exports the shape of a module without running it.
`ShapeGraph` lists the waits between members, the depth of each member, the
longest chain of activations, the cycles, and the keys that `initialize` would
reject:

```dart
import 'package:fp_di/tooling.dart';

final graph = ShapeGraph.of(features, ancestorModules: [infrastructure]);
graph.undeclared;    // keys that initialize would reject
graph.toJson();      // for a test or a build step
graph.toMermaid();   // a flowchart that GitHub draws
```

## The lifecycle follows from the keys

A scope takes its module when it is created. `initialize` creates the members,
and `dispose` releases them. A child scope reads the keys of its ancestors.

```dart
final app = await Scope(module: appModule).initialize();

// A login creates a child scope, and a logout disposes it.
final session = await app
    .child(module: sessionModule(userId))
    .initialize();
await session.dispose();   // the app scope stays
```

| Moment | What the runtime does |
|---|---|
| `initialize` starts | Rejects a required key that no member of the scope or its ancestors publishes (`UndeclaredKeyError`), and a key that two members publish (`DuplicateKeyError`), before it creates anything. |
| A member activates | Starts when each member that publishes a key that it reads has settled. Members without such a key start at the same time, so a scope of slow members takes as long as its slowest chain. |
| A member fails | No further member starts. After the members in flight settle, every node of the call is released in reverse declaration order, and `initialize` rethrows the first failure. The scope can try again. |
| A key is missing | The member waits instead of failing. It activates when a publisher appears, and it releases before that publisher goes away. |
| `dispose` runs | A member releases after every member that read its value. Members that do not read each other release at the same time. Failed dispose functions are collected in one `DisposeException`. |

The keys are the only order. When a member needs the effect of another member,
such as a logger that must be set up first, the other member publishes a
token type, and the first member requires it.

## Observing a scope

`Scope.state` returns an immutable value: the phase of the scope, the state of
each node, and the states of the child scopes. `addListener` calls a function
at each transition, so a debugger or a UI compares two values.

```dart
final node = app.findNode<UserRepository>();
node?.state.phase;   // NodePhase.waiting while no member publishes Database
node?.missing;       // [DiKey<Database>]: the required keys that do not resolve
await node?.whenActive;   // completes when the node activates

print(app.describe());   // one line for each node, with its state
```

To wait for a value without knowing which scope publishes it or when that
scope initializes, use `getWhenAvailable`:

```dart
// Completes once the key has a value, also from a parent that is not
// initialized yet. Fails with the cause when an activation fails behind it.
final repo = await session.getWhenAvailable<UserRepository>();
```

`get` throws an `UnavailableKeyException` that names the failed activations
behind the key, so an error view needs no listener.

## The algebra

### Pairs

A step is a pair `(c, d)` of a `create` function `c` and a `dispose` function
`d`, which receives the value that `c` returned. A step without `dispose` has
the `dispose` that does nothing. Steps combine like functions with their
inverses: the `create` functions run forward, and the `dispose` functions run
backward.

```text
step:      (c, d)                       d releases what c created

sequence:  (c₂, d₂) · (c₁, d₁)  =  (c₂ ∘ c₁ ,  d₁ ∘ d₂)       dep.map(c₂, dispose: d₂)
product:   (c₁, d₁) ⊗ (c₂, d₂)  =  (c₁ then c₂ ,  d₂ then d₁)  (dep1, dep2).zip
unit:      (id, no-op)                                        dep.map((x) => x)

failure:   c₁ … c_{j-1} completed and c_j throws
           ⇒  d_{j-1} ∘ … ∘ d₁ runs, and the failure is rethrown
```

In the sequence line, `dep` is the step `(c₁, d₁)`. `·` is associative and has
the unit `(id, no-op)`, so a chain of steps is one pair whatever its grouping.
In the runtime, the unit and the regrouping hold for the published value of an
activation that no cancellation interrupts, as [Laws](#laws) states. The
paper in [Inspiration](#inspiration) calls this composition of a function
with its inverse the twisted composition (Definition 1).

A component is the pair of its whole chain. A scope composes the pairs of its
members in the same way along the keys: the `create` of a member runs after the
`create` of each member whose key it reads, and its `dispose` runs before
their `dispose`. [The lifecycle](#the-lifecycle-follows-from-the-keys) states
that order.

### Shapes

Each value of the API has a shape, and each combinator computes the shape of
its result from the shapes of its parts. The rules below restate the
[lifecycle spec](https://github.com/dfdgsdfg/fp_di/blob/main/specs/runtime/lifecycle/spec.md#shape-algebra), whose
rules the tests of the package check. The two rules for `+` follow from the
rules for a module. Read `A` as `DiKey<A>()`.

**A `Dependency`** has `requires(d)`, the keys that must resolve before it
runs, and `optional(d)`, the keys that it reads and that may be absent.

```text
requires(Dependency(create, dispose))   = ∅
requires(Dependency.require<A>())       = {A}
optional(Dependency.maybe<A>())         = {A}
requires(DependencyN<A1, …, An, R>(…))  = {A1, …, An}

shape(d.map(f, dispose)) = shape(d.lazy()) = shape(d)

requires((d1, …, dn).zip) = requires(d1) ∪ … ∪ requires(dn)
optional((d1, …, dn).zip) = optional(d1) ∪ … ∪ optional(dn)
```

Each `optional` above that is not stated is ∅, and so is each `requires` of
`Dependency.maybe`. A step adds no key, and a combination is the union of its
parts.

**A `Component`** keeps the reads of its `Dependency` and adds the key that it
publishes. A collection read (`Dependency.requireSet`, `requireMap`, and their
`maybe` forms) adds its key to `reads`, not to `requires`, because an empty
collection is valid.

```text
requires(Component<A>(d)) = requires(d)       optional(Component<A>(d)) = optional(d)

publishes(Component<A>(d))         = {A}
publishes(Component<A>(d, key: k)) = {k}
publishes(Component.effect(d))     = ∅

reads(c) = requires(c) ∪ optional(c) ∪ collectionKeys(c) ∪ optionalCollectionKeys(c)
```

**A `Module`** `m = Module([c1, …, cn])` publishes what its members publish.
It requires what a member requires and no other member publishes, so
`requires(m)` is what an ancestor scope must publish.

```text
publishes(m) = publishes(c1) ∪ … ∪ publishes(cn)
requires(m)  = ⋃i ( requires(ci) \ ⋃j≠i publishes(cj) )

publishes(m1 + m2) = publishes(m1) ∪ publishes(m2)
requires(m1 + m2)  ⊆ requires(m1) ∪ requires(m2)
```

A composition never adds a requirement: a member of one module can only
satisfy a requirement of the other. A member that requires the key that it
publishes itself still needs another publisher, because `j ≠ i`.

An edit returns a new module. For a set of absent keys `K` and the keys `A`
that an ancestor also publishes, `requiring` and `withoutRequiring` divide the
members:

```text
components(requiring(m, K, A)) ⊎ components(withoutRequiring(m, K, A)) = components(m)

requires(c) ∩ K = ∅                         for each c in withoutRequiring(m, K, A)
requires(withoutRequiring(m, K, A))  ⊆  requires(m) ∪ A
```

The removal never adds a requirement that the caller did not name.

**The lifecycle** follows from one relation. Write `a ⇢ b` when `b` reads a
key that `a` provides: the key that `a` publishes, the set key that `a`
contributes to, or the map key of an entry that `a` publishes.

```text
a ⇢ b   ⇔   provides(a) ∩ reads(b) ≠ ∅

initialize:  b starts after each a with a ⇢ b has settled
dispose:     a releases after each b that read a value of a
             members without a path of ⇢ between them run at the same time
rollback:    when the steps e₁ … e_k of an activation completed, the release
             runs e_k⁻¹ … e₁⁻¹
```

The runtime computes `⇢` from the shapes before it creates anything.
`initialize` therefore rejects a module when no ancestor declares a key of
`requires(m)`, and `ShapeGraph` exports `⇢` as the edges of a graph.

### Laws

The rules give laws, and property tests in
[`test/laws_test.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/test/laws_test.dart) check each one with generated
dependencies, components, modules, and chains. A module has no `==`, so a law
about modules compares their members and origins.

```text
-- Shape: no condition
shape((d1, …, dn).zip)   = shape(d1) ∪ … ∪ shape(dn)
shape(d.map(f))          = shape(d.lazy()) = shape(d)
shape(((a, b).zip, c).zip) = shape((a, (b, c).zip).zip)

-- Modules: members and origins
(m1 + m2) + m3   =  m1 + (m2 + m3)  =  Module.all([m1, m2, m3])
m + Module([])   =  Module([]) + m  =  m
publishes(m1 + m2) = publishes(m1) ∪ publishes(m2)
requires(m1 + m2)  ⊆ requires(m1) ∪ requires(m2)
requires(m)        ⊆ reads(m)

-- Values: the published value of an activation that no cancellation interrupts
d.map(id)          ≡  d
d.map(f).map(g)    ≡  d.map(g ∘ f)
((a, b).zip, c).zip  ≡  (a, (b, c).zip).zip        as ((x, y), z) and (x, (y, z))

-- Releases
dispose of the steps e₁ … eₙ   runs   eₙ⁻¹ … e₁⁻¹
step e_j throws                ⇒     e_{j-1}⁻¹ … e₁⁻¹ run before initialize throws,
                                     and no later step runs
```

The value laws have a condition because a `map` step is a cancellation
checkpoint: when a cancellation arrives between two steps, `d.map(id)` stops
where `d` completes. `e⁻¹` is the dispose function of a step that has one.
The laws are about `fp_di` itself. They do not import the theorems of the
paper in [Inspiration](#inspiration), whose premises `fp_di` does not check.

### Limits

- A pair is an inverse only if its `dispose` undoes its `create`. A `dispose`
  function is supplied by the author. The runtime orders and collects the
  dispose functions, but it cannot prove that one restores the state.
- The laws hold under their conditions. The value laws compare the published
  value of an activation that no cancellation interrupts. A `Dependency` and
  a `Module` have no `==`, so no law states that two of them are equal.
- Members that do not read each other activate and release at the same time.
  The runtime does not check that their effects are independent. Members that
  share an external resource without a key between them need a token key.
- The steps of one component run one after another.
- Separate `initialize` and `dispose` calls run one after another on one queue.
- The contents of a scope are fixed when the scope is created. A new set of
  components is a new child scope.
- Each member publishes when it commits. Publish one record under one key when
  several values must become visible together.

### Inspiration

The design adapts a subset of *A Programming Paradigm for Spatiotemporal
Composability* by Yifan Shi, Wei Zhang, and Tianyi Cui
([arXiv:2608.25512](https://arxiv.org/abs/2608.25512v1)): revertible effects,
whose release is tracked with their creation, and reactive coeffects, whose
declared reads drive activation. `fp_di` keeps a small Dart API and does not
import the theorems of the paper as guarantees. The
[paper adoption](https://github.com/dfdgsdfg/fp_di/blob/main/specs/architecture/spec.md#paper-adoption) table states
what is adopted, what is adapted, and what is left out.

## Learn more

- The API reference groups the types in six topics: Dependency, Declaration,
  Keys, Lifecycle, Observation, and Errors and exceptions. Each topic page explains
  its part in detail; the pages are in
  [`doc/`](https://github.com/dfdgsdfg/fp_di/tree/main/packages/fp_di/doc), and
  [`doc/lifecycle.md`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/doc/lifecycle.md)
  draws the states of a node and of a scope.
- Coming from get_it? [`doc/from_get_it.md`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/doc/from_get_it.md)
  maps each get_it call to its `fp_di` form and suggests an order for moving
  an application over.
- Each file in [`example/`](https://github.com/dfdgsdfg/fp_di/tree/main/packages/fp_di/example) runs with `dart run`:

  | Example | Shows |
  |---|---|
  | [`basic.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/basic.dart) | Two components in one scope |
  | [`chaining.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/chaining.dart) | Several steps in one component |
  | [`parallel.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/parallel.dart) | Independent members at the same time |
  | [`token_key.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/token_key.dart) | A token key orders a member after an effect |
  | [`session_scope.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/session_scope.dart) | A login scope and a logout |
  | [`environments.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/environments.dart) | Platform, flavor, test fakes, and a two-stage start |
  | [`collections.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/collections.dart) | Many elements of one interface in one set or map |
  | [`shape_export.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/shape_export.dart) | The shape of each variant as JSON and Mermaid |
  | [`rollback.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/rollback.dart) | A failed `initialize` rolls back and tries again |
  | [`cancellation.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/cancellation.dart) | A logout during a login, a withdrawn value, a failed step |
  | [`lazy.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/lazy.dart) | A value created on first use |
  | [`factory.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/factory.dart) | A new value for each call |
  | [`cached_factory.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/cached_factory.dart) | One value for each id, released with the factory |
  | [`diagnostics.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/diagnostics.dart) | `describe`, `missing`, `whenActive`, and a forgotten key |
  | [`reactive.dart`](https://github.com/dfdgsdfg/fp_di/blob/main/packages/fp_di/example/reactive.dart) | A nearer publisher reaches only its readers |

- The [specifications](https://github.com/dfdgsdfg/fp_di/blob/main/specs/spec.md) state the requirements, the
  design, and the decisions.

## Installation

```sh
dart pub add fp_di
```

For Flutter, add [`fp_di_flutter`](https://pub.dev/packages/fp_di_flutter) too:

```sh
flutter pub add fp_di fp_di_flutter
```
