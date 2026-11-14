A key is the identity of a value in a scope. A `DiKey` has at most one
publisher in a scope. A collection key collects the elements that several
components contribute.

- `DiKey<T>()` names the one value of type `T`. Pass `name` for a second
  value of the same type.
- `DiSetKey<T>` and `DiMapKey<T>` are collection keys. Components contribute
  elements, and a reader gets the set or the map of the scope and its
  ancestors.
- `DiMapEntryKey<T>` is the key of one entry of a map, from
  `DiMapKey.entryKey(id)`.
- `DiKeyBase` is the supertype of every key, so a set of keys of different
  types has this element type.

## Collection keys in the shape

A collection read is not a requirement: an empty set is a valid set, and an
ancestor scope can add contributions that a module does not see. So a
collection read joins `reads`, never `requires`, and a module never subtracts
it:

```text
collectionKeys(Dependency.requireSet(K))       = {K}
optionalCollectionKeys(Dependency.maybeSet(K)) = {K}
reads(c) = requires(c) ∪ optional(c) ∪ collectionKeys(c) ∪ optionalCollectionKeys(c)

reads(m) = ⋃i ( (requires(ci) ∪ optional(ci)) \ ⋃j≠i publishes(cj) )
           ∪ ⋃i ( collectionKeys(ci) ∪ optionalCollectionKeys(ci) )
```

The map forms, `requireMap` and `maybeMap`, follow the same rules. A
contribution to a set publishes no key: `Component.into(K, d)` has
`contributesTo = {K}` and `publishes = ∅`. A module counts its contributors in
`contributes`:

```text
contributes(m) = { K ↦ |{ i : K ∈ contributesTo(ci) }| }
```

An entry of a map is different: it has a key of its own, `DiMapKey.entryKey(id)`,
so it is a publication, and a member can require one entry.

## Environments and keys

`Scope()` creates a root scope with its own runtime. An application needs one
root; each test can create its own, so no state leaks between tests. `child()`
creates a child scope whose lookup falls back to its parent. A binding in the
child shadows the parent binding, the parent cannot see child bindings, and
siblings cannot see each other. Bindings use `DiKey<T>()` by default;
`DiKey<T>(name: 'name')` supports multiple values of the same type.

**Name a key of a core value type.** Dart erases an extension type to its
representation type at run time, so `DiKey<PoolSize>()` of an extension type
over `int` is `DiKey<int>()`. Two such types would collide, and one alone
would serve every reader of `int`. A `Component` therefore rejects a key
without a name of `bool`, `int`, `double`, `num`, `String`, `BigInt`,
`DateTime`, `Duration`, `Uri`, `Symbol`, or `Object`, nullable or not, in its
key and in its reads. Give the extension type its key once, as `PoolSize.key`
above, and read it with `Dependency.require<PoolSize>(key: PoolSize.key)`. An
extension type over a class or a collection type still erases to that type;
name its key as well, or use a wrapper class.

## Collections

Several features can contribute elements of one interface to one value, for
example the scopes that an app starts. A collection key collects them. A
lookup by type does not: a member is an element only when it contributes.

| Key | Contribution | Read | Value |
|---|---|---|---|
| `DiSetKey<T>(name: ...)` | `Component<T>.into(key: ..., dependency: ...)`, anonymous | `Dependency.requireSet(key: ...)`, `Dependency.maybeSet(key: ...)` | `Set<T>` |
| `DiMapKey<T>(name: ...)` | `Component<T>(key: map.entryKey(id), ...)`, an ordinary publication | `Dependency.requireMap(key: ...)`, `Dependency.maybeMap(key: ...)` | `Map<String, T>` |

```dart
const startScopes = DiMapKey<AppScope>(name: 'start');
const foregroundScopes = DiSetKey<AppScope>(name: 'foreground');

final deviceModule = Module(components: [
  Component<AppScope>(key: startScopes.entryKey('connectivity'), dependency: ...),
  Component<AppScope>(key: startScopes.entryKey('lifecycle'), dependency: ...),
]);
Module engagementModule(Platform platform) => Module(components: [
  if (platform == Platform.mobile)
    Component<AppScope>.into(key: foregroundScopes, dependency: ...),
]);

final startObserver = Component<ScopeObserver>(
  dependency: Dependency.requireMap(key: startScopes)
      .map((scopes) => ScopeObserver(scopes.values.toList())),
);
```

- **Membership.** A reader sees the contributions of its scope and its
  ancestors, ancestors first, in declaration order. A parent does not see a
  child. A contribution of an ancestor that is not initialized yet counts. A
  contribution whose contributor is disposed by itself leaves the collection,
  and its readers activate again. A reader does not see its own contribution.
- **Strict and optional.** `requireSet` and `requireMap` wait while a
  contribution does not resolve, as `require` waits for a key. `maybeSet` and `maybeMap`
  read the active contributions and never wait. Both activate again when a
  contribution changes. An empty collection is an empty value, never `UndeclaredKeyError`.
- **Set.** Equal values of two contributors are one element, at the position
  of the first. A set contribution has no key. `replacing`, `without`, and
  `overriddenBy` do not select it, and `where` does.
- **Map.** An entry key is a `DiKey`, so another member reads one entry with
  `Dependency.require(key: map.entryKey(id))`, and `overriddenBy` replaces one
  entry in a test. An id selects the nearest active entry, as that `require`
  does, and keeps the position of its first declaration. Two entries of one
  id in one scope throw `DuplicateKeyError`.
- **Identity.** The kind, the element type, and the name identify a
  collection key. An entry key is a `DiMapEntryKey`, a `DiKey` that carries
  its map key and its id, so it equals no plain `DiKey` and no entry of
  another map.
- **Shape.** A collection key is in `reads` and never in `requires`.
  `Module.contributes` counts the set contributions per key; compare it across
  the variants, because the runtime does not detect a contribution to a wrong
  key. Declare each collection key once, as a constant that contributors
  import.

Use a map when an element needs an identity, to be read or replaced, and a
set for leaves that nothing refers to.
`example/collections.dart` runs both kinds with a
platform-only element, a fake entry, a child scope that adds an entry, and a
disposed contribution.
