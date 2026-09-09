import 'package:chess_reader/core/entitlements/pro_entitlement.dart';
import 'package:chess_reader/core/entitlements/pro_trial.dart';
import 'package:chess_reader/core/entitlements/purchase_service.dart';
import 'package:chess_reader/core/settings/app_settings.dart';
import 'package:chess_reader/features/chessnut/presentation/chessnut_settings_section.dart';
import 'package:chess_reader/features/chessnut/presentation/chessnut_status_widget.dart';
import 'package:chess_reader/features/chessnut/state/chessnut_controller.dart';
import 'package:chess_reader/features/chessnut/transport/fake_chessnut_board.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_pro_store_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeChessnutBoard fakeBoard;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    fakeBoard = FakeChessnutBoard();
  });

  Widget createWidgetUnderTest(Widget child, {SharedPreferences? prefs}) {
    return ProviderScope(
      overrides: [
        if (prefs != null) sharedPrefsProvider.overrideWithValue(prefs),
        chessnutTransportProvider.overrideWithValue(fakeBoard),
      ],
      child: MaterialApp(
        home: Scaffold(body: child),
      ),
    );
  }

  group('ChessnutStatusWidget UI', () {
    testWidgets('renders connect button when completely disconnected', (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        createWidgetUnderTest(const ChessnutStatusWidget(), prefs: prefs),
      );

      expect(find.text('Connect Chessnut'), findsOneWidget);
    });

    testWidgets('shows Paused and Play button when connected in paused state', (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          chessnutTransportProvider.overrideWithValue(fakeBoard),
        ],
      );

      final controller = container.read(chessnutControllerProvider.notifier);
      await controller.connectToDevice(FakeChessnutBoard.fakeDeviceId);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: ChessnutStatusWidget()),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Paused'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.text('85%'), findsOneWidget); // Board battery

      await tester.pumpWidget(const SizedBox());
      await controller.disconnect();
      container.dispose();
    });

    testWidgets('shows mismatch banner and recovery buttons when in mismatch state', (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          chessnutTransportProvider.overrideWithValue(fakeBoard),
        ],
      );

      final controller = container.read(chessnutControllerProvider.notifier);
      await controller.connectToDevice(FakeChessnutBoard.fakeDeviceId);
      await controller.startOrResume();
      // Let the initial align target reach and settle on the board before
      // simulating a subsequent physical move.
      await tester.pump(const Duration(milliseconds: 400));

      // Put mismatched placement
      fakeBoard.simulatePhysicalMove('8/8/8/8/8/8/8/8');

      // Stability (350ms) + Grace (1.75s)
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 2000));

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: ChessnutStatusWidget()),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Position mismatch'), findsOneWidget);
      expect(find.text('Send app position'), findsOneWidget);
      expect(find.text('Clear red LEDs'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await controller.disconnect();
      container.dispose();
    });
  });

  group('ChessnutSettingsSection UI', () {
    testWidgets('shows a locked upsell card, not the connect controls, '
        'without Pro entitlement', (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          chessnutTransportProvider.overrideWithValue(fakeBoard),
          // kDebugMode unlocks Pro for on-device testing; simulate the
          // locked (release/no-purchase) case explicitly here.
          proEntitlementProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: ListView(children: const [ChessnutSettingsSection()]),
            ),
          ),
        ),
      );

      expect(find.text('Chessnut Move Board'), findsOneWidget);
      expect(find.text('Pro feature'), findsOneWidget);
      expect(find.text('Scan for boards'), findsNothing);
    });

    testWidgets('trial credits unlock the section without a purchase', (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          chessnutTransportProvider.overrideWithValue(fakeBoard),
          proStoreGatewayProvider.overrideWithValue(FakeProStoreGateway()),
          // Mirror release-build behavior (no kDebugMode shortcut) so this
          // exercises the trial-credit path itself, not the debug bypass.
          proEntitlementProvider.overrideWith(
            (ref) =>
                ref.watch(proPurchasedProvider) ||
                ref.watch(proTrialRemainingProvider) > 0,
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: ListView(children: const [ChessnutSettingsSection()]),
            ),
          ),
        ),
      );

      // Fresh install: 5 free credits, so the section is unlocked already.
      expect(container.read(proTrialRemainingProvider), kProTrialCredits);
      expect(find.text('Scan for boards'), findsOneWidget);
    });

    testWidgets('locks the section again once trial credits run out', (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          chessnutTransportProvider.overrideWithValue(fakeBoard),
          proStoreGatewayProvider.overrideWithValue(FakeProStoreGateway()),
          proEntitlementProvider.overrideWith(
            (ref) =>
                ref.watch(proPurchasedProvider) ||
                ref.watch(proTrialRemainingProvider) > 0,
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(proTrialRemainingProvider.notifier).state = 0;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: ListView(children: const [ChessnutSettingsSection()]),
            ),
          ),
        ),
      );

      expect(find.text('Pro feature'), findsOneWidget);
      expect(find.text('Scan for boards'), findsNothing);

      // Tapping through opens the real purchase dialog (not the old
      // test-code redeem flow).
      await tester.tap(find.widgetWithText(FilledButton, 'Upgrade to Pro'));
      await tester.pumpAndSettle();
      expect(find.text('Pro Unlock'), findsOneWidget);
    });

    testWidgets('renders Scan button and scan lists discovered devices', (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          chessnutTransportProvider.overrideWithValue(fakeBoard),
          proEntitlementProvider.overrideWithValue(true),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: ListView(children: const [ChessnutSettingsSection()]),
            ),
          ),
        ),
      );

      expect(find.text('Chessnut Move Board'), findsOneWidget);
      expect(find.text('Scan for boards'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Scan'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Scan'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text(FakeChessnutBoard.fakeDeviceName), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);

      final controller = container.read(chessnutControllerProvider.notifier);
      await controller.stopScan();
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    });
  });
}
