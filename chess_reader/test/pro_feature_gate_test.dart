import 'package:chess_reader/core/entitlements/pro_entitlement.dart';
import 'package:chess_reader/core/entitlements/pro_purchase_dialog.dart';
import 'package:chess_reader/core/entitlements/pro_trial.dart';
import 'package:chess_reader/core/entitlements/purchase_service.dart';
import 'package:chess_reader/core/settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_pro_store_gateway.dart';

/// Reports purchased without touching the real store (no platform channel
/// available in widget tests).
class _FakePurchasedNotifier extends ProPurchasedNotifier {
  @override
  bool build() => true;
}

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  testWidgets('purchased: resolves true with no dialog', (tester) async {
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        proStoreGatewayProvider.overrideWithValue(FakeProStoreGateway()),
        proPurchasedProvider.overrideWith(_FakePurchasedNotifier.new),
      ],
    );
    addTearDown(container.dispose);

    bool? result;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => ElevatedButton(
                onPressed: () async {
                  result = await presentProFeatureGate(
                    context,
                    ref,
                    featureName: 'Guess the Move',
                    featureDescription: 'Predict the next move.',
                  );
                },
                child: const Text('trigger'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('trigger'));
    await tester.pumpAndSettle();

    expect(result, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('trial active: shows the remaining-count intro dialog',
      (tester) async {
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        proStoreGatewayProvider.overrideWithValue(FakeProStoreGateway()),
        proEntitlementProvider.overrideWith(
          (ref) =>
              ref.watch(proPurchasedProvider) ||
              ref.watch(proTrialRemainingProvider) > 0,
        ),
      ],
    );
    addTearDown(container.dispose);

    bool? result;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => ElevatedButton(
                onPressed: () async {
                  result = await presentProFeatureGate(
                    context,
                    ref,
                    featureName: 'Guess the Move',
                    featureDescription: 'Predict the next move.',
                  );
                },
                child: const Text('trigger'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('trigger'));
    await tester.pumpAndSettle();

    expect(find.text('Guess the Move'), findsOneWidget);
    expect(find.text('You have $kProTrialCredits free sessions left.'),
        findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();

    expect(result, isTrue);
    // The gate itself doesn't spend a credit -- the caller does.
    expect(container.read(proTrialRemainingProvider), kProTrialCredits);
  });

  testWidgets('trial active: "Not now" resolves false', (tester) async {
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        proStoreGatewayProvider.overrideWithValue(FakeProStoreGateway()),
        proEntitlementProvider.overrideWith(
          (ref) =>
              ref.watch(proPurchasedProvider) ||
              ref.watch(proTrialRemainingProvider) > 0,
        ),
      ],
    );
    addTearDown(container.dispose);

    bool? result;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => ElevatedButton(
                onPressed: () async {
                  result = await presentProFeatureGate(
                    context,
                    ref,
                    featureName: 'Guess the Move',
                    featureDescription: 'Predict the next move.',
                  );
                },
                child: const Text('trigger'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('trigger'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Not now'));
    await tester.pumpAndSettle();

    expect(result, isFalse);
  });

  testWidgets('trial exhausted: shows the full purchase dialog instead',
      (tester) async {
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        proStoreGatewayProvider.overrideWithValue(FakeProStoreGateway()),
        proEntitlementProvider.overrideWith(
          (ref) =>
              ref.watch(proPurchasedProvider) ||
              ref.watch(proTrialRemainingProvider) > 0,
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(proTrialRemainingProvider.notifier).state = 0;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => ElevatedButton(
                onPressed: () => presentProFeatureGate(
                  context,
                  ref,
                  featureName: 'Guess the Move',
                  featureDescription: 'Predict the next move.',
                ),
                child: const Text('trigger'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('trigger'));
    await tester.pumpAndSettle();

    expect(find.text('Pro Unlock'), findsOneWidget);
  });
}
