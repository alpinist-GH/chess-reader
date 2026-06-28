import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/settings/app_settings.dart';
import 'billing_config.dart';

/// Snapshot of the user's purchase + metering state.
class PurchaseState {
  const PurchaseState({
    required this.proUnlocked,
    required this.convertedCount,
  });

  /// Whether the lifetime "Pro" entitlement is active.
  final bool proUnlocked;

  /// How many books have been converted (fresh conversions only — the sample
  /// book and cache re-opens don't count). Capped informally by the paywall.
  final int convertedCount;

  int get freeRemaining =>
      (kFreeConversionLimit - convertedCount).clamp(0, kFreeConversionLimit);

  PurchaseState copyWith({bool? proUnlocked, int? convertedCount}) =>
      PurchaseState(
        proUnlocked: proUnlocked ?? this.proUnlocked,
        convertedCount: convertedCount ?? this.convertedCount,
      );
}

/// The single gate for the freemium model. Tracks the on-device conversion
/// count and the RevenueCat "Pro" entitlement, with no accounts: RevenueCat
/// runs under its anonymous app-user id, and we mirror the entitlement into
/// SharedPreferences so the check works synchronously and offline.
///
/// When [kBillingEnabled] is false (desktop / sideload builds) this stays inert
/// and [canConvert] always returns true.
class PurchaseController extends Notifier<PurchaseState> {
  static const _kProUnlocked = 'pro_unlocked';
  static const _kConvertedCount = 'converted_count';

  bool _configured = false;

  SharedPreferences get _prefs => ref.read(sharedPrefsProvider);

  @override
  PurchaseState build() {
    final p = _prefs;
    final initial = PurchaseState(
      proUnlocked: p.getBool(_kProUnlocked) ?? false,
      convertedCount: p.getInt(_kConvertedCount) ?? 0,
    );
    if (kBillingEnabled) {
      // Fire-and-forget: configure RevenueCat and refresh the entitlement the
      // first time the controller is read. The update listener keeps state in
      // sync afterwards (e.g. after a purchase or restore on another device).
      unawaited(_configure());
    }
    return initial;
  }

  Future<void> _configure() async {
    if (_configured) return;
    _configured = true;
    final key = revenueCatApiKey;
    if (key.isEmpty) return; // No key for this platform — leave metering local.
    try {
      await Purchases.configure(PurchasesConfiguration(key));
      Purchases.addCustomerInfoUpdateListener(_onCustomerInfo);
      _onCustomerInfo(await Purchases.getCustomerInfo());
    } catch (_) {
      // Network/configuration failure: fall back to the locally cached flag.
    }
  }

  void _onCustomerInfo(CustomerInfo info) {
    final unlocked = info.entitlements.active.containsKey(kEntitlementId);
    _setProUnlocked(unlocked);
  }

  void _setProUnlocked(bool unlocked) {
    _prefs.setBool(_kProUnlocked, unlocked);
    if (state.proUnlocked != unlocked) {
      state = state.copyWith(proUnlocked: unlocked);
    }
  }

  /// Whether a fresh conversion is currently allowed. Order matters: a paid
  /// user is never metered.
  bool canConvert() {
    if (!kBillingEnabled) return true;
    if (state.proUnlocked) return true;
    return state.convertedCount < kFreeConversionLimit;
  }

  /// Records one fresh (cache-miss, non-sample) conversion. No-op once Pro is
  /// unlocked so the counter doesn't run away after purchase.
  void recordConversion() {
    if (!kBillingEnabled || state.proUnlocked) return;
    final next = state.convertedCount + 1;
    _prefs.setInt(_kConvertedCount, next);
    state = state.copyWith(convertedCount: next);
  }

  /// The current offering's lifetime package (for price + purchase), or null if
  /// offerings can't be loaded.
  Future<Package?> lifetimePackage() async {
    try {
      final offerings = await Purchases.getOfferings();
      final current = offerings.current;
      if (current == null) return null;
      return current.lifetime ??
          (current.availablePackages.isNotEmpty
              ? current.availablePackages.first
              : null);
    } catch (_) {
      return null;
    }
  }

  /// Buys the lifetime unlock. Returns true if the entitlement is now active.
  /// A user cancellation returns false without surfacing an error.
  Future<bool> purchaseLifetime(Package package) async {
    try {
      // ignore: deprecated_member_use
      final result = await Purchases.purchasePackage(package);
      _onCustomerInfo(result.customerInfo);
      return state.proUnlocked;
    } on PlatformException catch (e) {
      final code = PurchasesErrorHelper.getErrorCode(e);
      if (code == PurchasesErrorCode.purchaseCancelledError) return false;
      rethrow;
    }
  }

  /// Restores a previous purchase (App Store review requires this path).
  Future<bool> restore() async {
    try {
      _onCustomerInfo(await Purchases.restorePurchases());
      return state.proUnlocked;
    } catch (_) {
      return false;
    }
  }
}

final purchaseControllerProvider =
    NotifierProvider<PurchaseController, PurchaseState>(PurchaseController.new);
