import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the user has purchased the Pro upgrade (Chessnut Move board sync,
/// play vs computer). Hardcoded `false` until in-app purchases are wired up;
/// swapping this provider's implementation for a real purchase/restore check
/// is the only change needed to unlock these features for paying users.
final proEntitlementProvider = Provider<bool>((ref) => false);
