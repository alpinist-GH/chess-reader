import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_reader/core/settings/app_settings.dart';
import 'package:chess_reader/features/library/book_import.dart';
import 'package:chess_reader/features/purchase/billing_config.dart';
import 'package:chess_reader/features/purchase/purchase_controller.dart';

Future<ProviderContainer> _container() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(
    overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('isSampleBookPath', () {
    test('matches the materialised sample, nothing else', () {
      expect(isSampleBookPath(p.join('x', 'books', 'samples', 'My System.pdf')),
          isTrue);
      // Wrong filename in the samples dir.
      expect(isSampleBookPath(p.join('x', 'books', 'samples', 'Other.pdf')),
          isFalse);
      // Right filename, but not under samples/.
      expect(
          isSampleBookPath(p.join('x', 'books', 'My System.pdf')), isFalse);
    });
  });

  test('freeRemaining counts down and clamps at zero', () {
    expect(
        const PurchaseState(proUnlocked: false, convertedCount: 0)
            .freeRemaining,
        kFreeConversionLimit);
    expect(
        const PurchaseState(proUnlocked: false, convertedCount: 2)
            .freeRemaining,
        (kFreeConversionLimit - 2).clamp(0, kFreeConversionLimit));
    expect(
        const PurchaseState(proUnlocked: false, convertedCount: 99)
            .freeRemaining,
        0);
  });

  group(
    'metering gate (store builds only)',
    () {
      test('allows the free allowance, then blocks', () async {
        final c = await _container();
        final pc = c.read(purchaseControllerProvider.notifier);
        for (var i = 0; i < kFreeConversionLimit; i++) {
          expect(pc.canConvert(), isTrue, reason: 'conversion ${i + 1}');
          pc.recordConversion();
        }
        expect(c.read(purchaseControllerProvider).convertedCount,
            kFreeConversionLimit);
        expect(pc.canConvert(), isFalse);
      });

      test('count persists across a fresh controller', () async {
        final c1 = await _container();
        c1.read(purchaseControllerProvider.notifier).recordConversion();
        final prefs = c1.read(sharedPrefsProvider);
        final c2 = ProviderContainer(
          overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
        );
        addTearDown(c2.dispose);
        expect(c2.read(purchaseControllerProvider).convertedCount, 1);
      });
    },
    // canConvert/recordConversion are inert unless billing is compiled in.
    skip: kBillingEnabled ? false : 'run with --dart-define=ENABLE_IAP=true',
  );
}
