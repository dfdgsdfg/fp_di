// A checkout workflow over a narrow environment.
//
// One domain: the checkout. fp_di_fpdart owns the lifecycle. fpdart describes
// the workflow:
//
// - `ReaderTaskEither` is the workflow. It reads a narrow environment, and it
//   returns a `Receipt` or a `CheckoutError`.
// - A `Dependency` builds the environment. `zip.mapN` joins the reads of the
//   configuration, the gateway, and the cart. `Dependency.option` makes the
//   optional analytics an `Option`.
// - A business failure is a `Left`. It is data. It rolls nothing back, and the
//   checkout component stays in the scope.
// - `scope.use` brackets the scope: run, use, and always dispose.
//
// Run: dart run packages/fp_di_fpdart/example/checkout.dart
import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';

Future<void> main() async {
  await shop();
  await businessFailures();
}

/// Shows an `Either`. A `Left` that holds a `Cause` prints as a tree.
String show<L, R>(Either<L, R> either) => either.match(
  (l) => 'Left(${l is Cause<Object?> ? l.prettyPrint() : l})',
  (r) => 'Right($r)',
);

/// Reads a published value as a step of a program.
ReaderTaskEither<Scope, CheckoutError, T> read<T>() =>
    ReaderTaskEither((scope) async => scope.get<T>().mapLeft(NotReady.new));

/// 1. A checkout inside `use`: run, use, dispose.
Future<void> shop() async {
  print('1. a checkout');
  final analytics = Analytics();
  final scope = Scope(components: shopComponents(analytics: analytics));
  final result = await scope
      .use(
        ReaderTaskEither<Scope, CheckoutError, Receipt>.Do(($) async {
          final cart = await $(read<Cart>());
          cart.add('tea', 2);
          cart.add('cake', 1);
          print('  cart ${cart.items}, total ${cart.total}');
          final checkout = await $(read<Checkout>());
          return $(ReaderTaskEither.fromTaskEither(checkout()));
        }),
      )
      .run();
  print('  ${show(result)}');
  print('  analytics ${analytics.events}');
}

/// 2. A `Left` of the workflow is data. It rolls nothing back.
Future<void> businessFailures() async {
  print('2. business failures are data');
  final scope = Scope(components: shopComponents());
  final result = await scope
      .use(
        ReaderTaskEither<Scope, CheckoutError, List<String>>.Do(($) async {
          final cart = await $(read<Cart>());
          final checkout = await $(read<Checkout>());
          final outcomes = <String>[];
          Future<void> attempt(String label) async {
            final outcome = await checkout().run();
            outcomes.add('$label: ${show(outcome)}, cart ${cart.items}');
          }

          await attempt('empty');
          cart.add('kettle', 2); // over the decline line of the gateway
          await attempt('declined');
          cart.add('kettle', 1); // over the credit limit
          await attempt('over limit');
          cart.remove('kettle');
          cart.add('tea', 1);
          await attempt('then');
          final published = scope.get<Checkout>().match(
            (failure) => 'lost: $failure',
            (_) => 'in place',
          );
          outcomes.add('checkout component: $published');
          return outcomes;
        }),
      )
      .run();
  result.match((cause) => print('  ${cause.prettyPrint()}'), (lines) {
    for (final line in lines) {
      print('  $line');
    }
  });
}

// ---------------------------------------------------------------------------
// The services: configuration, gateway, and cart.
// ---------------------------------------------------------------------------

/// The configuration of the shop.
final class Config {
  const Config(this.currency, this.creditLimit);

  final String currency;
  final int creditLimit;

  @override
  String toString() => 'Config($currency, $creditLimit)';
}

/// Why a checkout failed. A business result, not a lifecycle failure.
sealed class CheckoutError {
  const CheckoutError();
}

final class EmptyCart extends CheckoutError {
  const EmptyCart();

  @override
  String toString() => 'EmptyCart()';
}

final class Declined extends CheckoutError {
  const Declined(this.amount);

  final int amount;

  @override
  String toString() => 'Declined($amount)';
}

final class OverLimit extends CheckoutError {
  const OverLimit(this.total, this.limit);

  final int total;
  final int limit;

  @override
  String toString() => 'OverLimit($total > $limit)';
}

/// The scope could not give a value to the program.
final class NotReady extends CheckoutError {
  const NotReady(this.failure);

  final DiFailure failure;

  @override
  String toString() => 'NotReady($failure)';
}

