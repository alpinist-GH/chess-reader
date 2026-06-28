import 'dart:io';

/// Compile-time configuration for the freemium meter + in-app purchase.
///
/// Billing (the meter and the paywall) is active only on store builds — iOS,
/// the Mac App Store, and Google Play — which pass `--dart-define=ENABLE_IAP=true`
/// and the RevenueCat public SDK keys. Everything else (the Windows installer,
/// the sideloaded macOS DMG, Linux, plain `flutter run`) leaves [kBillingEnabled]
/// false and stays fully unlocked: RevenueCat's Flutter SDK can't take payment
/// there anyway. See the Codemagic workflows for where these are set.
const bool kBillingEnabled = bool.fromEnvironment('ENABLE_IAP');

/// RevenueCat entitlement granted by the lifetime unlock. Must match the
/// entitlement identifier configured in the RevenueCat dashboard.
const String kEntitlementId = 'pro';

/// Number of free book conversions before the paywall. The sample book and
/// re-opening an already-converted (cached) book don't count.
const int kFreeConversionLimit = 3;

/// Shown if RevenueCat offerings can't be loaded (offline / misconfigured), so
/// the paywall still names a price.
const String kFallbackPrice = '\$4.99';

/// Secret promo code that grants the lifetime unlock locally, bypassing the
/// store purchase. Compared case-insensitively after trimming. Used for
/// give-aways / press / review copies — it sets the entitlement on this device
/// only (it doesn't touch RevenueCat), and survives store entitlement syncs.
const String kPromoCode = 'maxpromo';

/// RevenueCat **public** SDK key for the current platform, supplied at build
/// time. These are not secrets (they're embedded in the shipped binary), but we
/// keep them out of source so each store build injects its own.
String get revenueCatApiKey {
  if (Platform.isIOS) {
    return const String.fromEnvironment('REVENUECAT_IOS_KEY');
  }
  if (Platform.isMacOS) {
    return const String.fromEnvironment('REVENUECAT_MACOS_KEY');
  }
  if (Platform.isAndroid) {
    return const String.fromEnvironment('REVENUECAT_ANDROID_KEY');
  }
  return '';
}
