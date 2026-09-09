import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../settings/app_settings.dart' show sharedPrefsProvider;

// TODO(pro-upgrade): remove the redeemable test code once real in-app
// purchases are wired up — it exists only so TestFlight/release builds
// (where kDebugMode is false) can be unlocked for pre-launch testing.
const _kTestUnlockCode = 'chess';
const _kTestUnlockPrefKey = 'proTestUnlock';

/// Persists whether the temporary test-unlock code has been redeemed on
/// this device. See [_kTestUnlockCode].
class ProTestUnlockNotifier extends Notifier<bool> {
  SharedPreferences get _prefs => ref.read(sharedPrefsProvider);

  @override
  bool build() => _prefs.getBool(_kTestUnlockPrefKey) ?? false;

  /// Redeems [code]; returns whether it matched. Persists on success.
  bool redeem(String code) {
    if (code.trim().toLowerCase() != _kTestUnlockCode) return false;
    _prefs.setBool(_kTestUnlockPrefKey, true);
    state = true;
    return true;
  }
}

final proTestUnlockProvider =
    NotifierProvider<ProTestUnlockNotifier, bool>(ProTestUnlockNotifier.new);

/// Whether the user has purchased the Pro upgrade (Chessnut Move board sync,
/// play vs computer). Unlocked in debug builds so Pro features stay testable
/// on-device, and via the temporary test-unlock code otherwise (for
/// TestFlight/release testing). Swapping this for a real purchase/restore
/// check is the only change needed to unlock these features for paying
/// users once in-app purchases are wired up.
final proEntitlementProvider = Provider<bool>(
  (ref) => kDebugMode || ref.watch(proTestUnlockProvider),
);
