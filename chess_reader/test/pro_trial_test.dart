import 'package:chess_reader/core/entitlements/pro_trial.dart';
import 'package:chess_reader/core/entitlements/purchase_service.dart';
import 'package:chess_reader/core/settings/app_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_pro_store_gateway.dart';

/// Reports purchased without touching the real store (no platform channel
/// available in widget/unit tests).
class _FakePurchasedNotifier extends ProPurchasedNotifier {
  @override
  bool build() => true;
}

void main() {
  late SharedPreferences prefs;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        proStoreGatewayProvider.overrideWithValue(FakeProStoreGateway()),
      ],
    );
  });

  tearDown(() => container.dispose());

  test('starts with the full free trial pool', () {
    expect(container.read(proTrialRemainingProvider), kProTrialCredits);
  });

  test('consumeIfEligible counts down and persists', () {
    final notifier = container.read(proTrialRemainingProvider.notifier);

    expect(notifier.consumeIfEligible(), isTrue);
    expect(container.read(proTrialRemainingProvider), kProTrialCredits - 1);
    expect(prefs.getInt('proTrialRemaining'), kProTrialCredits - 1);
  });

  test('exhausts after kProTrialCredits uses and then refuses', () {
    final notifier = container.read(proTrialRemainingProvider.notifier);

    for (var i = 0; i < kProTrialCredits; i++) {
      expect(notifier.consumeIfEligible(), isTrue);
    }
    expect(container.read(proTrialRemainingProvider), 0);
    expect(notifier.consumeIfEligible(), isFalse);
    expect(container.read(proTrialRemainingProvider), 0);
  });

  test('never spends a credit once Pro is purchased', () {
    final purchasedContainer = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        proStoreGatewayProvider.overrideWithValue(FakeProStoreGateway()),
        proPurchasedProvider.overrideWith(_FakePurchasedNotifier.new),
      ],
    );
    addTearDown(purchasedContainer.dispose);

    final notifier = purchasedContainer.read(proTrialRemainingProvider.notifier);
    expect(notifier.consumeIfEligible(), isFalse);
    expect(purchasedContainer.read(proTrialRemainingProvider), kProTrialCredits);
  });
}
