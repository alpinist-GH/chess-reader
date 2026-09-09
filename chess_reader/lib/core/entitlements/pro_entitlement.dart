import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the user has purchased the Pro upgrade (Chessnut Move board sync,
/// play vs computer). Unlocked in debug builds so Pro features stay testable
/// on-device; hardcoded locked otherwise until in-app purchases are wired
/// up. Swapping the `kReleaseMode`/`kProfileMode` branch below for a real
/// purchase/restore check is the only change needed to unlock these
/// features for paying users — release and TestFlight/profile builds stay
/// locked until then.
final proEntitlementProvider = Provider<bool>((ref) => kDebugMode);
