import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../settings/app_settings.dart' show sharedPrefsProvider;

/// Product id for the one-time Pro Unlock, as configured in App Store
/// Connect (covers iOS + macOS via Universal Purchase) and Google Play
/// Console (Android). Must match exactly on both.
const kProProductId = 'pro_unlock';

const _kPurchasedPrefKey = 'proPurchased';

/// True only for the Developer-ID-signed macOS build
/// (`tool/build_macos_signed.sh`, distributed as a direct-download DMG, not
/// through the Mac App Store). Apple ties real StoreKit purchases to App
/// Store distribution, so that binary can't actually complete a purchase —
/// the purchase dialog checks this to avoid offering a "Buy" button it can't
/// honor. The Mac App Store build (`tool/build_macos_appstore.sh`) and every
/// other platform leave this false.
const kIsDevIdDistribution = String.fromEnvironment('DISTRIBUTION') == 'devid';

/// The subset of [InAppPurchase] the Pro Unlock flow needs, behind a seam so
/// tests can inject a fake instead of touching the real store — the real
/// `InAppPurchase.instance` singleton eagerly connects to a native billing
/// client (Android's `BillingClientManager` in particular) the moment it's
/// first accessed, which hangs or crashes outside a real app run. Mirrors
/// this codebase's existing `chessnutTransportProvider`/`FakeChessnutBoard`
/// pattern for the BLE transport.
abstract class ProStoreGateway {
  Stream<List<PurchaseDetails>> get purchaseStream;
  Future<bool> isAvailable();
  Future<ProductDetailsResponse> queryProductDetails(Set<String> ids);
  Future<void> buyNonConsumable(ProductDetails product);
  Future<void> restorePurchases();
  void completePurchase(PurchaseDetails purchase);
}

class _RealProStoreGateway implements ProStoreGateway {
  @override
  Stream<List<PurchaseDetails>> get purchaseStream =>
      InAppPurchase.instance.purchaseStream;

  @override
  Future<bool> isAvailable() => InAppPurchase.instance.isAvailable();

  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> ids) =>
      InAppPurchase.instance.queryProductDetails(ids);

  @override
  Future<void> buyNonConsumable(ProductDetails product) =>
      InAppPurchase.instance
          .buyNonConsumable(purchaseParam: PurchaseParam(productDetails: product));

  @override
  Future<void> restorePurchases() => InAppPurchase.instance.restorePurchases();

  @override
  void completePurchase(PurchaseDetails purchase) =>
      InAppPurchase.instance.completePurchase(purchase);
}

final proStoreGatewayProvider =
    Provider<ProStoreGateway>((ref) => _RealProStoreGateway());

/// Whether the user owns the Pro Unlock. This is the persisted source of
/// truth for [proEntitlementProvider][../entitlements/pro_entitlement.dart] —
/// it stays subscribed to the store's purchase stream for the app's whole
/// lifetime (independent of whether a purchase dialog is open) so a purchase
/// or restore completes and persists even if the UI that started it has
/// since been dismissed, and is the only place that calls
/// [ProStoreGateway.completePurchase].
class ProPurchasedNotifier extends Notifier<bool> {
  SharedPreferences get _prefs => ref.read(sharedPrefsProvider);
  ProStoreGateway get _store => ref.read(proStoreGatewayProvider);
  StreamSubscription<List<PurchaseDetails>>? _sub;

  @override
  bool build() {
    final purchased = _prefs.getBool(_kPurchasedPrefKey) ?? false;
    _sub = _store.purchaseStream.listen(_onPurchaseUpdates, onError: (_) {});
    ref.onDispose(() => _sub?.cancel());
    return purchased;
  }

  /// Replays past purchases so a reinstall / another device recovers
  /// entitlement without the user having to find "Restore Purchases".
  /// Called once explicitly from `main()` — not from [build] — so merely
  /// referencing this provider (e.g. in widget tests) never reaches out to
  /// the store. Best effort: the store may be unreachable.
  Future<void> restoreOnStartup() async {
    try {
      if (await _store.isAvailable()) {
        await _store.restorePurchases();
      }
    } catch (_) {
      // Ignored — the purchase stream / a later explicit "Restore
      // Purchases" tap remain the ways entitlement gets picked up.
    }
  }

  void _onPurchaseUpdates(List<PurchaseDetails> purchases) {
    for (final purchase in purchases) {
      if (purchase.productID == kProProductId &&
          (purchase.status == PurchaseStatus.purchased ||
              purchase.status == PurchaseStatus.restored)) {
        _markPurchased();
      }
      if (purchase.pendingCompletePurchase) {
        _store.completePurchase(purchase);
      }
    }
  }