/// A payment gateway that declines amounts above [declineAbove].
final class PaymentGateway {
  PaymentGateway(this.currency, this.declineAbove);

  final String currency;
  final int declineAbove;
  int _next = 0;

  TaskEither<CheckoutError, String> charge(int amount) => TaskEither(
    () async => amount > declineAbove
        ? Either.left(Declined(amount))
        : Either.right('$currency-txn-${++_next}'),
  );
}

/// Prices in minor units.
const prices = <String, int>{'tea': 300, 'cake': 450, 'kettle': 4000};

/// A minimal mutable cart: item name to quantity.
final class Cart {
  final Map<String, int> items = {};

  void add(String item, int quantity) =>
      items[item] = (items[item] ?? 0) + quantity;

  void remove(String item) => items.remove(item);

  int get total => items.entries.fold(
    0,
    (sum, line) => sum + prices[line.key]! * line.value,
  );

  /// Empties the cart and yields what it held.
  Map<String, int> takeAll() {
    final held = {...items};
    items.clear();
    return held;
  }
}

/// Something that tracks events. Optional in this app.
final class Analytics {
  final List<String> events = [];

  void track(String event) => events.add(event);
}

/// The configuration is a value that exists already.
final config = Component<Config>.value(value: const Config('EUR', 10000));

/// The gateway reads `Config` from the scope and builds the payment gateway.
final gateway = Component<PaymentGateway>(
  dependency: Dependency.require<Config>().map<PaymentGateway>(
    (config) => PaymentGateway(config.currency, config.creditLimit ~/ 2),
  ),
);

final cart = Component<Cart>(dependency: Dependency<Cart>(create: Cart.new));

// ---------------------------------------------------------------------------
// ReaderTaskEither: the checkout workflow over a narrow environment.
// ---------------------------------------------------------------------------

/// The environment of the checkout: values that a `Dependency` read.
typedef CheckoutEnv = ({
  Config config,
  PaymentGateway gateway,
  Cart cart,
  Option<Analytics> analytics,
});

/// A completed checkout.
final class Receipt {
  const Receipt(this.transaction, this.total, this.items);

  final String transaction;
  final int total;
  final Map<String, int> items;

  @override
  String toString() => 'Receipt($transaction, $total, $items)';
}

/// The workflow. Building it runs nothing. `run(env)` does. The workflow
/// changes the cart only after the charge succeeds, so a `Left` leaves the
/// cart as it was.
final ReaderTaskEither<CheckoutEnv, CheckoutError, Receipt> checkoutProgram =
    ReaderTaskEither<CheckoutEnv, CheckoutError, Receipt>.Do(($) async {
      final env = await $(ReaderTaskEither.ask<CheckoutEnv, CheckoutError>());
      final sum = env.cart.total;
      if (sum == 0) {
        return $(ReaderTaskEither.left(const EmptyCart()));
      }
      if (sum > env.config.creditLimit) {
        return $(ReaderTaskEither.left(OverLimit(sum, env.config.creditLimit)));
      }
      final transaction = await $(
        ReaderTaskEither.fromTaskEither(env.gateway.charge(sum)),
      );
      final items = env.cart.takeAll();
      env.analytics.map((analytics) => analytics.track('checkout $sum'));
      return Receipt(transaction, sum, items);
    });

/// The checkout as a service: the workflow applied to the environment that
/// the component read.
final class Checkout {
  Checkout(this.env);

  final CheckoutEnv env;

  TaskEither<CheckoutError, Receipt> call() =>
      TaskEither(() => checkoutProgram.run(env));

  @override
  String toString() => 'Checkout(${env.config.currency})';
}

/// A `Dependency` reads the environment, so the scope creates the checkout
/// after the publishers of these keys. The optional analytics is an `Option`:
/// `None` when no scope publishes it.
final checkout = Component<Checkout>(
  dependency:
      (
        Dependency.require<Config>(),
        Dependency.require<PaymentGateway>(),
        Dependency.require<Cart>(),
        Dependency.option<Analytics>(),
      ).zip.mapN(
        (config, gateway, cart, analytics) => Checkout((
          config: config,
          gateway: gateway,
          cart: cart,
          analytics: analytics,
        )),
      ),
);

/// The components of the shop: a plain list. The analytics is optional.
List<Component<Object?>> shopComponents({Analytics? analytics}) => [
  config,
  gateway,
  cart,
  checkout,
  if (analytics != null) Component<Analytics>.value(value: analytics),
];
