// fp_di with fpdart through fp_di_fpdart: a checkout.
//
// fp_di owns the lifecycle: which value exists, when it is created, what it
// reads, and when it is disposed. fpdart describes the programs:
//
// - `Either` validates the configuration and keeps every problem;
//   `mapTaskEither` turns its `Left` into a setup failure.
// - `State` is a pure state machine for the cart; an owned store runs it.
// - `ReaderTaskEither` is the checkout workflow, with business failures as
//   `Left` data.
// - `toOption` makes the optional analytics read an `Option`.
// - `scope.use` brackets the scope: initialize, use, and always dispose.
//
// Run: dart run packages/fp_di_fpdart/example/checkout.dart
import 'package:fp_di/fp_di.dart';
import 'package:fp_di_fpdart/fp_di_fpdart.dart';
import 'package:fpdart/fpdart.dart';

Future<void> main() async {
  await shop();
  await businessFailures();
  await invalidConfiguration();
  await alwaysDisposed();
  await dormantMember();
}

String show<L, R>(Either<L, R> either) =>
    either.match((l) => 'Left($l)', (r) => 'Right($r)');

/// 1. A checkout inside `use`: initialize, use, dispose.
Future<void> shop() async {
  print('1. a checkout');
  final analytics = Analytics();
  late CartStore cart;
  final scope = Scope(
    module: shopModule((
      currency: 'EUR',
      creditLimit: 10000,
    ), analytics: analytics),
  );
  final result = await scope
      .use(
        ReaderTaskEither<Scope, CheckoutError, Receipt>.Do(($) async {
          final scope = await $(ReaderTaskEither.ask());
          // The cart is a pure state machine; the owned store runs it.
          cart = scope.get<CartStore>()
            ..run(add('tea', 2).andThen(() => add('cake', 1)));
          print('  cart ${cart.cart}, total ${cart.run(total)}');
          return $(ReaderTaskEither.fromTaskEither(scope.get<Checkout>()()));
        }),
      )
      .run();
  print('  ${show(result)}');
  print('  analytics ${analytics.events}, cart closed ${cart.isClosed}');
}

/// 2. A `Left` of the workflow is data: it rolls nothing back.
Future<void> businessFailures() async {
  print('2. business failures are data');
  final scope = Scope(
    module: shopModule((currency: 'EUR', creditLimit: 10000)),
  );
  final result = await scope
      .use(
        ReaderTaskEither<Scope, Never, List<String>>.Do(($) async {
          final scope = await $(ReaderTaskEither.ask());
          final cart = scope.get<CartStore>();
          final checkout = scope.get<Checkout>();
          final outcomes = <String>[];
          Future<void> attempt(String label) async =>
              outcomes.add('$label: ${show(await checkout().run())}');

          await attempt('empty');
          cart.run(add('kettle', 2)); // over the gateway's decline line
          await attempt('declined');
          cart.run(add('kettle', 1)); // over the credit limit
          await attempt('over limit');
          cart.run(remove('kettle').andThen(() => add('tea', 1)));
          await attempt('then');
          outcomes.add(
            'checkout still active: '
            '${scope.node(key: DiKey<Checkout>()).isActive}',
          );
          return outcomes;
        }),
      )
      .run();
  result.match((e) => print('  $e'), (lines) {
    for (final line in lines) {
      print('  $line');
    }
  });
}

/// 3. Every configuration problem in one setup failure.
Future<void> invalidConfiguration() async {
  print('3. an invalid configuration fails the setup');
  final scope = Scope(module: shopModule((currency: 'EURO', creditLimit: 0)));
  final result = await scope
      .use(ReaderTaskEither<Scope, Never, Unit>.of(unit))
      .run();
  switch (result.getLeft().toNullable()) {
    case InitializeFailed(:final failure):
      print('  ${failure.cause}');
      print('  rollback failures: ${failure.disposeFailures}');
    case final other:
      print('  unexpected: $other');
  }
}

