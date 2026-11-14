# Ontology Decisions

Append accepted decisions only. Newest at the bottom.
Current definitions live in YAML. Authoring guidance lives in [AGENTS.md](AGENTS.md).

## [2026-11-03] decision | Adopt a documentation-only local ontology for workspace topology

- Context: Specs own behavior, and rules own agent practice. No artifact gives stable identifiers or typed
  relations for the workspace packages and the runtimes they need. The documentation rules come from a
  sibling repository that keeps its own ontology, so any ID reuse needs a policy.
- Decision: Maintain flat YAML topic files under `ontology/` as reviewed documentation. Ship no validator,
  script, schema file, or CI wiring. Describe the format in [the format spec](../specs/ontology/spec.md).
  Adopt only the node kinds, relation types, and bindings that this repository has evidence for. Reuse
  another repository's ID only when its meaning matches. Cite only existing files in this repository.
- Consequences: The ontology adds no build or test cost. Integrity of IDs, endpoints, and evidence paths
  rests on manual review and can drift. The CI-workflow and WebView vocabulary of the sibling ontology is
  not available until a later decision adds it. A validator also needs a new decision that supersedes this one.
- References: [project architecture](../specs/architecture/spec.md).

## [2026-11-03] decision | Move the lifecycle glossary into concept nodes

