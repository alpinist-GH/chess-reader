import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pro_trial.dart';
import 'purchase_service.dart';

/// Whether the user currently has access to Pro features (Chessnut Move
/// board sync, play vs computer): purchased, in debug builds (so Pro stays
/// testable on-device), or still within the free trial credit pool.
///
/// This is a **peek** — it does not spend a trial credit. Call sites that
/// actually start a Pro-gated action (starting a computer game, connecting a
/// Chessnut board) must call [ProTrialNotifier.consumeIfEligible] themselves
/// at the point the action begins; every other read of this provider is for
/// UI enablement only.
final proEntitlementProvider = Provider<bool>(
  (ref) =>
      kDebugMode ||
      ref.watch(proPurchasedProvider) ||
      ref.watch(proTrialRemainingProvider) > 0,
);
