# fp_di - Algebraic dependency injection for Dart

[![CI](https://github.com/dfdgsdfg/fp_di/actions/workflows/ci.yml/badge.svg)](https://github.com/dfdgsdfg/fp_di/actions/workflows/ci.yml)

**Automatic ordering. Safe release. Composed like functions and their
inverses.**

Each dependency is a pair: `create` makes a value from the keys that it reads,
and `dispose` releases that value. Pairs combine like functions with their
inverses. The `create` functions run forward, and the `dispose` functions run
backward:

```text
(c₂, d₂) · (c₁, d₁)  =  (c₂ ∘ c₁ ,  d₁ ∘ d₂)
```

```dart
final pool = Dependency1<Config, Pool>(
  create: (config) => Pool.open(config.url),
  dispose: (pool) => pool.close(),
);
// Creates: open, then lease. Disposes: release, then close.
final session = pool.map((pool) => pool.lease(), dispose: (s) => s.release());
```

A scope composes the pairs of its components along the keys that they read:
a component is created after the components whose keys it reads and disposed
before them. A failure disposes what was created, in reverse. Modules of
components are values that you combine, edit, and inspect before anything
runs.

The workspace has four packages:

- [`fp_di`](packages/fp_di): the Dart runtime. It has no dependencies and does
  not import Flutter.
- [`fp_di_flutter`](packages/fp_di_flutter): publishes a caller-owned scope to
  the widget tree, with `BuildContext` reads.
- [`fp_di_fpdart`](packages/fp_di_fpdart): the scope lifecycle, lookups, and
  `Dependency` steps as fpdart types. It is experimental.
- [`fp_di_devtools`](packages/fp_di_devtools): a DevTools extension that shows
  the scopes and nodes of a running app. It is experimental, and a release of
  `fp_di` does not ship it.

Start with the [`fp_di` README](packages/fp_di/README.md).

## Motivation

A dependency container answers two questions: where a value comes from, and
when it exists. Most containers answer the first question. The application
then owns the second: the order of startup, the cleanup after a failed start,
and the order of release.
In get_it, for example, the release order is the reverse of the registration
order: a convention that the application keeps in step with the reads. In
fp_di, the order follows from the composition of the pairs, and the tests
check the laws of that composition.

Some libraries answer a part of the second question. In ZIO, a
[`ZLayer`](https://zio.dev/reference/contextual/zlayer) describes the
acquisition and the release of a service as one value. Layers compose, their
construction runs in parallel, a failure releases the acquired resources, and
`ZIO#provide` reports a missing dependency at compile time. A layer builds its
environment one time, for the program that it provides. A service that goes
away while the program runs, such as a user session at logout, is outside
that model.

fp_di keeps four guarantees together in one model:

- **Dependency order.** A component is created after the components whose
  keys it reads. Components that do not read each other start concurrently.
- **Transactional start.** A failed start releases what it created, in
  reverse, and publishes nothing.
- **Reverse release.** A component is released before the components that it
  reads. Components that do not read each other release concurrently.
- **Reactive rebinding.** When a publisher goes away, the components that read
  it are deactivated first, while the values that they read are still alive.
  When a publisher comes back, they activate again and read the new value.

The design adapts a subset of *A Programming Paradigm for Spatiotemporal
Composability* ([arXiv:2608.25512](https://arxiv.org/abs/2608.25512v1)). The
paper composes programs on two axes. On the spatial axis, components compose
through the keys that they require and provide: these are coeffects. On the
temporal axis, effects compose with their inverses: creation runs forward, and
release runs backward. In fp_di, a `Dependency` is both. Its pairs of
`create` and `dispose` are the effect algebra, and its shape of required and
optional keys is the coeffect algebra.

The lifecycle part of the paper (§4) keeps the two axes consistent while the
set of available keys changes over time. When a provider unloads, its key
stops being available first. The components that read the key deactivate
while their reads are still alive, and the provider releases after them.
Reactive rebinding comes from that part, and a layer that is built one time
does not need it.

Two parts of the paper are not adopted. A paper effect carries a witness that
its inverse restores the state; a `dispose` function does not. A paper key
carries operations with a commutativity contract, which make effects at
different keys provably independent; a `DiKey` carries only a value. The
independence and confluence theorems rest on those parts, so fp_di does not
claim them. The
[paper adoption](specs/architecture/spec.md#paper-adoption) table states what
is adopted and what is left out.

The combination is checked, not only stated:

- [Property tests](packages/fp_di/test/laws_test.dart) check the laws of
  shapes, components, modules, and values with generated inputs.
- [TLA+ models](verification/tla) of lazy resources, activation, rollback,
  reconciliation, cancellation, disposal, teardown, reentrancy, and failure
  reporting, and one model of their interaction, are checked with TLC.

Both are evidence within finite bounds and stated assumptions, not a proof.
The [formal verification](specs/verification/formal/spec.md) spec states the
bounds. The [specifications](specs/spec.md) state the requirements, the
design, the known gaps, and the decisions. [Agent setup](agents/README.md)
documents the shared guidance for coding agents.

## Examples

Each file in [`packages/fp_di/example`](packages/fp_di/example) runs with
`dart run`, for example:

```sh
dart run packages/fp_di/example/basic.dart
```

Each file in [`packages/fp_di_flutter/example`](packages/fp_di_flutter/example)
is one Flutter application. A widget test runs all of them:

```sh
flutter test packages/fp_di_flutter/test/example_test.dart
```

## Development

```sh
flutter pub get
dart analyze
dart run agents/scripts/test_core.dart
dart run agents/scripts/test_core.dart packages/fp_di_fpdart/test
flutter test packages/fp_di_flutter/test
dart run agents/scripts/validate_specs.dart --final
```