/// 4. `use` disposes on every path, also when the use fails.
Future<void> alwaysDisposed() async {
  print('4. always disposed');
  late CartStore cart;
  final scope = Scope(module: shopModule((currency: 'EUR', creditLimit: 900)));
  final result = await scope
      .use(
        ReaderTaskEither<Scope, String, Unit>.Do(($) async {
          cart = (await $(ReaderTaskEither.ask())).get<CartStore>();
          return $(ReaderTaskEither.left('the use gave up'));
        }),
      )
      .run();
  print('  ${show(result)}, cart closed ${cart.isClosed}');

  // Without the bracket, a Right scope stays open until its owner disposes.
  final open = Scope(module: shopModule((currency: 'EUR', creditLimit: 900)));
  final task = open.initializeTask();
  print('  task built: initialized ${open.isInitialized}');
  await task.run();
  print('  second run: ${(await task.run()).getLeft().map((f) => f.error)}');
  final store = open.getEither<CartStore>();
  print('  after a Right: cart closed ${store.map((s) => s.isClosed)}');
  await open.disposeTask().run();
  print('  after dispose: cart closed ${store.map((s) => s.isClosed)}');
}

/// 5. A `Right` does not mean active: a member can wait for a key.
Future<void> dormantMember() async {
  print('5. a Right with a dormant member');
  final parent = Scope(
    module: Module(
      components: [
        Component<RawConfig>.value(
          key: rawConfigKey,
          value: (currency: 'EUR', creditLimit: 5000),
        ),
        config,
      ],
    ),
  );
  final shop = parent.child(
    module: Module(components: [gateway, cartStore, checkout]),
  );
  final result = await shop.initializeTask().run();
  final node = shop.node(key: DiKey<Checkout>());
  print(
    '  ${result.isRight() ? 'Right' : 'Left'}, '
    'checkout active ${node.isActive}, missing ${node.missing}',
  );
  final active = node.whenActiveTask().run();
  await parent.initializeTask().run();
  print('  after the parent: ${show(await active)}');
  await parent.disposeTask().run();
}

// ---------------------------------------------------------------------------
// The shop.
// ---------------------------------------------------------------------------

/// The configuration as it arrives, unchecked.
typedef RawConfig = ({String currency, int creditLimit});

/// A checked configuration.
final class Config {
  const Config._(this.currency, this.creditLimit);

  final String currency;
  final int creditLimit;
}

/// Why a configuration is invalid.
final class ConfigError {
  const ConfigError(this.reason);

  final String reason;

  @override
  String toString() => 'ConfigError($reason)';
}

/// One check of a raw configuration: `Some` problem, or `None`.
typedef ConfigCheck = Option<ConfigError> Function(RawConfig raw);

final List<ConfigCheck> configChecks = [
  (raw) => raw.currency.length == 3
      ? const None()
      : Some(ConfigError('currency ${raw.currency}')),
  (raw) => raw.creditLimit > 0
      ? const None()
      : Some(ConfigError('credit limit ${raw.creditLimit}')),
];

/// Checks a raw configuration and keeps every problem, not only the first,
/// so one report shows all that is wrong. The result is data: it decides
/// nothing about the lifecycle by itself.
Either<List<ConfigError>, Config> validate(RawConfig raw) {
  final problems = [for (final check in configChecks) ?check(raw).toNullable()];
  return problems.isEmpty
      ? Either.right(Config._(raw.currency, raw.creditLimit))
      : Either.left(problems);
}

/// The key of the raw configuration. A record type is structural, so the name
/// keeps this key apart from another record with the same fields.
const rawConfigKey = DiKey<RawConfig>(name: 'RawConfig');

/// The host policy for this app: an invalid configuration is a setup
/// failure. `mapTaskEither` names that policy: its `Left` fails the step with
/// a `DependencyLeft`, before commit.
final config = Component<Config>(
  dependency: Dependency.require<RawConfig>(
    key: rawConfigKey,
  ).mapTaskEither((raw) => TaskEither.fromEither(validate(raw))),
);

// ---------------------------------------------------------------------------
// The gateway: a Dependency1 is the reader of its constructor.
// ---------------------------------------------------------------------------

