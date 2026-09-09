import 'dart:async';

import 'package:chess_reader/core/entitlements/purchase_service.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

/// In-memory [ProStoreGateway] for tests — never touches a real store.
/// Defaults to "unavailable" (no product, no purchases), matching how a CI
/// runner or a bare simulator would answer.
class FakeProStoreGateway implements ProStoreGateway {
  final _controller = StreamController<List<PurchaseDetails>>.broadcast();
  bool available = false;
  final List<PurchaseDetails> completed = [];

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => _controller.stream;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> ids) async =>
      ProductDetailsResponse(productDetails: const [], notFoundIDs: ids.toList());

  @override
  Future<void> buyNonConsumable(ProductDetails product) async {}

  @override
  Future<void> restorePurchases() async {}

  @override
  void completePurchase(PurchaseDetails purchase) => completed.add(purchase);

  void dispose() => _controller.close();
}
