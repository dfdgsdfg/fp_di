# fp_di

Algebraic dependency injection for Dart.

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

The workspace has three packages:

- [`fp_di`](packages/fp_di): the Dart runtime. It has no dependencies and does
  not import Flutter.
- [`fp_di_flutter`](packages/fp_di_flutter): publishes a caller-owned scope to
  the widget tree, with `BuildContext` reads.
- [`fp_di_fpdart`](packages/fp_di_fpdart): the scope lifecycle, lookups, and
  `Dependency` steps as fpdart types. It is experimental and not published.

Start with the [`fp_di` README](packages/fp_di/README.md).

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

## Design

The [specifications](specs/spec.md) state the requirements, the design, the
known gaps, and the decisions. The design adapts a subset of *A Programming
Paradigm for Spatiotemporal Composability*
([arXiv:2608.25512](https://arxiv.org/abs/2608.25512v1)); the
[paper adoption](specs/architecture/spec.md#paper-adoption) table states what
is adopted and what is left out. [Agent setup](agents/README.md) documents the
shared guidance for coding agents.

## Development

```sh
flutter pub get
dart analyze
dart run agents/scripts/test_core.dart
dart run agents/scripts/test_core.dart packages/fp_di_fpdart/test
flutter test packages/fp_di_flutter/test
dart run agents/scripts/validate_specs.dart --final
```
