// A cart as a pure state machine, run by a store that a component owns.
//
// One domain: the cart. The example shows four facts:
//
// 1. A `State<Cart, A>` program is a pure value. Build programs with
//    `flatMap` and `andThen`. A program runs nothing until a caller gives it
//    a cart.
// 2. A `CartStore` holds the cart of one scope and runs the programs. The
//    store is a resource. A component owns it, and the scope closes it.
// 3. A second component, `CartSummary`, reads the store. The scope releases
//    the summary before the store, so the summary can still read the store
//    when it releases.
// 4. A run on a closed store is a `Left` with `StoreClosed`. It does not
//    throw.
//
// `scope.use` runs the programs in one bracket: run, use, and dispose.
//
// Run: dart run packages/fp_di_fpdart/example/state.dart
import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';

Future<void> main() async {
  pureValues();
  await ownedStore();
}

/// Shows an `Either` as one line.
String show<L, R>(Either<L, R> either) =>
    either.match((l) => 'Left($l)', (r) => 'Right($r)');

/// 1. A program is a value. The same program runs on any cart.
void pureValues() {
  print('1. programs are pure values');
  final (sum, cart) = fill.run(const {});
  print('  fill on an empty cart: total $sum, cart $cart');
  final (again, _) = fill.run(const {});
  print('  fill again: total $again, the same result');
  final (other, held) = fill.run(const {'kettle': 1});
  print('  fill on a cart with a kettle: total $other, cart $held');
}

/// 2. A store runs the programs. 3. The summary releases before the store.
/// 4. A closed store answers with a `Left`.
Future<void> ownedStore() async {
  print('2. a store runs the programs');
  final scope = Scope(components: components);
  final result = await scope
      .use(
        ReaderTaskEither<Scope, CartError, CartStore>.Do(($) async {
          final store = await $(read<CartStore>());
          final summary = await $(read<CartSummary>());
          final sum = await $(lift(store.run(fill)));
          print('  fill: total $sum, cart ${store.cart}');
          print('  summary: ${await $(lift(summary.describe()))}');
          final settled = await $(lift(store.run(settle)));
          print('  settle: sum $settled, cart ${store.cart}');
          // The store leaves the bracket here, to show a run after dispose.
          return store;
        }),
      )
      .run();
  print('3. after the scope ends');
  result.match((cause) => print('  failed:\n${cause.prettyPrint()}'), (store) {
    print('  run on the closed store: ${show(store.run(total))}');
  });
}

// ---------------------------------------------------------------------------
// The cart as a state machine.
// ---------------------------------------------------------------------------

/// The cart: item name to quantity. Immutable.
typedef Cart = Map<String, int>;

/// Prices in minor units.
const prices = <String, int>{'tea': 300, 'cake': 450, 'kettle': 4000};

/// Adds [quantity] of [item].
State<Cart, Unit> add(String item, int quantity) => State<Cart, Unit>(
  (cart) => (unit, {...cart, item: (cart[item] ?? 0) + quantity}),
);

/// Removes [item].
State<Cart, Unit> remove(String item) =>
    State<Cart, Unit>((cart) => (unit, {...cart}..remove(item)));

/// The total of the cart.
final State<Cart, int> total = State<Cart, int>(
  (cart) => (
    cart.entries.fold(0, (sum, line) => sum + prices[line.key]! * line.value),
    cart,
  ),
);

/// Empties the cart and yields what it held.
final State<Cart, Cart> takeAll = State<Cart, Cart>(
  (cart) => (cart, const <String, int>{}),
);

/// Adds two items, and yields the total. `andThen` joins the steps.
final State<Cart, int> fill = add(
  'tea',
  2,
).andThen(() => add('cake', 1)).andThen(() => total);

/// Reads the total, then empties the cart. `flatMap` passes the total on.
final State<Cart, int> settle = total.flatMap((sum) => takeAll.map((_) => sum));

// ---------------------------------------------------------------------------
// The store and the summary: two components.
// ---------------------------------------------------------------------------

/// Why a program of the cart failed.
sealed class CartError {
  const CartError();
}

/// The store is closed. The scope has disposed it.
final class StoreClosed extends CartError {
  const StoreClosed();

  @override
  String toString() => 'StoreClosed';
}

/// The scope could not give a value to the program.
final class NotReady extends CartError {
  const NotReady(this.failure);

  final DiFailure failure;

  @override
  String toString() => 'NotReady($failure)';
}

/// Holds the cart of one scope and runs `State` programs against it.
final class CartStore {
  CartStore() {
    print('  + cart store');
  }

  Cart _cart = const {};
  bool _closed = false;

  /// Runs [program] and keeps its final state. A closed store gives a `Left`.
  Either<StoreClosed, A> run<A>(State<Cart, A> program) {
    if (_closed) return Either<StoreClosed, A>.left(const StoreClosed());
    final (result, next) = program.run(_cart);
    _cart = next;
    return Either<StoreClosed, A>.right(result);
  }

  /// The cart as it is now.
  Cart get cart => _cart;

  void close() {
    _closed = true;
    print('  - cart store');
  }
}

/// A service that reads the store.
final class CartSummary {
  CartSummary(this.store) {
    print('  + cart summary');
  }

  final CartStore store;

  /// One line about the cart.
  Either<StoreClosed, String> describe() =>
      store.run(total).map((sum) => '${store.cart.length} lines, total $sum');

  /// The summary releases before the store, so the last read still works.
  void close() {
    final last = describe().match((closed) => '$closed', (text) => text);
    print('  - cart summary (last read: $last)');
  }
}

final cartStore = Component<CartStore>(
  debugLabel: 'store',
  dependency: Dependency<CartStore>(
    create: CartStore.new,
    dispose: (store) => store.close(),
  ),
);

final cartSummary = Component<CartSummary>(
  debugLabel: 'summary',
  dependency: Dependency.require<CartStore>().map<CartSummary>(
    CartSummary.new,
    dispose: (summary) => summary.close(),
  ),
);

final components = <Component<Object?>>[cartStore, cartSummary];

// ---------------------------------------------------------------------------
// Steps of a program.
// ---------------------------------------------------------------------------

/// Reads a published value as a step of a program.
ReaderTaskEither<Scope, CartError, T> read<T>() =>
    ReaderTaskEither((scope) async => scope.get<T>().mapLeft(NotReady.new));

/// Lifts a result of the store into a step of a program.
ReaderTaskEither<Scope, CartError, A> lift<A>(Either<StoreClosed, A> result) =>
    ReaderTaskEither.fromEither(result);