  void _markPurchased() {
    if (state) return;
    state = true;
    _prefs.setBool(_kPurchasedPrefKey, true);
  }
}

final proPurchasedProvider =
    NotifierProvider<ProPurchasedNotifier, bool>(ProPurchasedNotifier.new);

enum ProPurchaseFlowStatus { idle, loadingProduct, unavailable, buying, error }

class ProPurchaseFlowState {
  const ProPurchaseFlowState({
    this.status = ProPurchaseFlowStatus.idle,
    this.product,
    this.errorMessage,
  });

  final ProPurchaseFlowStatus status;
  final ProductDetails? product;
  final String? errorMessage;

  ProPurchaseFlowState copyWith({
    ProPurchaseFlowStatus? status,
    ProductDetails? product,
    String? errorMessage,
  }) =>
      ProPurchaseFlowState(
        status: status ?? this.status,
        product: product ?? this.product,
        errorMessage: errorMessage,
      );
}

/// Drives the purchase dialog: loading the live localized price, starting a
/// purchase, and starting a restore, surfacing transient status for the UI.
/// Does not itself complete purchases or persist entitlement — that's
/// [ProPurchasedNotifier], which stays active regardless of this dialog.
class ProPurchaseFlowNotifier extends Notifier<ProPurchaseFlowState> {
  ProStoreGateway get _store => ref.read(proStoreGatewayProvider);
  StreamSubscription<List<PurchaseDetails>>? _sub;

  @override
  ProPurchaseFlowState build() {
    _sub = _store.purchaseStream.listen(_onPurchaseUpdates, onError: (_) {});
    ref.onDispose(() => _sub?.cancel());
    return const ProPurchaseFlowState();
  }

  void _onPurchaseUpdates(List<PurchaseDetails> purchases) {
    for (final purchase in purchases) {
      if (purchase.productID != kProProductId) continue;
      switch (purchase.status) {
        case PurchaseStatus.pending:
          state = state.copyWith(status: ProPurchaseFlowStatus.buying);
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          state = state.copyWith(status: ProPurchaseFlowStatus.idle);
        case PurchaseStatus.error:
          state = state.copyWith(
            status: ProPurchaseFlowStatus.error,
            errorMessage: purchase.error?.message ?? 'Purchase failed.',
          );
        case PurchaseStatus.canceled:
          state = state.copyWith(status: ProPurchaseFlowStatus.idle);
      }
    }
  }

  Future<void> loadProduct() async {
    if (state.product != null) return;
    state = state.copyWith(status: ProPurchaseFlowStatus.loadingProduct);
    try {
      if (!await _store.isAvailable()) {
        state = state.copyWith(status: ProPurchaseFlowStatus.unavailable);
        return;
      }
      final response = await _store.queryProductDetails({kProProductId});
      if (response.productDetails.isEmpty) {
        state = state.copyWith(
          status: ProPurchaseFlowStatus.unavailable,
          errorMessage: response.error?.message,
        );
        return;
      }
      state = ProPurchaseFlowState(
        status: ProPurchaseFlowStatus.idle,
        product: response.productDetails.first,
      );
    } catch (_) {
      state = state.copyWith(status: ProPurchaseFlowStatus.unavailable);
    }
  }

  Future<void> buy() async {
    final product = state.product;
    if (product == null) return;
    state = state.copyWith(status: ProPurchaseFlowStatus.buying);
    try {
      await _store.buyNonConsumable(product);
    } catch (_) {
      state = state.copyWith(
        status: ProPurchaseFlowStatus.error,
        errorMessage: 'Purchase failed. Please try again.',
      );
    }
  }

  Future<void> restore() async {
    state = state.copyWith(status: ProPurchaseFlowStatus.buying);
    try {
      await _store.restorePurchases();
    } catch (_) {
      // Fall through to the timeout below, which resets to idle.
    }
    // If nothing was actually restored, the stream stays silent — drop back
    // to idle after giving the store a moment to reply.
    await Future.delayed(const Duration(seconds: 2));
    if (state.status == ProPurchaseFlowStatus.buying) {
      state = state.copyWith(status: ProPurchaseFlowStatus.idle);
    }
  }
}

final proPurchaseFlowProvider =
    NotifierProvider<ProPurchaseFlowNotifier, ProPurchaseFlowState>(
        ProPurchaseFlowNotifier.new);
