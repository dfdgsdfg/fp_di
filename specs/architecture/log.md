---
type: log
title: "Project Architecture Decision Log"
description: "Accepted decisions affecting project architecture and package boundaries."
tags: [architecture, decisions]
---

# Project Architecture Decision Log

Significant accepted changes to boundaries are recorded here. Existing package
structure is described in the spec; documenting it does not invent a historical decision.

## [2026-09-08] decision | Keep fpdart interoperability at the host boundary

- Context: The core currently has no package dependencies. Functional application code needs to combine its values and tasks with DI without confusing domain results with activation failure or task execution with resource ownership.
- Decision: Define interoperability against the fpdart 1.2.0 API at the host boundary, preserve the core's public handle and exception semantics, and keep fpdart out of the production core and Flutter adapter dependencies.
- Consequences: Hosts can use Option, Either, and TaskEither without coupling the runtime to a functional-library release. Hosts explicitly choose Left handling and dispose acquired handles; a separately pinned integration fixture is required to verify that contract. A packaged bridge would require a separate design decision.
- References: [Interoperability contract](spec.md#fpdart-interoperability), verification gap.

## [2026-11-03] decision | ComponentScope renders child only while the component is active

- Context: `ComponentScope` rendered `child` as soon as a handle existed. A component that waited for a dependency, or lost it, left descendants to call `di<T>()` against missing bindings. The previous profile excluded this gating without a recorded reason, and the adapter README listed it as a known gap.
- Decision: `ComponentScope` listens to its owned scope and renders `loading` whenever the handle is inactive. It renders `child` only while the handle is active. The reinstall-on-identity rule is now documented, and hosts SHOULD create the component outside `build`.
- Consequences: A withdrawal unmounts the subtree and discards its `State`; descendants never observe an inactive component's bindings. A separate inactive placeholder was not added, to keep the widget surface small.
- References: [Flutter integration](spec.md#flutter-integration), V-T-AR-UI-005.

## [2026-11-03] decision | Export types only; move constructors into their types

- Context: `fp_di` exported `pure`, `require`, `maybe`, `provide`, `acquire`, `perform`, `lazy`, `reversible`, `all`, and `component` as top-level functions, and `fp_di_flutter` exported `diContextOf`. These short names entered every importing library, and they could collide with other functional libraries.
- Decision: The constructors are static members of `Component`, following the fpdart convention. The imperative escape hatch `component` becomes `Component.imperative`. `diContextOf` becomes `FpDiScope.of`, following the Flutter `X.of` convention. No deprecated top-level aliases are kept.
- Consequences: Call sites are longer (`Component.require<Database>()`), and every caller must migrate at once. Both packages are unpublished, so the migration cost is limited to this workspace. The public surface now groups each operation under the type it creates.
- References: [Public API Namespaces](spec.md#public-api-namespaces).

## [2026-11-08] decision | Chain only for algebra and type constraints

- Context: `Component.publish(value, key:)`, `named(label)`, and `DiScope.override(key, value)` mixed two forms. A value and a key in one call let Dart infer a common supertype, so `Component.publish(Foo(), key: DiKey<Bar>())` compiled as `Component<Object>`. A chained `published` rejected the same mismatch. `named` chained but changed neither the value nor the type.
- Decision: A public method chains only for an algebraic step or when the type of its receiver constrains its argument. Other metadata is a named argument. `named(label)` becomes the `name` argument of `Component` and `Component.value`. `Component.publish(value, key:)` becomes `Component.value(value).published(key:)`. `DiScope.override(key, value)` keeps two arguments, because it is an imperative mutation that returns a `Future`, and it checks the value against the runtime type of the key at the call.
- Consequences: A key that does not match the component type is a compile error for every component. An implementation published under a port key needs an explicit type argument, because Dart has no lower bound for a method type argument. An override mismatch is detected at run time, not at compile time.
- References: [Chaining and arguments](spec.md#chaining-and-arguments), [component.dart](../../packages/fp_di/lib/src/model/component.dart), [context.dart](../../packages/fp_di/lib/src/model/context.dart).

## [2026-11-08] decision | One name for each scope operation

- Context: `DiScope` had two names for lookup (`get` and `require`) and two for install (`use` and `install`). `DiScope.root()` made a root look like a separate concept, and `scope.scope()` used one word as a noun and a verb. The scope tree was not visible in the names.
- Decision: The aliases `require` and `install` are removed. The unnamed constructor `DiScope()` creates a root scope with its own runtime, and `child()` creates a child scope. The scope surface is `child`, `use`, `useModule`, `get`, `maybeGet`, `describe`, and `dispose`.
- Consequences: A reader learns one name for each operation, and `session = app.child()` shows the tree. Every caller migrates at once; the packages are unpublished, so the cost stays in this workspace. The scope override is removed by a separate lifecycle decision.
- References: [Public API Namespaces](spec.md#public-api-namespaces), [lifecycle log](../runtime/lifecycle/log.md).

## [2026-11-08] decision | Name constructor and configuration arguments

- Context: Constructors mixed positional and named arguments: `Component(source, name:)`, `Module(components, ordered:)`, `DiScope([module])`, `DiKey<T>([name])`, and `replacing(key, component)`. Flutter widgets name every configuration argument, so the API read differently from the widget tree that it mirrors.
- Decision: Every constructor and configuration argument is named: `source`, `value`, `components`, `modules`, `module`, `name`, `key`, and `component`. A combinator that takes one function keeps it positional, as `Iterable.map` and `Future.then` do; so do `FpDiScope.of(context)` and `addListener(listener)`. `DiKey.toString` keeps the form `DiKey<T>(name)`.
- Consequences: A declaration reads like a widget tree, for example `DiScope(module: Module(components: [...]))`. Call sites are longer, and every caller migrates at once. The shape algebra keeps the short notation `Component(r)` for `Component(source: r)`.
- References: [Chaining and arguments](spec.md#chaining-and-arguments).

## [2026-11-08] decision | Name resource callbacks create and dispose

- Context: `Resource(acquire:, release:)` used the vocabulary of functional resource libraries. Flutter DI libraries name the same pair `create` and `dispose` (`Provider(create:, dispose:)`, get_it `dispose:`). `initialize` was considered and rejected: in Dart it initializes an object that exists, and `DiScope.initialize` already names the creation of a scope's declaration.
- Decision: The callbacks are `Resource(create:, dispose:)`. The rest of the public vocabulary follows: `Resource.create()` returns a `Lease(value:, dispose:)`, `Dependency.acquireWith` and `acquireWithN` are `createWith` and `createWithN`, and `Lazy.isAcquired` is `isCreated`. The spec and ontology keep acquisition, lease, release, rollback, and cleanup as runtime concepts; a `dispose` callback is the inverse that a release runs.
- Consequences: The public API reads like Flutter DI code. "dispose" now names both the value callback, which runs at every deactivation, and the permanent disposal of a node or scope, so the spec states which one it means. `ReleasedLazy` keeps its name because it names the released state of the owner.
- References: [Public API Namespaces](spec.md#public-api-namespaces).

## [2026-11-08] decision | Split Dependency steps by whether the value has a dispose

- Context: A value with a `dispose` read `Dependency.require<Config>().createWith((c) => Resource(create: ..., dispose: ...))`, with three verbs and a nested resource. Always returning a `Resource` from one step was considered. It would make the most common step, a constructor with no `dispose` such as `mapN(Repository.new)`, three times longer and would lose constructor tear-offs.
- Decision: `Dependency` keeps `map` and `mapN` for a value that needs no `dispose`, as `Resource.map` does. `createWith` and `createWithN` are renamed `resource` and `resourceN`, which create the value from a `Resource` built from the read value, as `Resource.flatMap` does. `lazyWith` is removed; a lazy value returns `resource.lazy()` from `resource`. A `resourceN` step stays, because a Dart parameter cannot destructure a record.
- Consequences: The rule for a reader is one question: does the value need a `dispose` or lazy creation? `map` stays a plain step without a lease, so it costs nothing. `Lazy` has one entry point, `Resource.lazy()`.
- References: [Public API Namespaces](spec.md#public-api-namespaces), [lifecycle shape algebra](../runtime/lifecycle/spec.md#shape-algebra).

## [2026-11-08] decision | Name the producer key method bind

- Context: `Component.published(key:)` was a past participle in a builder chain, which reads unlike other Dart methods. `publish(key:)`, `key(...)`, and `bind(key:)` were considered. `key` collides with the Flutter widget `key`. `bind` is also the functional name of `flatMap`, and `Resource.flatMap` exists, but the required `key:` argument makes the call read as a DI binding.
- Decision: The method is `bind(key:)`. It adds the key to `publishes`. The rest of the vocabulary stays: the shape getter `publishes`, the terms publisher and publication, `DuplicatePublisher`, and the `DiChangeKind` names. "Bind" names the act, and "publishes" names the resulting shape and the runtime record, which the ontology calls a binding record.
- Consequences: A declaration reads `Component(source: ...).bind(key: DiKey<Db>())`. A reader meets both words, so the README and spec use "bind" for the call and "publish" for the effect in a scope.
- References: [Chaining and arguments](spec.md#chaining-and-arguments).

## [2026-11-08] decision | Take the producer key in the Component constructor

- Supersedes: [Chain only for algebra and type constraints](#2026-11-08-decision--chain-only-for-algebra-and-type-constraints), [Name the producer key method bind](#2026-11-08-decision--name-the-producer-key-method-bind)
- Context: The type of a component was decided by its source and checked last by `bind(key: DiKey<T>())`. Flutter DI states the provided type first, as `Provider<T>`, and a reader expected `Component<T>` to carry `T` with its key. The chained `bind` had kept a static check: a key of an unrelated type did not compile, while a constructor argument lets inference widen the type argument to a common supertype. Moving the key into the constructor also exposed a second effect of chaining: a generic list element type, `Component<Object?>` in `Module(components:)`, became the inference context of each component and fixed its type argument to `Object?`, which made the parameters of closures inside it `Object?`.
- Decision: `Component<A>({required Source<A> source, DiKey<A>? key, String? name})` and `Component.value({required A value, DiKey<A>? key, String? name})` take the key. `bind` is removed. The constructor throws an `ArgumentError` when the key type is not exactly `A`. The sealed, non-generic `AnyComponent` is the element type of `Module(components:)` and of the module edits, so Dart infers each component's type from its own arguments, as Provider does with `SingleChildWidget` for `MultiProvider`. Methods chain only for algebraic steps.
- Consequences: A declaration states what it provides and its key in one place. A key of an unrelated type fails where the component is built rather than at compile time. A list that a caller types as `Component<Object?>` shows the same failure, so a caller types such a list as `AnyComponent`. A key without a type argument, such as `DiKey(name: 'x')`, no longer infers its type from a receiver, so it needs one.
- References: [Chaining and arguments](spec.md#chaining-and-arguments), [component.dart](../../packages/fp_di/lib/src/model/component.dart), [module.dart](../../packages/fp_di/lib/src/model/module.dart).

## [2026-11-08] decision | Keep values functional and declarations Flutter-like

- Context: After the provided type and the key moved to the front of `Component<T>`, the same form was considered for `Dependency`: `Dependency<T>` with its reads. Dart has no generic constructors, so a call cannot state the output type and the input types together; the only form is a class for each arity, as Provider's `ProxyProvider2<A, B, R>` to `ProxyProvider6`.
- Decision: The API has three layers. The value layer, `Resource` and `Dependency`, stays functional: immutable values and chained combinators that take one function. A `Dependency` describes relations in the dependency graph, so a chain from the reads to the value fits it, and the type flows from the inputs to the output. The declaration layer, `Component<T>`, `Module`, and `DiScope`, follows Flutter: the provided type first and named arguments. The instance layer, `ComponentNode` and the node tree, is created by the runtime. The `source:` argument is the boundary between values and declarations.
- Consequences: The output type is written once, on `Component<T>`, and flows into the `source` as the inference context. A future API change picks its style from the layer that it belongs to. No arity classes are added.
- References: [Chaining and arguments](spec.md#chaining-and-arguments).

## [2026-11-08] decision | Add Dependency1 to Dependency8 for the common case

- Supersedes: [Keep values functional and declarations Flutter-like](#2026-11-08-decision--keep-values-functional-and-declarations-flutter-like) in its rule that the value layer has no arity classes.
- Context: The common dependent component reads a few keys and creates one value, sometimes with a `dispose`. As a chain it reads `Dependency.require2<A, B>().resourceN((a, b) => Resource(create: ..., dispose: ...))`. Provider writes the same case as `ProxyProvider2<A, B, R>(update: ..., dispose: ...)`, one class for each arity, because Dart has no generic constructors.
- Decision: `Dependency1<A, R>` to `Dependency8<A, ..., H, R>` take optional keys `k1` to `k8`, a required `create` that receives the values in key order, and an optional `dispose`. Each extends `Dependency<R>`: without `dispose` it is the matching `requireN().mapN(create)`, and with it the matching `requireN().resourceN` of a `Resource(create:, dispose:)`. The chain stays for several steps, optional reads, and lazy values. The arity stops at 8, as `requireN` does.
- Consequences: The common case is one call with no nested `Resource`, and a constructor tear-off such as `Dependency2(create: Repository.new)` gives all type arguments. The value layer stays immutable and keeps one shape algebra, because a `DependencyN` is a `Dependency`. There are two ways to write a single-step dependency; the README presents the class first and the chain for the cases that the class does not cover.
- References: [Chaining and arguments](spec.md#chaining-and-arguments), [dependency.dart](../../packages/fp_di/lib/src/model/dependency.dart).

## [2026-11-08] decision | Label components with debugLabel and default to the key

- Context: `Component(name:)` was a diagnostic label, but its name suggested an identity next to `DiKey(name:)`, which is part of a key. Most components repeated their key as the label, for example `name: 'database'` with `DiKey<Database>()`.
- Decision: The argument is `debugLabel`, as in Flutter's `FocusNode` and `AnimationController`. Without it, the label is the published key, or the type and node number for a component without a key. `AnyComponent.label` returns the effective label. `DiKey(name:)` keeps its name; get_it calls the same qualifier `instanceName`.
- Consequences: Examples drop labels that repeat their key. `describe` and errors such as `UnresolvableDependency` show the key, for example `DiKey<Database>: active`. `Module(name:)` keeps its name.
- References: [Chaining and arguments](spec.md#chaining-and-arguments), [component.dart](../../packages/fp_di/lib/src/model/component.dart).

## [2026-11-08] decision | Name the key qualifier instanceName

- Context: `DiKey(name:)` qualified a key, and `Component(debugLabel:)` had just replaced a `name` that was only a label. get_it calls the same qualifier `instanceName`.
- Decision: The qualifier is `DiKey<T>(instanceName: ...)`, and the `DependencyKey` getter is `instanceName`. `DiKey.toString` keeps the form `DiKey<T>(timeout)`.
- Consequences: A get_it registration with `instanceName: 'timeout'` maps to a key with the same argument. `Module(name:)` is the only remaining `name`, a module label.
- References: [key.dart](../../packages/fp_di/lib/src/model/key.dart).

## [2026-11-08] decision | Name the Component argument dependency

- Context: After `Resource` left the public API, the `source:` argument of `Component` accepted only a `Dependency`, so the generic word no longer named a choice.
- Decision: The argument is `Component(dependency: ...)`. The boundary between the value layer and the declaration layer is the `dependency:` argument.
- Consequences: A declaration reads `Component<Db>(key: DiKey<Db>(), dependency: Dependency1(create: Db.new))`. The shape algebra keeps the short notation `Component(d)`.
- References: [Chaining and arguments](spec.md#chaining-and-arguments).

## [2026-11-08] decision | Split failures into DiError and DiException

- Context: `DiError` was named an error but implemented `Exception`, its subtypes had no suffix, and the runtime also threw `ArgumentError` and `StateError`. Dart separates an `Error`, a programming mistake that callers do not catch, from an `Exception`, a condition that callers handle.
- Decision: Wiring mistakes extend the sealed `DiError extends Error` and end in `Error`: duplicate publisher, dependency cycle, unreachable key, unresolvable dependency, reentrant mutation, disposed scope, and invalid lifecycle operation. Failures at run time implement the sealed `DiException implements Exception` and end in `Exception`: activation, cleanup, listener, missing dependency, inactive component, and released lazy. `ArgumentError` and `StateError` stay for invalid arguments and calls in the wrong state. `DiScope.errors` is a `Stream<DiException>`; a wiring error during an automatic activation arrives as the `cause` of an `ActivationException`.
- Consequences: A caller catches `DiException` and lets `DiError` reach its error reporting. Every failure type is renamed. A `DiError` has no `const` constructor, because `Error` has none.
- References: [error.dart](../../packages/fp_di/lib/src/model/error.dart), [exception.dart](../../packages/fp_di/lib/src/model/exception.dart), [lifecycle notes](../../packages/fp_di/doc/lifecycle.md#failures-and-atomicity).

## [2026-11-08] decision | Align the public vocabulary with create, dispose, and initialize

- Context: After values became `Dependency` with `create` and `dispose`, and scopes gained `initialize` and `dispose`, public names still used publisher, cleanup, release, mutation, and the shape words `inject`, `watch`, and `observes`, which differ from `Dependency.require` and `Dependency.maybe`. A component publishes at most one key, but its shape exposed a set. The Flutter names used an `FpDi` prefix, and `DiScopeProvider.of` named a key `dependency`.
- Decision: A value is created and disposed, a scope is initialized and disposed, and a node is active or inactive, as a Flutter `Element` is, because a node can activate again and only `dispose` is final. Key errors name the key condition: `DuplicateKeyError`, `UndeclaredKeyError`, `UnavailableKeyException`, and `UnreachableKeyError`. Dispose failures are `DisposeException` and `DisposeIssue`; `DisposedLazyException` and `ReentrantLifecycleError` follow. `DiChangeKind` has `keyAvailable`, `keyUnavailable`, and `exception`. The shape is `requires`, `optional`, `reads`, and a single `key`. `Module(debugLabel:)` matches `Component`. The Flutter widget is `DiScopeProvider`, the extension is `DiBuildContext`, and `of` takes `key:`. The noun publisher stays in prose for the member that publishes a key, because the verb `publishes` stays in `Module.publishes`.
- Consequences: Every renamed type, value, and getter breaks callers. Internal names such as `_Publisher`, `acquire`, and `Lease` are unchanged.
- References: [error.dart](../../packages/fp_di/lib/src/model/error.dart), [exception.dart](../../packages/fp_di/lib/src/model/exception.dart), [component.dart](../../packages/fp_di/lib/src/model/component.dart), the changelog of `fp_di`, removed on 2026-11-14.

## [2026-11-09] decision | Ship an fpdart host example as a workspace package

- Context: The fpdart contract asked for a separately pinned host fixture before V-T-AR-DI-002 could close (G-AR-DI-001), and an advanced example with `Reader`, `State`, and `ReaderTaskEither` was requested. The core MUST NOT depend on fpdart.
- Decision: `examples/fpdart` is a workspace package (`fp_di_fpdart_example`, `publish_to: none`) that pins `fpdart: 1.2.0`. Its library builds a checkout: a `Reader` constructs the payment gateway from the configuration, a `State` program runs against an owned cart store, a `ReaderTaskEither` workflow runs over an environment that a `Dependency` reads, an optional read becomes an `Option`, and `TaskEither` makes the host's `initialize` lazy and total. Its tests are the V-T-AR-DI-002 fixture.
- Consequences: G-AR-DI-001 is closed, and the architecture topic has no open gap, so its `gap.md` is removed. fpdart appears in the workspace lock file, but no production package depends on it. The example is not an adapter: the helpers stay in the example.
- References: [spec](spec.md#fpdart-interoperability), `packages/fp_di/example_fpdart/lib/checkout.dart`, `packages/fp_di/example_fpdart/test/interop_test.dart` (removed).

## [2026-11-09] decision | Make the fpdart example a standalone package under fp_di

- Context: The fpdart example was a workspace member, so fpdart entered the workspace lock file and shared the resolution of the production packages.
- Decision: The example moves to `packages/fp_di/example_fpdart` as a standalone package (`fp_di_example_fpdart`): it is not a workspace member, depends on `fp_di` by path, and pins `fpdart: 1.2.0` in its own `pubspec.lock`. This supersedes the location in [Ship an fpdart host example as a workspace package](#2026-11-09-decision--ship-an-fpdart-host-example-as-a-workspace-package).
- Consequences: The workspace lock file has no fpdart. The example sits next to the package it demonstrates, like the `example` of a Flutter package. It is checked with `dart pub get`, `dart analyze`, and `dart test` in its own directory.
- References: [spec](spec.md#fpdart-interoperability), `packages/fp_di/example_fpdart/pubspec.yaml` (removed).

## [2026-11-09] decision | Ship fp_di_fpdart as the fpdart integration

- Context: The standalone example had to repeat glue at every boundary: `TaskEither` around `initialize` and `dispose`, a bracket, and a `Left`-to-exception step. A host that writes its programs with fpdart wanted the fp_di operations in the same vocabulary.
- Decision: The workspace package `packages/fp_di_fpdart` (`fpdart: ^1.2.0`) provides `initializeTask`, `disposeTask`, `use`, `getEither`, `getOption`, `whenActiveTask`, `mapTaskEither`, `mapTaskEitherAsData`, `mapTask`, `toOption`, and `canceledTask`, with `DiFailure` and `ScopeError`. The example moves into the package. This supersedes "No interoperability adapter is shipped" and the location in [Make the fpdart example a standalone package under fp_di](#2026-11-09-decision--make-the-fpdart-example-a-standalone-package-under-fp_di).
- Consequences: fpdart enters the workspace lock file; the core and `fp_di_flutter` still do not depend on it. The package adds no lifecycle behavior and no `flatMap`, so the runtime still knows the reads of every `Dependency` before it runs. The `Left` policy is a choice of the host that the step name states. V-T-AR-DI-002 now verifies the package.
- References: [spec](spec.md#fpdart-interoperability), [fp_di_fpdart.dart](../../packages/fp_di_fpdart/lib/fp_di_fpdart.dart), `packages/fp_di_fpdart/test/fp_di_fpdart_test.dart` (removed).

## [2026-11-10] decision | Name the keys of a DependencyN key1 to key8

- Context: `Dependency1` to `Dependency8` and `Dependency.require2` to `require8` named their optional keys `k1` to `k8`. Every other API that takes a key names the argument `key`: `Component`, `Dependency.require`, `DiScope.get`, and `DiScope.member`. Effective Dart asks to avoid abbreviations that are not widely known.
- Decision: The optional keys are `key1` to `key8`. The number is the position of the value in `create`. No alias for `k1` to `k8` remains, as for the earlier renames.
- Consequences: One word names a key in every API, at the cost of three characters per argument. Code that passes `k1` to `k8` does not compile and needs a mechanical rename; a call that passes the default key can drop the argument instead. The shape algebra keeps `k1, …, kn` as math notation.
- Supersedes: [Add Dependency1 to Dependency8 for the common case](#2026-11-08-decision--add-dependency1-to-dependency8-for-the-common-case), only the names of its keys.
- References: [spec](spec.md), [dependency.dart](../../packages/fp_di/lib/src/model/dependency.dart).

## [2026-11-10] decision | Name the first API layer after Dependency and add a diagnostics layer

- Context: The spec named three API layers: value, declaration, and instance. The word value also names what a `create` function returns, so the value layer had a second meaning. The types and members that only read the runtime, such as `DiChange`, `SlowMutation`, `ShapeGraph`, and `describe`, belonged to no layer. `DiScope` was listed as a declaration, but an initialized scope also owns nodes.
- Decision: The first layer is the dependency layer, named after its types. A fourth layer, diagnostics, holds the read-only values and listeners; a read starts no mutation. The spec states that a `DiScope` belongs to the declaration layer and, after `initialize`, owns the nodes of the instance layer. The name description was not used, because the ontology calls both a `Component` and a `Dependency` a description.
- Consequences: The styles of the layers do not change. Earlier entries say value layer for the dependency layer.
- Supersedes: [Keep values functional and declarations Flutter-like](#2026-11-08-decision--keep-values-functional-and-declarations-flutter-like), only the name of the first layer and the number of layers.
- References: [Chaining and arguments](spec.md#chaining-and-arguments), [lifecycle observation](../runtime/lifecycle/spec.md#observation).

## [2026-11-11] decision | Name the fourth API layer observation

- Context: The fourth API layer was the diagnostics layer. The lifecycle spec, its requirement R-UC-RT-LC-016, and the README say observation for the same members. A listener is not only a diagnostic: the Flutter adapter rebuilds widgets from `DiChange` events.
- Decision: The fourth layer is the observation layer. Its types and members do not change. `ShapeGraph` stays in the layer: it reads declarations, and the other members read the runtime. The first layer keeps the name dependency.
- Consequences: One word names the read-only surface in the architecture spec, the lifecycle spec, and the ontology. The word diagnostic stays an ordinary word for text that people read, such as the text of `describe`.
- Supersedes: [Name the first API layer after Dependency and add a diagnostics layer](#2026-11-10-decision--name-the-first-api-layer-after-dependency-and-add-a-diagnostics-layer), only the name of the fourth layer.
- References: [Chaining and arguments](spec.md#chaining-and-arguments), [lifecycle observation](../runtime/lifecycle/spec.md#observation), [ontology log](../../ontology/log.md).

## [2026-11-11] decision | Name the fpdart failure values failure

- Context: The core package reserves the word error for `DiError`, a wiring mistake that a caller does not catch. The fpdart package named the `Left` of `DiScope.use` `ScopeError<E>`, next to `DiFailure`. `DiFailure.rollbackIssues` also returned the issues of a `DisposeException`, which do not come from a rollback.
- Decision: `ScopeError<E>` becomes `ScopeFailure<E>`. Its subtypes `InitializeFailed`, `UseFailed`, and `DisposeFailed` keep their names. `DiFailure.rollbackIssues` becomes `issues`. `rollbackIssues` of `ActivationException` and `ActivationCanceledException` does not change.
- Consequences: The change breaks callers of the fpdart package. No release has the package, so its changelog states the new names in the entry of the first version.
- References: [fpdart interoperability](spec.md#fpdart-interoperability), [failure.dart](../../packages/fp_di_fpdart/lib/src/failure.dart).

## [2026-11-11] decision | Name the key qualifier name again

- Context: The decision of 2026-11-08 named the qualifier of a `DiKey` `instanceName`, after get_it. Collection keys came later: `DiSetKey(name)` and `DiMapKey(name)` have a `name`, and `DependencyKey.instanceName` returned that name. `DiKey.needsName`, the error messages, and the lifecycle spec say name. One qualifier had two words.
- Decision: The qualifier is `DiKey<T>(name: ...)`, and the `DependencyKey` getter is `name`. `DiMapKey.entry(id)` keeps the word id for the argument, and the `name` of an entry key is that id. The dartdoc states that get_it calls the same qualifier `instanceName`.
- Consequences: Every key has a `name`. A get_it registration with `instanceName: 'timeout'` maps to a key with `name: 'timeout'`, so a migrated call site changes the argument name. The change breaks every caller that wrote `instanceName`. The getter and the argument have the names of release 0.2.0 again, so the changelog adds no entry and states `name` in the entry of the named arguments.
- Supersedes: [Name the key qualifier instanceName](#2026-11-08-decision--name-the-key-qualifier-instancename).
- References: [key.dart](../../packages/fp_di/lib/src/model/key.dart), [key names](../runtime/lifecycle/spec.md#key-names), [ontology log](../../ontology/log.md).

## [2026-11-11] decision | State the rule of the Di prefix

- Context: Some public types have the prefix `Di`, and others have none. No document stated the rule. The lifecycle decision of 2026-11-06 renamed `Key` to `DiKey`, because `package:flutter/widgets.dart` exports its own `Key`, and kept the name `DependencyKey` for the supertype.
- Decision: The spec states the rule that the present names follow. A general word that stands alone takes the prefix, and a name that adds a word to a `Di` name keeps it. A name that starts with a word of the library has no prefix. A concrete error, exception, or failure names its condition. No type changes its name.
- Consequences: A new public type has one row to follow. `DependencyKey` has no prefix, while each of its subtypes has one, so Q-AR-DI-001 keeps the names of the key types open.
- References: [Type names](spec.md#type-names), [Rename the key type to DiKey](../runtime/lifecycle/log.md#2026-11-06-decision--rename-the-key-type-to-dikey).

## [2026-11-11] decision | Name the supertypes without a type argument Base

- Context: `DependencyKey` was the only key type without `DiKey` in its name, and Q-AR-DI-001 kept the names of the key types open. `AnyComponent` had the same role for `Component<A>` with another form of name. The prefix `Any` is a Swift idiom, and no package in the local pub cache uses it for a supertype. The suffix `able` was considered and rejected: in Dart it names a capability that a caller implements, such as `Listenable`, and the library alone implements these two types.
- Decision: `DependencyKey` becomes `DiKeyBase`, and `AnyComponent` becomes `ComponentBase`, as go_router names `RouteBase` and bloc names `BlocBase`. A supertype without a type argument adds the suffix `Base` to the name of its main type. A supertype whose name no other type has keeps the plain name, such as `DiError` and `DiCollectionKey`. Resolves Q-AR-DI-001.
- Consequences: Every key type has `DiKey` in its name, and the rule of the `Di` prefix has no exception. The change breaks every caller that names one of the two types. Release 0.2.0 has `DependencyKey`, so the changelog states that rename as breaking; `AnyComponent` is not in a release. Earlier log entries keep the old names. `DiKeyBase` stays an interface that is not sealed.
- Supersedes: [State the rule of the Di prefix](#2026-11-11-decision--state-the-rule-of-the-di-prefix), only the open names of the key types.
- References: [Type names](spec.md#type-names), [key.dart](../../packages/fp_di/lib/src/model/key.dart), [component.dart](../../packages/fp_di/lib/src/model/component.dart), [go_router `RouteBase`](https://pub.dev/documentation/go_router/latest/go_router/RouteBase-class.html), [bloc `BlocBase`](https://pub.dev/documentation/bloc/latest/bloc/BlocBase-class.html).

## [2026-11-11] decision | Name the arguments of the collection keys

- Context: The decision of 2026-11-08 named every constructor and configuration argument. Collection keys came later with positional arguments: `DiSetKey<T>(name)`, `DiMapKey<T>(name)`, `Component.into(key, dependency:)`, and `Dependency.requireSet(key)`, `maybeSet(key)`, `requireMap(key)`, and `maybeMap(key)`. The spec required named arguments and stated no exception for them. The spec also said producer key once for the published key.
- Decision: The arguments are named: `DiSetKey<T>(name:)`, `DiMapKey<T>(name:)`, `Component.into(key:, dependency:)`, and `key:` for the four collection reads. `DiMapKey.entry(id)` keeps its positional id, because the call selects one entry of a map, as `map[id]` does. The spec says published key.
- Consequences: A key and a read of a collection have the form of `DiKey<T>(name:)` and `Dependency.require(key:)`. The change breaks every caller of these members. No release has collection keys, so the changelog states the named forms in the entry that adds them. The shape algebra of the lifecycle spec keeps its short notation, such as `requireSet(K)`.
- References: [Chaining and arguments](spec.md#chaining-and-arguments), [Name constructor and configuration arguments](#2026-11-08-decision--name-constructor-and-configuration-arguments), [key.dart](../../packages/fp_di/lib/src/model/key.dart).

## [2026-11-11] decision | Read the published scope from a listenable

- Context: `DiScopeProvider` published one `DiScope` that its parent supplied. A parent that rebuilds the provider replaces the scope only at the next frame, and a scope answers no read from the moment its disposal starts, not even for a key of its parent. A host whose session scope is not a widget subtree, because every route is below one `Navigator`, replaces the scope of the root provider at login and logout. A widget that read between the disposal and the rebuild got a `DisposedScopeError`. The provider also rebuilt every watching widget when any scope of the root was disposed, and a rebuild into the disposed scope threw.
- Decision: The constructor `DiScopeProvider.listenable(scope:)` takes a `ValueListenable<DiScope>`, and a lookup reads its value at the moment of the call. The host changes the value before it disposes the old scope. The constructor for one scope is `DiScopeProvider.fixed(scope:)`, for a scope that lives longer than the widget. The disposal of a scope rebuilds no watching widget. Two alternatives were rejected. A disposed child scope that reads its parent needs a change of the core contract and lets a read after disposal succeed for some keys. A provider that replaces the scope when it receives the disposal is too late, because reads fail from the start of the disposal and the notification comes at its end.
- Consequences: The widget has no unnamed constructor, so each caller names the form, and the name `fixed` states the limit of that form. The change breaks every caller of the former constructor. A host needs an object that holds the current scope, such as a `ValueNotifier<DiScope>`; the adapter adds no holder type. The order of the two steps stays a duty of the host. A subtree below a `ComponentScope` still reads the owned child scope until the next frame. The change does not make a key of the old scope available, so a host removes the widgets that read a session key in the frame of the replacement at the latest.
- References: [Flutter Integration](spec.md#flutter-integration), [di_scope_provider.dart](../../packages/fp_di_flutter/lib/src/scope_provider.dart), [scope_listenable_test.dart](../../packages/fp_di_flutter/test/scope_listenable_test.dart), [scope_disposal_test.dart](../../packages/fp_di_flutter/test/scope_disposal_test.dart).

## [2026-11-11] decision | Publish scopes only and remove ComponentScope

- Context: `ComponentScope` created a child scope with one component, initialized it, and disposed it, and its name did not follow `DiScopeProvider`. A constructor `DiScopeProvider(create:)` was considered, as Provider and flutter_bloc pair `create:` with `.value`. A widget for one component also asks for a widget for a module. The code that calls `initialize` gets its failure and decides what the user sees while the call runs. A widget that calls `initialize` therefore needs a loading widget and an error widget among its arguments.
- Decision: The adapter only publishes a caller-owned scope. `DiScopeProvider` has the constructors `listenable` and `fixed`, and no constructor that creates a scope. `ComponentScope` is removed. A host that needs a scope for one widget subtree creates a child scope, calls `initialize` and `dispose` in its own code, and publishes the child scope with `DiScopeProvider`.
- Consequences: The adapter owns no scope and has no argument for a user interface. A host that owns a scope outside the widget tree needs the provider alone. A host that binds a scope to a widget loses what `ComponentScope` did: it disposed a scope whose initialization ended after the unmount, reported the release failures of an abandoned initialization, started again when the ambient scope was replaced, and rendered `loading` while its node was inactive. R-US-AR-UI-002, R-UC-AR-UI-002, V-T-AR-UI-002, V-T-AR-UI-003, and V-T-AR-UI-005 are removed, and their IDs are not used again. A later widget that owns a scope needs its own decision.
- Supersedes: [ComponentScope renders child only while the component is active](#2026-11-03-decision--componentscope-renders-child-only-while-the-component-is-active).
- References: [Flutter Integration](spec.md#flutter-integration), [di_scope_provider.dart](../../packages/fp_di_flutter/lib/src/scope_provider.dart).

## [2026-11-11] decision | Show loading and error states from the state of a node

- Context: The adapter has no widget with a loading state or an error state. A widget read only whether a key had a value. The failure of an automatic activation goes to `DiScope.errors` once and to no caller, and it is a change without a key, so no watcher rebuilt for it. The core gives the state of a node with `DiScope.maybeNode`.
- Decision: `maybeDiNode` and `watchMaybeDiNode` read the node that publishes a key. The watching read rebuilds when the state, the failure, or the missing keys of that node change. The provider compares what each watched node looked like at each change of the scope; the core has no new notification. The widget that reads the node decides what the user sees.
- Consequences: A widget shows loading, error, and data with one read and no stream. The comparison runs for each watched key at each change of the root. The runtime announces no start of an activation, so a watcher does not see `activating` at that moment. The failure of `initialize` stays with the caller of `initialize`, and a `FutureBuilder` shows it.
- References: [Flutter Integration](spec.md#flutter-integration), [di_extensions.dart](../../packages/fp_di_flutter/lib/src/di_extensions.dart), [node_state.dart](../../packages/fp_di_flutter/example/node_state.dart), [page_scope.dart](../../packages/fp_di_flutter/example/page_scope.dart).

## [2026-11-11] decision | Split the core sources into model and runtime folders

- Context: `packages/fp_di/lib/src/` held nineteen files in one folder. Eight of them belonged to the scope library or served only the runtime, and eleven declared the types that a host writes. A reader could not see that boundary from the file list.
- Decision: The folder `src/model/` holds the declarations and values. The folder `src/runtime/` holds the scope library, its part files, `runtime_teardown.dart`, and `runtime_faults.dart`. A file of `model/` MUST NOT import a file of `runtime/`. `scope.dart` is in `runtime/`, because it is the library of the part files. The files of `model/` stay grouped by concept, so an enum stays in the file of its type.
- Consequences: No behavior and no public API changes. `package:fp_di/fp_di.dart` and `package:fp_di/tooling.dart` export the same names. An import of `package:fp_di/src/` has a new path; only three core tests have one. The specs, the ontology, and the scenario manifests name the new paths. Earlier log entries keep their text, and their links follow the files.
- Alternatives: A folder for each kind of declaration, such as one for enums, separates an enum from the type that uses it. A folder name other than `model` avoids the word that the specs use for a formal model, but the user chose the name, and a path is not prose.
- References: [source folders of the core](spec.md#source-folders-of-the-core), [fp_di.dart](../../packages/fp_di/lib/fp_di.dart).

## [2026-11-11] decision | Name three errors after their condition

- Context: The public API named one concept with three words. `SlowMutation` said mutation, `ReentrantLifecycleError` said lifecycle, and `InvalidLifecycleOperationError` said lifecycle operation. The last name did not state its condition: the runtime throws it when a step runs after its activation ended. `ListenerException` stated the thrower with a general word, and the type of the thrower is `DiListener`. A prefix `Di` in every error name was considered.
- Decision: `ReentrantLifecycleError` is `ReentrantMutationError`. `InvalidLifecycleOperationError` is `OutsideActivationError`. `ListenerException` is `DiListenerException`, by the rule that a name that adds a word to a `Di` name keeps the prefix. The other errors and exceptions keep their names.
- Consequences: Breaking changes without a behavior change. The messages and the fields stay. The word mutation is the public word for one queued lifecycle call. `OutsideActivationError` also covers a `contribute` of a node that has no set key, a case that the public API cannot reach.
- Alternatives: A name such as `DuplicateKeyDiError` puts the prefix in every error. The sealed supertypes `DiError` and `DiException` already group the types, and a name that states a condition collides with no other library.
- References: [type names](spec.md#type-names), [error.dart](../../packages/fp_di/lib/src/model/error.dart), [exception.dart](../../packages/fp_di/lib/src/model/exception.dart).

## [2026-11-11] decision | Give the scope the plain name Scope

- Context: A host composes three units: a module, a component, and a scope. `Module` and `Component` had plain names, and the scope was `DiScope`. The prefix `Di` exists because Flutter exports `Key`. No type of Flutter 3.47.8 or of the Dart SDK has the name `Scope`, `Module`, or `Component`. The library already said `DisposedScopeError`, `ScopeFailure`, and `scopeDisposed` without the prefix.
- Decision: `DiScope` is `Scope`. The Flutter widget `DiScopeProvider` is `ScopeProvider`, in `scope_provider.dart`. The fpdart extension `DiScopeFpdart` is `ScopeFpdart`. `DiBuildContext` keeps its name, because it adds DI reads to a `BuildContext`. `DiKey`, `DiChange`, `DiListener`, `DiError`, `DiException`, and `DiFailure` keep the prefix.
- Consequences: Breaking changes without a behavior change. The operation name `DiScope.dispose` in `SlowMutation` and `ReentrantMutationError` is `Scope.dispose`. sentry and injectable export a `Scope`, and injectable exports a `Module`, so a file that imports one of them with this library hides one name or uses an import prefix. Flutter has widgets whose names end in `Scope`, such as `FocusScope`; `ScopeProvider` does not state what scope it publishes.
- Alternatives: `DiScope` stays, and the scope is the one unit with a prefix. `DiScopeProvider` stays for the widget only; the widget then has a prefix that its scope does not have.
- References: [type names](spec.md#type-names), [scope.dart](../../packages/fp_di/lib/src/runtime/scope.dart), [scope_provider.dart](../../packages/fp_di_flutter/lib/src/scope_provider.dart), [lifecycle log](../runtime/lifecycle/log.md).

## [2026-11-12] decision | Return null from a lookup with no provider

- Context: `ScopeProvider.of` throws a `FlutterError` when no provider is above. A host that also keeps its scope outside the widget tree wants a widget to read that scope when no provider publishes one, for example in a widget test. The inherited widgets of the provider are private, so a host cannot write that lookup.
- Decision: `ScopeProvider.maybeOf` takes the arguments of `of` and returns null when no provider is above. A listening call that found no provider records an unsatisfied dependency, so the framework rebuilds the widget when the widget moves below a provider. The reads of the `BuildContext` extension keep the `FlutterError`.
- Consequences: A host writes `ScopeProvider.maybeOf(context) ?? fallback`. `of` and `maybeOf` share one lookup. The adapter still holds no scope and has no fallback of its own.
- Alternatives: `maybeDi` and `maybeDiNode` that return null with no provider give one null two meanings: a key that is not available and a provider that is absent. The second one is an error of the widget tree in most hosts. A `hasDi` read is `maybeDiNode<T>() != null`, and a host chooses whether a node that waits counts. A read that throws the failure behind an inactive node needs only `Scope.maybeNode` and `NodeState.missing` of the core, so a host can write it without the adapter.
- References: [Flutter Integration](spec.md#flutter-integration), [scope_provider.dart](../../packages/fp_di_flutter/lib/src/scope_provider.dart), [scope_maybe_of_test.dart](../../packages/fp_di_flutter/test/scope_maybe_of_test.dart).

## [2026-11-13] decision | Move to a replaced scope after the frame when setState is not allowed

- Context: `ScopeProvider` called `setState` in the listener of its listenable. A host that changed the value from `State.dispose` got "setState() or markNeedsBuild() called when widget tree was locked", and a change from a build got "called during build". A widget that goes away is a natural place to change the scope, and the adapter did not state that the place is not allowed.
- Decision: `ScopeProvider` reads the scheduler phase. In the persistent callbacks of a frame, and in a build outside a frame that the debug flag of the build owner shows, the provider does not call `setState`. A callback after the frame moves the subscription and calls `setState`, and the provider asks for a frame when none runs. A change at another moment calls `setState` at once, as before.
- Consequences: The host changes the listenable from any callback. A lookup reads the new scope at once, because a lookup reads the value of the listenable. The listening widgets rebuild one frame later than after a change at an allowed moment. Until the callback runs, the provider still listens to the old scope, and the comparison does nothing for a scope whose `isDisposed` is true. The flag is read in an assertion. A release build has no assertion on `setState`, by the source of Flutter; no test runs a release build.
- Alternatives: A rule that forbids the change from `State.dispose` leaves the error to each host. A move after the frame at every moment delays each replacement by one frame. A `scheduleMicrotask` runs after the frame only in some phases.
- References: [Lifecycles of the adapter](spec.md#lifecycles-of-the-adapter), [requirements](requirements.md#r-uc-ar-ui-005), [scope_provider.dart](../../packages/fp_di_flutter/lib/src/scope_provider.dart), [scope_replacement_phase_test.dart](../../packages/fp_di_flutter/test/scope_replacement_phase_test.dart).

## [2026-11-13] decision | Schedule no frame for a transition while no key was watched

- Context: The runtime calls each listener at each transition of the root. `ScopeProvider` scheduled one frame callback for the comparison at each transition, also below a provider with no watching read. A consumer reads only with `di` and `maybeDi`, so each transition of its runtime asked for a frame that compared nothing.
- Decision: A transition schedules no comparison while no key was watched since the mount of the provider.
- Consequences: A host without watching reads gets no frame from the runtime. The first watching read keeps the `NodeState` of its key at that moment, so a transition before that read needs no comparison. The provider does not forget a watched key: after one watching read, each transition schedules a frame again, also when the watcher is unmounted.
- Alternatives: A count of the mounted watchers of each key needs a hook that an `InheritedModel` does not give. A listener that the provider adds at the first watching read saves the call and not the frame.
- References: [Lifecycles of the adapter](spec.md#lifecycles-of-the-adapter), [scope_provider.dart](../../packages/fp_di_flutter/lib/src/scope_provider.dart), [scope_replacement_phase_test.dart](../../packages/fp_di_flutter/test/scope_replacement_phase_test.dart).

## [2026-11-13] decision | Check the adapter with random histories of the framework

- Context: The frames of Flutter, the mount of widgets and of routes, the replacement of the published scope, and the transitions of the runtime meet in the adapter. The adapter tests had fixed fixtures and no route transition. No formal model covers the adapter. The adapter has no composition operator, so the shape algebra and its laws do not apply to it.
- Decision: The spec states the state of a mounted provider, its reaction to each event, and four safety properties. Random histories with fixed seeds check the properties with a real `WidgetTester`, a real `Navigator`, and the real runtime. Each check has a control: one defect of the harness that the check must report. The adapter gets no fault hook.
- Consequences: The histories run the semantics of the framework and do not assume them. They reported the replacement from `State.dispose` on the adapter before its correction. The evidence is bounded: 40 histories of 40 steps, one platform, and the steps that the harness knows. A control shows that a check can report; it does not show that the adapter has no other defect.
- Alternatives: A TLA+ model of the adapter must assume the frame phases, the notification of an `InheritedModel`, and the lock of the tree, and the known defect was in such an assumption. A model of the host rule alone stays possible. A fault hook in the adapter, as `RuntimeFaults` of the core, adds a production path for one test.
- References: [Lifecycles of the adapter](spec.md#lifecycles-of-the-adapter), [V-T-AR-UI-011](requirements.md#v-t-ar-ui-011), [adapter_history_test.dart](../../packages/fp_di_flutter/test/adapter_history_test.dart), [test specification](../verification/test/spec.md).

## [2026-11-13] decision | Give a route its scope through a State of the route

- Context: A route is a sibling of the other routes below a `Navigator`, so it is not below the widget that pushed it. A route stays mounted during its exit transition. With one provider at the root and a listenable, a replacement reaches an exiting route at once, and a strict watching read of a key of the old scope then throws `UnavailableKeyException`, in each order of the pop and of the change. The adapter owns no scope and has no router code.
- Decision: The spec states a host rule. A scope that a route owns belongs to a `State` of that route, which creates, initializes, publishes, and disposes the scope. A route reads a scope from a provider of its own or from a `Navigator` below the provider. A host with one listenable for all routes reads the keys of a replaced scope with the reads that return null, or removes the widgets in the frame of the change. The example `navigator_scope.dart` shows the first two rules.
- Consequences: Flutter calls `State.dispose` after the exit transition, so an exiting route reads its scope until it leaves, and the host needs no order between a pop and a disposal. A nested `Navigator` keeps each route of a session below the session scope. The package still has no widget that creates a scope: the example defines its host widget. No committed test runs a strict read of an exiting route after a replacement.
- Alternatives: A widget of the package that owns a scope takes the failure of `initialize` and the loading state from the host, which the decision of 2026-11-11 to publish scopes only rejected. A provider that keeps the old scope for an exiting route needs to know the routes, and the adapter has no router code. A disposal that waits for the routes to unmount moves the lifecycle of the routes into the holder of the scope.
- References: [Host rule for routes](spec.md#host-rule-for-routes), [navigator_scope.dart](../../packages/fp_di_flutter/example/navigator_scope.dart), [session_scope.dart](../../packages/fp_di_flutter/example/session_scope.dart).

## [2026-11-13] decision | State where a popup reads its scope

- Context: The host rule for routes did not name popups. `showDialog` pushes a route on the root `Navigator` by default, so a dialog of a route below a nested `Navigator` reads the scope above the root `Navigator`. A `ScaffoldMessenger` builds a snack bar in every root `Scaffold` below it, also in the `Scaffold` of a route below and of the next route.
- Decision: Rule 5 of the host rule for routes states the place of each popup. A popup that reads a scope is a route of a `Navigator` below that scope, or it republishes the scope with `ScopeProvider.fixed` and closes before the scope is disposed. The content of a snack bar or a banner reads no scope. `popup_scope.dart` shows each form, and its test reads the scope of each popup.
- Consequences: The adapter has no popup code. A dialog of the root `Navigator` that republishes a scope reads a disposed scope when the host removes the route of that scope while the dialog is open.
- Alternatives: `_InheritedScope` as an `InheritedTheme` lets `showDialog` and `showMenu` capture the scope like a theme. The captured scope is a fixed value, and the popup can live longer than the route that owns the scope, against rule 2. A popup helper of the package duplicates each `show` function of Flutter.
- References: [Host rule for routes](spec.md#host-rule-for-routes), [popup_scope.dart](../../packages/fp_di_flutter/example/popup_scope.dart), [example_test.dart](../../packages/fp_di_flutter/test/example_test.dart).

## [2026-11-14] decision | Group the API reference by layer and require a doc comment on each public member

- Context: `dart doc` built the three packages without errors, but `fp_di` listed about sixty public types in one flat list. The libraries `fp_di` and `fp_di_flutter` had no library comment, and 63 public members had no doc comment, among them `DiBuildContext`, `maybeDi`, and `watchMaybeDi`. No check reported a missing comment.
- Decision: Each public type of `fp_di` names a category in its doc comment, and `dartdoc_options.yaml` orders the categories by the layers of [Chaining and arguments](spec.md#chaining-and-arguments): Dependency, Declaration, Keys, Instance, Observation, Errors, and Exceptions. Each category has a page under `doc/topics/`, and the category Instance shows `doc/lifecycle.md`: `dart doc` builds no topic page for a category without a markdown file. Each library has a library comment. The analysis options enable `public_member_api_docs`.
- Consequences: The reference shows the four layers that the spec names, and `dart analyze` reports a public member without a doc comment. `dart analyze` reports the lint as an info, so the command does not fail without `--fatal-infos`. A new public type needs a category, and no check reports a missing one. The links of the README to `example/` and to other folders of the repository stay broken in the generated reference until the README is rewritten for publication, so `dart doc` is not a check of the workspace.
- Alternatives: One library for each layer splits the imports of an application. Categories in `dartdoc_options.yaml` alone, without a tag in each doc comment, do not place a type. The lint `comment_references` was not enabled: `dart doc` printed no warning for an unresolved reference in the three packages.
- References: [Chaining and arguments](spec.md#chaining-and-arguments), [dartdoc_options.yaml](../../packages/fp_di/dartdoc_options.yaml), [analysis_options.yaml](../../analysis_options.yaml).

## [2026-11-14] decision | Release the three packages as 0.1.0 without a changelog

- Context: The packages are not published. `fp_di` and `fp_di_flutter` had changelogs with the sections 0.1.0, 0.2.0, and Unreleased, and `fp_di_fpdart` had an Unreleased section, while each `pubspec.yaml` states the version 0.1.0. The Unreleased sections listed renames of names that no release had, and the decision logs already record each change and its reason.
- Decision: The three packages have the version 0.1.0 and no `CHANGELOG.md`. The first published release starts the changelog of each package.
- Consequences: A change before the first release is recorded in the decision log of its topic and in the commit, not in a changelog. The entries of the decision logs before this date that name a changelog describe files that no longer exist; Git history keeps them.
- Alternatives: A changelog with one 0.1.0 section that summarizes the current API duplicates the README, which is rewritten for publication. Keeping the Unreleased sections lists renames from names that no user saw.
- References: [Public API Namespaces](spec.md#public-api-namespaces).

## [2026-11-14] decision | Keep fp_di_fpdart experimental and unpublished

- Context: The workspace has three packages. The READMEs presented `fp_di_fpdart` next to the other two, and the README of `fp_di` had a section on it. The READMEs are rewritten for the first publication.
- Decision: `fp_di_fpdart` stays in the workspace as an experimental package with `publish_to: none`. Its README states that it is experimental and not published. The READMEs of `fp_di` and `fp_di_flutter` do not present it, and the root README lists it as experimental.
- Consequences: The published API is `fp_di` and `fp_di_flutter`. The tests of `fp_di_fpdart` still run, and the [fpdart interoperability](spec.md#fpdart-interoperability) design stays current for the workspace. A change of the core MAY break `fp_di_fpdart` without a deprecation.
- Alternatives: Publishing it ties the core to a second public API before the first release. Removing it from the workspace loses the tests of the boundary to fpdart.
- References: [fp_di_fpdart README](../../packages/fp_di_fpdart/README.md), [root README](../../README.md).

## [2026-11-14] decision | Present fp_di in a short README and move the details to the API reference

- Context: The README of `fp_di` had 1,261 lines: the full signatures, every edit of a module, observation, cancellation, the queue, and the failure rules. `dart doc` shows the README as the start page of the package and has a topic page for each category of the API reference.
- Decision: The README presents the idea in three parts: a `Dependency` is a value with a computed shape, a `Module` is a value that a program edits and inspects, and the lifecycle follows from the keys. Its section on the algebra restates the shape rules of the [lifecycle spec](../runtime/lifecycle/spec.md#shape-algebra) as equations, with the order relation of the lifecycle, and it states the guarantees and limits of the runtime. The detailed sections moved without change to the topic pages under `packages/fp_di/doc/topics/` and to `packages/fp_di/doc/lifecycle.md`.
- Consequences: The README has about 350 lines. A spec link to a detailed section points to its topic page. The topic pages name repository files as paths, because `dart doc` does not resolve a relative link to a file outside the reference. The README keeps relative links, and its installation section names a Git dependency with the repository URL left open until the repository is public.
- Alternatives: A README that keeps every section shows the reader all details before the idea. A separate documentation site adds a build that the workspace does not have.
- References: [packages/fp_di/README.md](../../packages/fp_di/README.md), [dartdoc_options.yaml](../../packages/fp_di/dartdoc_options.yaml).

## [2026-11-14] decision | Publish fp_di and fp_di_flutter 0.1.0 from a public repository under MIT

- Context: The two packages are ready for pub.dev. Publication needs a license, a repository, a changelog, and hosted dependencies.
- Decision: The repository `dfdgsdfg/fp_di` is public under the MIT license, and it starts from one commit of the current tree. `fp_di` and `fp_di_flutter` have the version 0.1.0, a `LICENSE`, a `CHANGELOG.md` with one initial entry, a `repository` field, and topics. `fp_di_flutter` depends on `fp_di: ^0.1.0`, so `fp_di` is published first. The package READMEs link files of the repository by absolute URL. `fp_di_fpdart` stays unpublished.
- Consequences: Each published change adds a changelog entry from now on, which supersedes the decision of this date to keep no changelog. The public history starts at the initial commit. A link of a README points to the `main` branch of the public repository.
- Supersedes: [Release the three packages as 0.1.0 without a changelog](#2026-11-14-decision--release-the-three-packages-as-010-without-a-changelog)
- Alternatives: Publishing without a repository leaves the links of the READMEs without a target.
- References: [LICENSE](../../LICENSE), [fp_di pubspec](../../packages/fp_di/pubspec.yaml), [fp_di_flutter pubspec](../../packages/fp_di_flutter/pubspec.yaml).

## [2026-11-14] decision | Set the lower bounds to Dart 3.10 and Flutter 3.38.1

- Context: The packages stated `sdk: ^3.9.0` and `flutter: '>=3.32.0'`, and the tests ran only on Dart 3.13 and Flutter 3.47. Flutter 3.32 ships Dart 3.8, so the Flutter bound could not hold. On Dart 3.9, the runtime tests passed, but the dev dependency `kiri_check` 1.4.0 needs `timezone` 0.11, which needs Dart 3.10, so the defect controls of the random histories could not run at that bound.
- Decision: The SDK lower bound is `^3.10.0` for each package and the workspace, and `fp_di_flutter` needs Flutter 3.38.1 or later. Flutter 3.38.0 ships a beta of Dart 3.10, which `^3.10.0` does not accept.
- Consequences: The whole test suite runs at the lower bound: on Flutter 3.38.1 with Dart 3.10.0, the 466 core tests, the defect controls among them, and the 42 Flutter tests pass. A host on Flutter 3.35 cannot use the packages. The workspace root keeps `analyzer ^12.1.0` for its scripts, which does not resolve on Flutter 3.38, so a lower-bound check copies the two packages out of the workspace.
- Alternatives: Dart 3.9 and Flutter 3.35 reach more hosts, and the runtime passed its tests there, but the bound would rest on a suite without its defect controls.
- References: [fp_di pubspec](../../packages/fp_di/pubspec.yaml), [fp_di_flutter pubspec](../../packages/fp_di_flutter/pubspec.yaml).

## [2026-11-14] decision | Name the API categories after what a reader looks for

- Context: The API reference had seven categories named after the layers of the API. The category Instance held one type, `ComponentNode`, and its page was the lifecycle guide, which explains the states of nodes and of scopes. The Declaration page explained the order of activation, the failure of `initialize`, and the release order, and the lifecycle guide repeated them. The pages of Errors and Exceptions had about twenty lines each. The guide pages under `doc/` are explanatory guides, not specs.
- Decision: The categories are Dependency, Declaration, Keys, Lifecycle, Observation, and Errors and exceptions. Lifecycle replaces Instance and holds `ComponentNode`, `NodePhase`, and `ScopePhase`, whose states its page draws. The Declaration page explains how to build and edit components and modules and their algebra; the Lifecycle page explains what the runtime does with them, with the state diagrams of a node and of a scope. One page explains errors and exceptions and keeps their difference. The Dependency page no longer lists the signatures that the API reference shows.
- Consequences: A reader finds the runtime behavior in one place. The category names no longer match the four layers of [Chaining and arguments](spec.md#chaining-and-arguments) one to one; the Lifecycle category holds the instance layer.
- Supersedes: [Group the API reference by layer and require a doc comment on each public member](#2026-11-14-decision--group-the-api-reference-by-layer-and-require-a-doc-comment-on-each-public-member)
- References: [dartdoc_options.yaml](../../packages/fp_di/dartdoc_options.yaml), [lifecycle guide](../../packages/fp_di/doc/lifecycle.md).

## [2026-11-15] decision | Own the scope of a subtree with ScopeBuilder

- Context: The decision of 2026-11-11 removed `ComponentScope`, and the decision of 2026-11-13 put the scope of a route in a `State` of that route. Three examples then held the same host code: two copies of `ScopeHost` and one page `State`. One copy missed a rule: it did not make a new scope when its module changed. A `FutureBuilder` over `initialize` shows only the first loading and the first failure, and the host still disposes the scope. The decision of 2026-11-11 rejected a widget that owns a scope because it needs a loading widget and an error widget among its arguments.
- Decision: `fp_di_flutter` adds `ScopeBuilder`. The unnamed constructor takes `create`, which it calls once for each scope of the closest provider; the widget calls `initialize`, publishes the scope through an inner `ScopeProvider.listenable`, and disposes the scope in `State.dispose`. `ScopeBuilder.value` takes a caller-owned scope and calls no `initialize` and no `dispose`, as `ScopeProvider.fixed` does. The builder receives a `ScopeSnapshot` with the scope, its `ScopeState`, and the failure of the `initialize` of the widget. A transition schedules a build before the next frame only when it changes the phase or a node state of the scope, so a child scope that starts or leaves builds nothing; the snapshot therefore holds the phase and the node states, and not the whole `ScopeState`. While its scope is disposed, the widget calls no builder, also for a rebuild from above. The widget has no retry; a new `key` makes a new scope. The examples use the widget.
- Consequences: The builder of the caller decides what a pending scope and a failure show, so the widget takes no loading widget and no error widget. The core does not change: a failed `initialize` still rolls the scope back to `declared`, and only the snapshot of the widget keeps the failure, so `ScopeBuilder.value` shows no failure. The package owns the scope that a `ScopeBuilder` creates, and still no scope that a caller supplies. `ScopeBuilder` is not a step of the random histories. When the widget was added, a defect of the rule on the disposal, of the comparison of its own state, of the reset of the failure, and of the report of a rollback each made a test of V-T-AR-UI-013 fail; the defects are not committed. A defect of the rule on `setState` made no test fail, because no public call of the core changes the phase or a node state of a scope inside the call, except a disposal.
- Alternatives: `ScopeBuilder(scope:)` alone follows `FutureBuilder` and `StreamBuilder`, but it cannot show the failure of `initialize` without a failure record in `ScopeState`, a change of the core. A `module:` argument compared by identity repeats the trap of a future made in `build`; `create` runs only for a new parent, as the `create` of Provider does. A `FutureBuilder` in a `State` of each page needs no new API, but it leaves the disposal and the later states to every page.
- Supersedes: [Publish scopes only and remove ComponentScope](#2026-11-11-decision--publish-scopes-only-and-remove-componentscope), for a widget that owns a scope. `ScopeProvider` still publishes only.
- References: [Flutter Integration](spec.md#flutter-integration), [scope_builder.dart](../../packages/fp_di_flutter/lib/src/scope_builder.dart), [scope_builder_test.dart](../../packages/fp_di_flutter/test/scope_builder_test.dart).

## [2026-11-15] decision | Borrow a caller-owned scope with ScopeBoundary and remove ScopeBuilder.value

- Context: A host that disposes a scope outside the widget tree, such as a session at logout, has routes of a flat `Navigator` that read the scope during their exit transition. The host rules covered a scope that a route owns and a listenable with reads that return null, but not strict reads of a scope that ends outside the tree. The core now delays a disposal for the holds of a scope. `ScopeBuilder.value` published a caller-owned scope and built from its state, but it took no hold.
- Decision: `fp_di_flutter` adds `ScopeBoundary(scope:, builder:, child:, debugLabel:)`. It takes a hold of the disposal of its scope at the mount, labeled with its `debugLabel` or the name of its route, closes it at the unmount, publishes the scope through an inner listenable, and builds from a `ScopeSnapshot`. Host rule 6 puts each route that reads such a scope below a boundary, and forbids removing those routes only after the `dispose` future. `ScopeBuilder.value` is removed in 0.2.0. `ScopeBuilder` and `ScopeBoundary` run their builders in `disposeRequested`, where the lookups answer; in `disposing` and `disposed` they call no builder and keep no widget below them.
- Consequences: A logout changes the listenable and disposes the session scope in one turn, and each exiting route reads live values until Flutter removes it; the host writes no barrier and no time limit unless it wants a bound. The three widgets split by ownership: `ScopeProvider` publishes, `ScopeBuilder` owns, and `ScopeBoundary` borrows. A boundary that stays mounted keeps the disposal waiting, so the host removes those routes or ignores the holds. A disposal that ignores the holds empties the subtree of a mounted boundary at the next frame, and a callback below it that runs before that frame can still read a disposed scope. Watchers below a provider keep their last values while a hold delays the disposal. The removal of `ScopeBuilder.value` breaks its callers.
- Alternatives: A boundary that drops its content in the frame after the request and reports the drop, as an application barrier does, shows an empty route during the exit transition and needs a contract on the builder; the hold makes the drop unnecessary. A boundary that keeps the widgets of its last build after the disposal starts lets a descendant that rebuilds by itself read a disposed scope. A static `retire` of the adapter keyed by scope could not see the descendants of a scope. Keeping `ScopeBuilder.value` beside `ScopeBoundary` leaves two widgets that differ only in the hold.
- Supersedes: the part on `ScopeBuilder.value` and on the widgets of the last build of [Own the scope of a subtree with ScopeBuilder](#2026-11-15-decision--own-the-scope-of-a-subtree-with-scopebuilder).
- References: [Flutter Integration](spec.md#flutter-integration), [R-UC-AR-UI-007](requirements.md#r-uc-ar-ui-007), [holds of a disposal](../runtime/lifecycle/spec.md#scope-declaration-and-initialization), G-AR-UI-001.

## [2026-11-15] decision | Exclude fp_di_fpdart from the architecture topic

- Context: `fp_di_fpdart` converted the operations of the core to fpdart types, and this topic owned that contract (R-UC-AR-DI-003, V-T-AR-DI-002). The package now drops its dependency on `fp_di` and implements its own runtime on fpdart, with every failure as a `Left`. It shares no code and no contract with the core.
- Decision: The architecture topic excludes `fp_di_fpdart`. The package is a separate track, and it gets its own spec when it needs one. The topic removes the package from the boundary table and the dependency direction, removes the Fpdart Interoperability section, and retires R-UC-AR-DI-003 and V-T-AR-DI-002. The other topics drop their mentions of the package.
- Consequences: No spec states the contract of `fp_di_fpdart` or its evidence; its README and tests are the only description until its track adds a spec. The core still has no package dependency, and V-L-AR-DI-001 checks it. A host that uses the core with fpdart converts the results itself, and no spec states rules for that conversion.
- Supersedes: [Ship fp_di_fpdart as the fpdart integration](#2026-11-09-decision--ship-fp_di_fpdart-as-the-fpdart-integration), [Keep fp_di_fpdart experimental and unpublished](#2026-11-14-decision--keep-fp_di_fpdart-experimental-and-unpublished), and [Keep fpdart interoperability at the host boundary](#2026-09-08-decision--keep-fpdart-interoperability-at-the-host-boundary).
- References: [requirements](requirements.md), [spec](spec.md), [fp_di_fpdart README](../../packages/fp_di_fpdart/README.md).

## [2026-11-16] decision | Split the pure rules of the runtime into core/

- Context: The runtime mixed its rules, such as resolution, node phases, and the search for the cause of an unavailable key, with the code that changes the object graph and runs effects. `fp_di_fpdart` keeps its rules in a pure core over one immutable state value, but a change there costs logarithmic time. The core of `fp_di` MUST keep constant-time changes.
- Decision: The folder `packages/fp_di/lib/src/core/` holds the pure rules as functions of read-only interfaces, which the runtime classes implement. The runtime keeps its object graph and changes it in place. A test checks that `core/` names no effect type.
- Consequences: A rule can be tested without a running runtime, and the structure follows `fp_di_fpdart` without its copy cost. Interface calls replace direct field reads in the rules; a benchmark of resolution and teardown shows no difference within the noise. The defect switches stay in `runtime/`, and the rules take their effect as arguments.
- Alternatives: Immutable records per node, replaced in place, were left for later. A table of ids instead of object references adds a lookup to each read.
- References: [source folders](spec.md#source-folders-of-the-core), [R-UC-AR-DI-005](requirements.md#r-uc-ar-di-005).

