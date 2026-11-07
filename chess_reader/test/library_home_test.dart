import 'package:chess_reader/core/persistence/library_store.dart';
import 'package:chess_reader/core/settings/app_settings.dart';
import 'package:chess_reader/features/library/library_home.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final hasRecentBooks in [false, true]) {
    testWidgets('fits a short pane when recent books: $hasRecentBooks', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 240);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      if (hasRecentBooks) {
        container.read(libraryStoreProvider.notifier).recordOpened('/a.pdf');
      }
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: LibraryHome())),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }
}
