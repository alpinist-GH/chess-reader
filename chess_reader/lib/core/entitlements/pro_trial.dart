import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../settings/app_settings.dart' show sharedPrefsProvider;
import 'purchase_service.dart';

/// Number of free Pro-feature sessions (Play vs Computer games, Chessnut
/// Move connections) a device gets before purchase is required.
const kProTrialCredits = 5;

const _kTrialRemainingPrefKey = 'proTrialRemaining';

/// Tracks the shared pool of free trial credits for the two Pro features.
/// Persisted per-device; not tied to the purchase itself (once purchased,
/// [ProEntitlement] stops consulting this at all).
class ProTrialNotifier extends Notifier<int> {
  SharedPreferences get _prefs => ref.read(sharedPrefsProvider);

  @override
  int build() => _prefs.getInt(_kTrialRemainingPrefKey) ?? kProTrialCredits;

  /// Spends one trial credit if the user hasn't purchased Pro and credits
  /// remain. No-ops (and returns `false`) once purchased — call sites should
  /// still gate on [proEntitlementProvider] first; this only guards against
  /// double-spending if it's ever called after a purchase completes mid-flow.
  bool consumeIfEligible() {
    if (ref.read(proPurchasedProvider)) return false;
    if (state <= 0) return false;
    state -= 1;
    _prefs.setInt(_kTrialRemainingPrefKey, state);
    return true;
  }
}

final proTrialRemainingProvider =
    NotifierProvider<ProTrialNotifier, int>(ProTrialNotifier.new);