- Context: The lifecycle spec glossary owned the project vocabulary. The ontology rule assigns short definitions and stable identity to `ontology/`, and the format now has a `concept` kind.
- Decision: Add `lifecycle.yml` with the 16 glossary terms as concept nodes in a new `lifecycle` domain. Behavior clauses were removed from the definitions after confirming that the lifecycle spec body states each one. The IDs `component_description` and `component_node` avoid the `component` kind name. The lifecycle spec keeps its `Glossary` heading as a pointer.
- Consequences: Terms have code anchors where a public type exists (`Component`, `ComponentHandle`, `DiContext`, `EffectLease`, `Undo`). Binding record, provider, provision, episode, release, rollback, cleanup, deactivation, withdrawal, failure region, and signal have no public type. Concepts that are not in the old glossary, such as key, shape, handle, and override, are not added by this decision.
- References: [lifecycle.yml](lifecycle.yml), [lifecycle spec](../specs/runtime/lifecycle/spec.md#glossary).

## [2026-11-06] decision | Rebind scope and episode symbols after the context rename

- Context: The runtime renamed the scope type `DiContext` to `DiScope` and the activation `Context` to `DiContext`. The 2026-11-03 entry names `DiContext` as the scope anchor, so the old symbol now names a different concept.
- Decision: The `scope` concept binds `DiScope`. The `activation_episode` concept binds `DiContext`. The `dependency_key` concept binds `DiKey`.
- Consequences: Readers of the 2026-11-03 entry must read its `DiContext` as the current `DiScope`. Episode now has a public type.
- References: [lifecycle.yml](lifecycle.yml), [lifecycle log](../specs/runtime/lifecycle/log.md).

## [2026-11-06] decision | Rename the provider and provision concepts

- Context: The runtime renamed its producer verb from provide to publish, because functional effect libraries use provide for the consumer side.
- Decision: The `provider` concept is now `publisher` with the term Publisher. The `provision` concept is now `publication` with the term Publication. The definitions do not change.
- Consequences: The old IDs are retired and are not reused. Earlier entries use the old IDs and terms.
- References: [lifecycle.yml](lifecycle.yml), [lifecycle log](../specs/runtime/lifecycle/log.md).

## [2026-11-06] decision | Rebind the lease concept to Lease

- Context: The runtime removed `Effect` and renamed `EffectLease` to `Lease`.
- Decision: The `lease` concept binds the symbol `Lease`. The term and definition do not change.
- Consequences: The concept term and its public symbol now share one word.
- References: [lifecycle.yml](lifecycle.yml), [lifecycle log](../specs/runtime/lifecycle/log.md).

## [2026-11-06] decision | Define a component as a shape plus a resource

- Context: The runtime replaced `Component.acquire`, `Component(create)`, and `Component.pure` with the unnamed constructor `Component(resource)`, and the release of `Resource` became optional.
- Decision: The `component_description` definition names its two parts: a graph shape and a `Resource` that creates the value and optionally releases it. The term, ID, and symbol do not change, and no `resource` node is added.
- Consequences: The definition matches the lifecycle spec. The `component_node` definition stays: a node is an installed registration of one component description.
- References: [lifecycle.yml](lifecycle.yml), [lifecycle log](../specs/runtime/lifecycle/log.md).

## [2026-11-06] decision | Define a component as a source plus its publications

- Context: The runtime split a component into a source, which is a `Resource` or a `Graph`, and the keys it publishes. The activation context `DiContext` left the public API.
- Decision: The `component_description` definition names a source and its published keys. The `activation_episode` concept keeps its term and file binding but no longer binds the symbol `DiContext`, because the episode context has no public type. No `graph` node is added.
- Consequences: The definitions match the lifecycle spec. A concept without a symbol has no public type, as the topic description states.
- References: [lifecycle.yml](lifecycle.yml), [lifecycle log](../specs/runtime/lifecycle/log.md).

## [2026-11-08] decision | Name the read source Dependency

- Context: The runtime renamed the source type `Graph` to `Dependency`.
- Decision: The `component_description` definition names its source as a `Resource` or a `Dependency`. No node is added for the source type, and the `dependency_key` concept does not change.
- Consequences: The definition matches the lifecycle spec and the public API.
- References: [lifecycle.yml](lifecycle.yml), [lifecycle log](../specs/runtime/lifecycle/log.md).

## [2026-11-08] decision | A publisher is always a node

- Context: The runtime removed `DiScope.override`, so no binding record is owned by a scope without a node.
- Decision: The `publisher` definition names only a node. The term and ID do not change.
- Consequences: The definition matches the lifecycle spec, where a value that exists before activation enters through `Component.value`.
- References: [lifecycle.yml](lifecycle.yml), [lifecycle log](../specs/runtime/lifecycle/log.md).

## [2026-11-08] decision | A node is created by initialize

- Context: The runtime removed `DiScope.use` and `DiScope.useModule`. A scope now declares its components at creation and creates its nodes in `initialize`.
- Decision: The `component_node` definition names the registration that a scope creates from one declared component in `initialize`. The term, ID, and symbol do not change.
- Consequences: The definition matches the lifecycle spec, where the contents of a scope are fixed at creation.
- References: [lifecycle.yml](lifecycle.yml), [lifecycle log](../specs/runtime/lifecycle/log.md).

## [2026-11-08] decision | Bind the node concept to ComponentNode

- Context: The runtime renamed `ComponentHandle` to `ComponentNode`.
- Decision: The `component_node` file binding names the symbol `ComponentNode`. The term, ID, and definition do not change.
- Consequences: The concept name and the public type now match.
- References: [lifecycle.yml](lifecycle.yml), [lifecycle log](../specs/runtime/lifecycle/log.md).

## [2026-11-08] decision | Make leases and inverses internal

- Context: The runtime removed `Resource`, `Lease`, and `Undo` from the public API; a `dispose` argument of a `Dependency` defines a release.
- Decision: The `lease` and `inverse` concepts keep their terms and file bindings without a symbol, because they have no public type. The `component_description` definition names a `Dependency` source and its key.
- Consequences: The ontology matches the public API, as its description states for concepts without a symbol.
- References: [lifecycle.yml](lifecycle.yml), [lifecycle log](../specs/runtime/lifecycle/log.md).

## [2026-11-09] decision | Add the fpdart package

- Context: The workspace adds `packages/fp_di_fpdart`, a package that puts the public runtime API into fpdart types.
- Decision: `fp_di_fpdart` is a workspace component node with a `depends_on` edge to `fp_di_core`. fpdart itself gets no node, because it is an external pub package, not a platform of the workspace.
- Consequences: The ontology lists every workspace member of the root `pubspec.yaml`.
- References: [workspace.yml](workspace.yml), [architecture log](../specs/architecture/log.md).

## [2026-11-10] decision | List the words of the public API in the ontology

- Context: The first decision shipped no script, so symbol bindings drifted: the `scope` concept bound `DiScope` to a file that no longer declares it. The public API had no checked vocabulary.
- Decision: Concept nodes list their words in `identifiers`. `vocabulary.yml` holds the Dart, Flutter, fpdart, diagnostics, and prefix words. New concepts name `Dependency`, `Module`, and `Lazy`. The `publisher` concept avoids `provision`. The `scope` binding moves to `scope.dart`. A script reads the ontology; this supersedes the rule of the first decision that no script ships.
- Consequences: Every word of the 441 public names resolves to a node. Some words have two meanings, such as `map` and `child`, and some concepts have two words, such as `maybe` and `optional`; the ontology records them as they are, and a rename needs its own decision.
- Supersedes: [Adopt a documentation-only local ontology for workspace topology](#2026-11-03-decision--adopt-a-documentation-only-local-ontology-for-workspace-topology), only its rule of no script.
- References: [vocabulary.yml](vocabulary.yml), [lifecycle.yml](lifecycle.yml), [format spec](../specs/ontology/spec.md#vocabulary).

## [2026-11-10] decision | Rename the cancellation signal concept to the cancellation token

- Context: The `cancellation_signal` concept had the term Signal. Its definition said that the spec defines a `CancellationSignal` and that no public type exists. The public type is `CancellationToken`, with one token for each failure region.
- Decision: The ID `cancellation_signal` is now `cancellation_token`, with the term Cancellation token. The definition names the `CancellationToken` of one failure region, and a file binding names the symbol `CancellationToken`. The identifiers do not change. The `failure_region` definition and the relation descriptions say token instead of signal. The `collection_key`, `contribution`, and `membership` definitions say contribution for an element of a collection key. The term Membership stays, because its definition still names the contributions that a reader sees.
- Consequences: The old ID is retired and is not reused. Earlier entries use the old ID and the term Signal. The `component_node` concept keeps the identifiers `member` and `members` for the components of a module or scope.
- References: [lifecycle.yml](lifecycle.yml), [lifecycle log](../specs/runtime/lifecycle/log.md).

## [2026-11-10] decision | Make the words of the public API the terms for dispose functions, disposal, and readers

- Context: The public API and the READMEs say `dispose`, dispose function, and reader. The ontology had the term Inverse, listed `dispose` only as a Dart word, and had no concept for a disposal, a declaration, a reader, a dependent, or a shape. A concept has one term, so the words of the API and the words of the spec could not both be terms.
- Decision: The word of the public API is the term. The ID `inverse` is now `dispose_function` with the term Dispose function, and it avoids `inverse`. The `lease`, `release`, and `activation_episode` definitions say dispose function. New concepts name Disposal, Declaration, Reader, Dependent, and Shape. The words `dispose`, `disposed`, `disposing`, and `shape` move from the vocabulary nodes to these concepts. The `component_description` definition says that a scope creates a node, not that a component is installed.
- Consequences: The old ID is retired and is not reused. Earlier entries use the term Inverse. Prose says dispose function, and the TLA+ models keep the word Inverse in their identifiers. The states of a node that is not active, the words install and register, and the layer names of the architecture spec have no concept yet. The word consumer is not avoided, because it also names a caller of a package.
- References: [lifecycle.yml](lifecycle.yml), [vocabulary.yml](vocabulary.yml), [lifecycle log](../specs/runtime/lifecycle/log.md), [format spec](../specs/ontology/spec.md#vocabulary).

## [2026-11-10] decision | Accept the definitions of the public API terms and narrow the Disposal definition

- Context: The entry before this one added the concepts Dispose function, Disposal, Declaration, Reader, Dependent, and Shape with definitions that no reviewer had confirmed. The Disposal definition had a second sentence that compared a disposal with a deactivation. A failed `initialize` removes the nodes that it created, and no caller calls `dispose` for them.
- Decision: The reviewer accepts the six definitions. The Disposal definition is its first sentence only, because the comparison states behavior, and the word permanent already says it. Disposal covers every permanent removal of a node, so it includes the nodes that a failed `initialize` removes.
- Consequences: The definitions pass the concept definition review of the format spec. The lifecycle spec still says unregister for the removal of a node; that word has no concept yet.
- References: [lifecycle.yml](lifecycle.yml), [format spec](../specs/ontology/spec.md#verification).

## [2026-11-10] decision | Define Dormant and name the node without the word registration

- Context: The state diagram, the READMEs, and the dartdoc say dormant, and no concept defined the word. An earlier entry of this date left it without a concept, because prose used it with two extents; the lifecycle log now limits it to the state of the diagram. The `component_node` definition called a node a registration, a word that the spec no longer uses for a node.
- Decision: A new concept Dormant names a node that is not active, has no running activation, and that the runtime tries to activate when its required keys resolve. The `component_node` definition says the runtime form of one declared component description. The words install, register, and unregister get no concept: creation of a node and Disposal name those events.
- Consequences: Dormant excludes a node that waits for a withdrawal, a blocked node, and a disposed node. The other states of the diagram have their meanings in the lifecycle spec, not in the ontology.
- References: [lifecycle.yml](lifecycle.yml), [lifecycle spec](../specs/runtime/lifecycle/spec.md#runtime-behavior), [lifecycle log](../specs/runtime/lifecycle/log.md).

## [2026-11-10] decision | Make Mutation a concept

- Context: The public API says mutation in `SlowMutation` and `onSlowMutation`, and the word was listed only as a diagnostics word. Prose said mutation for a queued lifecycle operation and transaction for the same operation while it runs.
- Decision: A new concept Mutation names one lifecycle operation that a caller requests and that the runtime runs from its queue. The word `mutation` moves from the diagnostics vocabulary to this concept. The concept does not avoid the word transaction, because prose keeps it for the all-or-nothing activation.
- Consequences: Prose says mutation for the queued operation, before and while it runs. The TLA+ models and the private names of the runtime keep the word transaction.
- References: [lifecycle.yml](lifecycle.yml), [vocabulary.yml](vocabulary.yml), [lifecycle log](../specs/runtime/lifecycle/log.md).

## [2026-11-10] decision | Make Setup a concept

- Context: The `activation_episode` definition, the lifecycle spec, and the formal invariants say setup, and no concept defined the word. Some prose also said setup for the initialization of a scope and for an activation as a whole.
- Decision: A new concept Setup names the part of an activation episode that runs the steps of the `Dependency`, before the commit. Prose that meant the initialization of a scope or a whole activation now says so. The word strict gets no concept: it has one meaning, a collection read that waits for every contribution, and the Collection keys section of the lifecycle spec states it.
- Consequences: Setup is a part of an activation episode. A `Left` of the fpdart package fails the setup, and the activation then rolls back.
- References: [lifecycle.yml](lifecycle.yml), [lifecycle spec](../specs/runtime/lifecycle/spec.md), [architecture spec](../specs/architecture/spec.md).

## [2026-11-11] decision | Accept the Dormant, Mutation, Setup, and Node definitions and keep Shape

- Context: Three entries of 2026-11-10 added the concepts Dormant, Mutation, and Setup and changed the `component_node` definition. No reviewer had confirmed these definitions. A review also asked whether graph words could replace the term Shape, which is a word of this project and not of the paper.
- Decision: The reviewer accepts the four definitions without a change. The term Shape stays.
- Consequences: No node and no relation changes. The private names of the runtime now follow these terms; the lifecycle log records the rename.
- References: [lifecycle.yml](lifecycle.yml), [lifecycle log](../specs/runtime/lifecycle/log.md).

## [2026-11-11] decision | Rename the diagnostics vocabulary to the observation vocabulary

- Context: The architecture spec now names the read-only API layer observation, as the lifecycle spec does. The vocabulary node for the words of that layer had the ID `diagnostics_words` and the term Diagnostics vocabulary.
- Decision: The node is `observation_words` with the term Observation vocabulary. Its definition and its identifiers do not change.
- Consequences: No other node and no relation referred to the old ID. Earlier entries say diagnostics vocabulary for this node.
- References: [vocabulary.yml](vocabulary.yml), [architecture log](../specs/architecture/log.md).

## [2026-11-11] decision | Add the word labels to the observation vocabulary

- Context: `DuplicateKeyError.members` listed the labels of members and is now `labels`. The vocabulary had `label` and not its plural.
- Decision: The observation vocabulary lists `labels`. The field `undeclared` of `UndeclaredKeyError` uses a word that the vocabulary already has.
- Consequences: No concept changes.
- References: [vocabulary.yml](vocabulary.yml), [lifecycle log](../specs/runtime/lifecycle/log.md).

## [2026-11-11] decision | Add the state words to the observation vocabulary

- Context: `ComponentNode.state` and the enum `ComponentNodeState` make the states of `describe` public identifiers. The vocabulary had no entry for `state`, `activating`, and `waiting`.
- Decision: The observation vocabulary lists `state`, `activating`, and `waiting`. The other values use words of existing concepts.
- Consequences: No concept changes. The lifecycle spec keeps the meaning of each state in its Observation section.
- References: [vocabulary.yml](vocabulary.yml), [lifecycle spec](../specs/runtime/lifecycle/spec.md#observation).

## [2026-11-11] decision | Remove the word instance from the key identifiers

- Context: The getter `DependencyKey.instanceName` is `name` again, so no public identifier has the word instance.
- Decision: The `dependency_key` concept no longer lists `instance`. It keeps `name`.
- Consequences: No definition changes.
- References: [lifecycle.yml](lifecycle.yml), [architecture log](../specs/architecture/log.md).

## [2026-11-11] decision | Add the suffix base to the naming vocabulary

- Context: `DependencyKey` is `DiKeyBase`, and `AnyComponent` is `ComponentBase`. The vocabulary had no entry for the word base.
- Decision: The `naming_prefixes` node lists `base`. Its definition adds the suffix that marks a supertype without a type argument.
- Consequences: No concept changes. The `dependency_key` concept keeps its term and its `DiKey` symbol.
- References: [vocabulary.yml](vocabulary.yml), [architecture log](../specs/architecture/log.md).

## [2026-11-11] decision | Add the word id to the collection key concept

- Context: The key of a map entry has its own type, `DiMapEntryKey`, with the public getter `id`. The vocabulary had no entry for the word id.
- Decision: The `collection_key` concept lists `id`. Its definition states that an entry key has the id of its entry in the map.
- Consequences: The concept keeps its term and its `DiCollectionKey` symbol. The `dependency_key` concept does not change: an entry key is a `DiKey`.
- References: [lifecycle.yml](lifecycle.yml), [lifecycle log](../specs/runtime/lifecycle/log.md).

## [2026-11-11] decision | Follow the Flutter adapter that only publishes

- Context: `DiScopeProvider` has the constructors `fixed` and `listenable`, and `ComponentScope` is removed. The vocabulary had no entry for the words fixed and listenable, and the words builder and loading had no use left. The `fp_di_flutter` component still named widget scopes and guards of mount and unmount.
- Decision: The `flutter_words` node lists `fixed` and `listenable` and no longer lists `builder` and `loading`. The definition of the `fp_di_flutter` component states that the package publishes a caller-owned scope and owns no scope.
- Consequences: The ownership boundary of the component is smaller: the host owns every scope. No concept of the lifecycle changes.
- References: [vocabulary.yml](vocabulary.yml), [workspace.yml](workspace.yml), [architecture log](../specs/architecture/log.md).

## [2026-11-11] decision | Follow the model and runtime folders of the core

- Context: The core sources moved from `packages/fp_di/lib/src/` into the folders `src/model/` and `src/runtime/`. Two files also changed names: `self_check.dart` to `runtime_faults.dart`, and `teardown.dart` to `runtime_teardown.dart`.
- Decision: Each source path of `lifecycle.yml` and `vocabulary.yml` names the new folder of its file.
- Consequences: No concept, term, or symbol changes.
- References: [lifecycle.yml](lifecycle.yml), [vocabulary.yml](vocabulary.yml), [architecture log](../specs/architecture/log.md).

## [2026-11-11] decision | Follow the new names of three errors

- Context: `InvalidLifecycleOperationError` is `OutsideActivationError`, and `ReentrantLifecycleError` is `ReentrantMutationError`. No identifier uses the words invalid and lifecycle now, and the vocabulary had no entry for the word outside.
- Decision: The `activation_episode` concept lists `outside`. The `dart_words` node no longer lists `invalid` and `lifecycle`.
- Consequences: No concept changes its term or its definition.
- References: [lifecycle.yml](lifecycle.yml), [vocabulary.yml](vocabulary.yml), [architecture log](../specs/architecture/log.md).

## [2026-11-11] decision | Follow the name DisposeFailure

- Context: `DisposeIssue` is `DisposeFailure`, and the fields `issues` and `rollbackIssues` are `failures` and `rollbackFailures`. No identifier uses the words issue and issues now.
- Decision: The `release` concept lists `failure` and `failures` and no longer lists `issue` and `issues`. Its definition states what a dispose failure is.
- Consequences: The word failure has two entries. In `fpdart_words` it names a failure value of the fpdart package, such as `DiFailure`. In the `release` concept it names one release that threw.
- References: [lifecycle.yml](lifecycle.yml), [lifecycle log](../specs/runtime/lifecycle/log.md).

## [2026-11-11] decision | Follow the name Scope

- Context: `DiScope` is `Scope`, `DiScopeProvider` is `ScopeProvider`, and the file of the widget is `scope_provider.dart`.
- Decision: Each symbol and each source path of the ontology names the new type or file.
- Consequences: No concept changes its term or its definition.
- References: [lifecycle.yml](lifecycle.yml), [vocabulary.yml](vocabulary.yml), [architecture log](../specs/architecture/log.md).

## [2026-11-11] decision | Add the words mermaid and collapsed to the observation vocabulary

- Context: `ShapeGraph.toMermaid` returns the shape as the text of a Mermaid chart, and its argument `collapsed` selects a chart with one node for each origin. The vocabulary had no entry for the two words.
- Decision: The observation vocabulary lists `mermaid`, with the meaning of the Mermaid chart language, and `collapsed`, for a chart that draws a group of members as one node. The word mermaid names the form of a view of the shape graph, as `json` names the form of the export.
- Consequences: No concept changes. Each word has one use, in the method of the shape graph.
- References: [vocabulary.yml](vocabulary.yml), [lifecycle log](../specs/runtime/lifecycle/log.md).

## [2026-11-11] decision | Add the word origins to the module concept

- Context: A `Module` has the public getter `origins`, the label of the module that listed each member. The vocabulary had no entry for the word.
- Decision: The `module` concept lists `origins`. The definition of the concept does not change: an origin is a label for the shape export, and no decision of the runtime reads it.
- Consequences: The word has one meaning, the origin of a member of a module.
- References: [lifecycle.yml](lifecycle.yml), [lifecycle log](../specs/runtime/lifecycle/log.md).

## [2026-11-12] decision | Add the words of the state value, and remove the words of the change event

- Context: `Scope.state` returns the values `ScopeState` and `NodeState`, with the enums `ScopePhase` and `NodePhase`. `DiChange` and `DiChangeKind` left the public API, and their words `activated`, `deactivated`, `available`, and `change` name no identifier now.
- Decision: The concept `runtime_state` lists `phase`, `nodes`, `children`, `commits`, `changed`, `since`, `declared`, `initializing`, `requested`, and `deactivating`, and it binds `state.dart`. The words `activated`, `deactivated`, `available`, and `change` leave their concepts and the observation vocabulary.
- Consequences: A phase is the place of a scope or a node in its machine, and a state is the immutable value. The word `changed` has one use, in `ScopeState.changedSince`.
- References: [lifecycle.yml](lifecycle.yml), [vocabulary.yml](vocabulary.yml), [lifecycle log](../specs/runtime/lifecycle/log.md).

## [2026-11-12] decision | Move the words of the node reads to node, nodes, and find

- Context: `Scope.members` is `Scope.nodes`, `Scope.member` is `Scope.node`, and `Scope.maybeNode` is `Scope.findNode`. No public identifier uses the words `member` and `members` now.
- Decision: The `component_node` concept lists `node`, `nodes`, and `find`. The words `member` and `members` leave the concept.
- Consequences: The word `nodes` has two entries. In `component_node` it names the `ComponentNode` list of a scope. In `runtime_state` it names the `NodeState` list of a `ScopeState`. The word member stays in prose for a component of a module or scope.
- References: [lifecycle.yml](lifecycle.yml), [lifecycle log](../specs/runtime/lifecycle/log.md).

## [2026-11-12] decision | Give the word nodes one concept, and add the word states

- Context: `ScopeState.nodes` is `ScopeState.nodeStates`. The word `nodes` now names only `Scope.nodes`, and the vocabulary had no entry for the word `states`.
- Decision: The concept `runtime_state` lists `states` and does not list `nodes`. The concept `component_node` keeps `nodes`.
- Consequences: The word `nodes` has one entry again, the `ComponentNode` list of a scope. The word `states` has one use, in `ScopeState.nodeStates`.
- References: [lifecycle.yml](lifecycle.yml), [lifecycle log](../specs/runtime/lifecycle/log.md).

## [2026-11-12] decision | Remove the word children from the state of the runtime

- Context: `ScopeState.children` is `ScopeState.childStates`. No public identifier uses the word `children` now.
- Decision: The concept `runtime_state` does not list `children`. The member takes `child` from the Flutter vocabulary and `states` from `runtime_state`.
- Consequences: The word `states` has two uses, in `ScopeState.nodeStates` and in `ScopeState.childStates`.
- References: [lifecycle.yml](lifecycle.yml), [lifecycle log](../specs/runtime/lifecycle/log.md).

## [2026-11-12] decision | Add the word keys, and remove the word collections

- Context: `collections` and `optionalCollections` of `Dependency` and `ComponentBase` are `collectionKeys` and `optionalCollectionKeys`. The vocabulary had `key` and not `keys`, and no public identifier uses the word `collections` now.
- Decision: The concept that lists `key` also lists `keys`. The concept `collection_key` does not list `collections`.
- Consequences: A public member that holds collection keys has the words `collection` and `keys`. The word collections stays in prose for the sets and the maps that readers read.
- References: [lifecycle.yml](lifecycle.yml), [lifecycle log](../specs/runtime/lifecycle/log.md).

## [2026-11-12] decision | List the word ancestor in place of ancestors

- Context: `ShapeGraph.ancestors` and the `ancestors` argument of `ShapeGraph.of` are `ancestorModules`. No public identifier uses the word `ancestors` now, and the vocabulary did not list `ancestor`.
- Decision: The scope concept lists `ancestor` and does not list `ancestors`.
- Consequences: The word ancestors stays in prose for the scopes above a scope. In a public identifier, the word `ancestor` comes before the word for the thing that the member holds.
- References: [lifecycle.yml](lifecycle.yml), [lifecycle log](../specs/runtime/lifecycle/log.md).

## [2026-11-13] decision | Add the word requiring to the module concept

- Context: The lifecycle spec defines `Module.requiring` and `Module.withoutRequiring`, the members of a module that require a set of keys and the module without them. The vocabulary had `require` and `requires` in the dependency concept and not `requiring`. The argument `ancestorKeys` takes the words `ancestor` and `keys`, which the vocabulary lists.
- Decision: The `module` concept lists `requiring`, beside `replacing`. The words `member`, `members`, `needing`, and `available` stay out of the public identifiers.
- Consequences: The word `requiring` names an edit of a module that follows required keys. No public identifier has the word until the runtime implements the design: the gap G-RT-LC-013 of the lifecycle topic is open.
- References: [lifecycle.yml](lifecycle.yml), [lifecycle log](../specs/runtime/lifecycle/log.md).

## [2026-11-14] decision | Allow the word inverse in its mathematical sense

- Context: The dispose function concept listed `inverse` and `inverses` in `avoid`, so that prose names the function of a `dispose` argument a dispose function. The READMEs now present a dependency as a pair of `create` and `dispose` that composes like a function and its inverse, which is the mathematical sense of the word. The prose scan reported each of those uses. The ontology rule keeps `avoid` for a word with one sense, because an ordinary word in `avoid` reports its other senses.
- Decision: The dispose function concept no longer lists `inverse` and `inverses` in `avoid`. Prose still names the function of a `dispose` argument a dispose function.
- Consequences: The READMEs and the specs can state the algebra of pairs with the word inverse. The scan no longer reports a use of inverse as a synonym of dispose function, so a review catches that use.
- References: [lifecycle.yml](lifecycle.yml), [documentation_ontology.rules.md](../agents/rules/documentation_ontology.rules.md).

## [2026-11-14] decision | Add the word available to the key concept

- Context: `Scope.getWhenAvailable` completes with the value of a key once it has one. The key concept listed `unavailable` for `UnavailableKeyException`, and not `available`. An earlier entry of 2026-11-13 kept `available` out of the public identifiers, when it was the name of an argument of the module edits.
- Decision: The key concept lists `available`. A key is available when `get` returns a value for it, and `getWhenAvailable` waits for that.
- Consequences: `available` and `unavailable` name one condition and its negation. The edits of a module still take `ancestorKeys`, not `available`.
- References: [lifecycle.yml](lifecycle.yml), [lifecycle log](../specs/runtime/lifecycle/log.md).
