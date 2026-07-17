import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/settings/app_settings.dart';
import 'features/engine/state/analysis_provider.dart';
import 'features/library/about.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerStockfishLicense();
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
  );

  // On desktop, closing the window/quitting asks Dart before the native side
  // tears down the Flutter engine. Without a response here, the engine
  // shutdown proceeds while Stockfish is still blocked reading its stdin
  // pipe, which hangs the whole app until it's force-killed. Stop the
  // engine first so its process actually exits.
  AppLifecycleListener(
    onExitRequested: () async {
      await container.read(analysisProvider.notifier).stopEngine();
      return AppExitResponse.exit;
    },
  );

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const ChessReaderApp(),
    ),
  );
}
