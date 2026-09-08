import 'package:chess_reader/core/settings/app_settings.dart';
import 'package:chess_reader/features/chessnut/presentation/chessnut_settings_section.dart';
import 'package:chess_reader/features/chessnut/presentation/chessnut_status_widget.dart';
import 'package:chess_reader/features/chessnut/state/chessnut_controller.dart';
import 'package:chess_reader/features/chessnut/transport/fake_chessnut_board.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    testWidgets('renders Scan button and scan lists discovered devices', (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          chessnutTransportProvider.overrideWithValue(fakeBoard),
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
