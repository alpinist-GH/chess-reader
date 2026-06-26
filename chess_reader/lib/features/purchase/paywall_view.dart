import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import 'billing_config.dart';
import 'purchase_controller.dart';

/// The paywall shown when a user has used their free conversions and tries to
/// convert another book. A one-time, non-consumable "Lifetime Unlock" — no
/// account, no subscription. On a successful purchase or restore the gated
/// conversion proceeds automatically (the conversion provider watches the
/// entitlement), so this just needs to flip the flag.
class PaywallView extends ConsumerStatefulWidget {
  const PaywallView({super.key});

  @override
  ConsumerState<PaywallView> createState() => _PaywallViewState();
}

class _PaywallViewState extends ConsumerState<PaywallView> {
  Package? _package;
  bool _loadingOffer = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadOffer();
  }

  Future<void> _loadOffer() async {
    final pkg =
        await ref.read(purchaseControllerProvider.notifier).lifetimePackage();
    if (!mounted) return;
    setState(() {
      _package = pkg;
      _loadingOffer = false;
    });
  }

  String get _priceLabel =>
      _package?.storeProduct.priceString ?? kFallbackPrice;

  Future<void> _buy() async {
    final package = _package;
    if (package == null) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final ok = await ref
          .read(purchaseControllerProvider.notifier)
          .purchaseLifetime(package);
      if (mounted && !ok) {
        messenger.showSnackBar(
            const SnackBar(content: Text('Purchase not completed.')));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Purchase failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await ref.read(purchaseControllerProvider.notifier).restore();
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      messenger.showSnackBar(
          const SnackBar(content: Text('No previous purchase found.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.workspace_premium,
                  size: 56, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text('Unlock unlimited conversions',
                  style: theme.textTheme.headlineSmall,
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Text(
                'You\'ve used your $kFreeConversionLimit free book '
                'conversions. Unlock the app once to convert as many books as '
                'you like — diagram recognition, OCR, and the reading view.',
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: (_busy || _loadingOffer) ? null : _buy,
                child: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Text('Unlock everything — $_priceLabel'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _busy ? null : _restore,
                child: const Text('Restore purchase'),
              ),
              const SizedBox(height: 8),
              Text(
                'One-time purchase. No subscription, no account required.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
