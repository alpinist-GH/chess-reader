import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'pro_trial.dart';
import 'purchase_service.dart';

/// Shows the Pro Unlock purchase dialog and returns whether Pro is unlocked
/// when it closes (either because this purchase/restore just succeeded, or
/// it already was). Shared by every Pro-gated feature once its free trial
/// credits are exhausted.
Future<bool> showProPurchaseDialog(BuildContext context, WidgetRef ref) async {
  if (ref.read(proPurchasedProvider)) return true;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => const _ProPurchaseDialog(),
  );
  return result ?? ref.read(proPurchasedProvider);
}

class _ProPurchaseDialog extends ConsumerStatefulWidget {
  const _ProPurchaseDialog();

  @override
  ConsumerState<_ProPurchaseDialog> createState() => _ProPurchaseDialogState();
}

class _ProPurchaseDialogState extends ConsumerState<_ProPurchaseDialog> {
  @override
  void initState() {
    super.initState();
    // The Developer-ID DMG build can't complete a real StoreKit purchase
    // (Apple ties that to Mac App Store distribution), so don't even query
    // the store for a product it can't sell.
    if (!kIsDevIdDistribution) {
      Future.microtask(
        () => ref.read(proPurchaseFlowProvider.notifier).loadProduct(),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(proPurchasedProvider, (previous, purchased) {
      if (purchased && Navigator.of(context).canPop()) {
        Navigator.of(context).pop(true);
      }
    });

    final flow = ref.watch(proPurchaseFlowProvider);
    final notifier = ref.read(proPurchaseFlowProvider.notifier);
    final busy = flow.status == ProPurchaseFlowStatus.loadingProduct ||
        flow.status == ProPurchaseFlowStatus.buying;

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.lock_outline),
          SizedBox(width: 8),
          Text('Pro Unlock'),
        ],
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              kIsDevIdDistribution
                  ? "You've used all $kProTrialCredits free Pro sessions. "
                      'Get ChessBook Reader from the Mac App Store to '
                      'purchase Pro — this direct-download build can\'t '
                      'process purchases itself.'
                  : "You've used all $kProTrialCredits free Pro sessions. "
                      'Unlock Pro to keep syncing a Chessnut Move board and '
                      'playing vs computer, on this device and any other '
                      'you sign in on.',
            ),
            if (!kIsDevIdDistribution) ...[
              const SizedBox(height: 16),
              if (flow.status == ProPurchaseFlowStatus.error &&
                  flow.errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    flow.errorMessage!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              if (flow.status == ProPurchaseFlowStatus.unavailable)
                const Text(
                  "Can't reach the store right now. Check your connection "
                  'and try again, or use Restore Purchases if you already '
                  'own Pro.',
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Not now'),
        ),
        if (!kIsDevIdDistribution) ...[
          TextButton(
            onPressed: busy ? null : notifier.restore,
            child: const Text('Restore Purchases'),
          ),
          FilledButton(
            onPressed: (busy || flow.product == null) ? null : notifier.buy,
            child: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_buyLabel(flow.product)),
          ),
        ],
      ],
    );
  }

  String _buyLabel(ProductDetails? product) =>
      product == null ? 'Buy Pro' : 'Buy Pro — ${product.price}';
}