/// Why a charge failed. A business result, not a lifecycle failure.
sealed class CheckoutError {
  const CheckoutError();
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

final class EmptyCart extends CheckoutError {
  const EmptyCart();

  @override
  String toString() => 'EmptyCart()';
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

/// A `Dependency1` is already the reader of this constructor: it reads
/// `Config` from the scope, tracks the read, and builds the gateway. Wrapping
/// the constructor in an fpdart `Reader` would add nothing; a `Reader` (here a
/// `ReaderTaskEither`) earns its place for a program that runs later against
/// an environment, as the checkout below does.
final gateway = Component<PaymentGateway>(
  dependency: Dependency1<Config, PaymentGateway>(
    create: (config) =>
        PaymentGateway(config.currency, config.creditLimit ~/ 2),
  ),
);

// ---------------------------------------------------------------------------
// State: a pure cart state machine, run by an owned store.
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

/// Holds the cart of one scope and runs State programs against it. The
/// store is a resource: fp_di disposes it with its scope.
final class CartStore {
  Cart _cart = const {};
  bool _closed = false;

  /// Runs [program] and keeps its final state.
  A run<A>(State<Cart, A> program) {
    if (_closed) throw StateError('The cart is closed.');
    final (result, next) = program.run(_cart);
    _cart = next;
    return result;
  }

  Cart get cart => _cart;

  void close() => _closed = true;

  bool get isClosed => _closed;
}

final cartStore = Component<CartStore>(
  dependency: Dependency<CartStore>(
    create: CartStore.new,
    dispose: (store) => store.close(),
  ),
);

// ---------------------------------------------------------------------------
// ReaderTaskEither: the checkout workflow over a narrow environment.
// ---------------------------------------------------------------------------

/// Something that tracks events. Optional in this app.
final class Analytics {
  final List<String> events = [];

  void track(String event) => events.add(event);
}

/// The environment of the checkout: values that a `Dependency` read.
typedef CheckoutEnv = ({
  Config config,
  PaymentGateway gateway,
  CartStore cart,
  Option<Analytics> analytics,
});

/// A completed checkout.
final class Receipt {
  const Receipt(this.transaction, this.total, this.items);

  final String transaction;
  final int total;
  final Cart items;

  @override
  String toString() => 'Receipt($transaction, $total, $items)';
}

/// The workflow. Building it runs nothing; `run(env)` does. A `Left` leaves
/// the cart as it was.
final ReaderTaskEither<CheckoutEnv, CheckoutError, Receipt> checkoutProgram =
    ReaderTaskEither<CheckoutEnv, CheckoutError, Receipt>.Do(($) async {
      final env = await $(ReaderTaskEither.ask<CheckoutEnv, CheckoutError>());
      final sum = env.cart.run(total);
      if (sum == 0) {
        return $(ReaderTaskEither.left(const EmptyCart()));
      }
      if (sum > env.config.creditLimit) {
        return $(ReaderTaskEither.left(OverLimit(sum, env.config.creditLimit)));
      }
      final transaction = await $(
        ReaderTaskEither.fromTaskEither(env.gateway.charge(sum)),
      );
      final items = env.cart.run(takeAll);
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

/// The environment is read through a `Dependency`, so a new publisher of
/// any of these keys rebuilds the checkout. The optional analytics becomes
/// an `Option`; a bound `null` would look like absence, which is fine here
/// because `Analytics` is never null.
final checkout = Component<Checkout>(
  dependency:
      (
        Dependency.require<Config>(),
        Dependency.require<PaymentGateway>(),
        Dependency.require<CartStore>(),
        Dependency.maybe<Analytics>().toOption(),
      ).zip.mapN(
        (config, gateway, cart, analytics) => Checkout((
          config: config,
          gateway: gateway,
          cart: cart,
          analytics: analytics,
        )),
      ),
);

/// The shop module. The raw configuration comes from the host.
Module shopModule(RawConfig raw, {Analytics? analytics}) => Module(
  components: [
    Component<RawConfig>.value(key: rawConfigKey, value: raw),
    config,
    gateway,
    cartStore,
    checkout,
    if (analytics != null) Component<Analytics>.value(value: analytics),
  ],
);
