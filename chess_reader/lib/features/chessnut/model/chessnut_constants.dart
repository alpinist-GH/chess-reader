/// Constants for Chessnut Move BLE protocol and board configuration.
class ChessnutConstants {
  ChessnutConstants._();

  // BLE Service UUIDs
  static const String fenServiceUuid = '1b7e8261-2877-41c3-b46e-cf057c562023';
  static const String fenCharacteristicUuid = '1b7e8262-2877-41c3-b46e-cf057c562023';

  static const String commandServiceUuid = '1b7e8271-2877-41c3-b46e-cf057c562023';
  static const String commandWriteCharacteristicUuid = '1b7e8272-2877-41c3-b46e-cf057c562023';
  static const String commandNotifyCharacteristicUuid = '1b7e8273-2877-41c3-b46e-cf057c562023';

  // Device advertising name hint
  static const String deviceNamePrefix = 'Chessnut';
  static const String deviceModelName = 'Chessnut Move';

  // Packet lengths
  static const int fenReportLength = 38;
  static const int setTargetCommandLength = 35;
  static const int stopCommandLength = 35;
  static const int setLedsCommandLength = 34;
  static const int batteryQueryCommandLength = 3;
  static const int batteryResponseLength = 5;
  static const int pieceStatusQueryCommandLength = 3;
  static const int pieceStatusResponseLength = 139;

  // MTU requirements
  // 35-byte target command requires MTU >= 38
  // 38-byte FEN report requires MTU >= 41
  // 139-byte piece status report requires MTU >= 142
  static const int targetCommandMinMtu = 38;
  static const int fenReportMinMtu = 41;
  static const int pieceStatusReportMinMtu = 142;
  static const int desiredAndroidMtu = 247;

  // LED Colors
  static const int ledOff = 0;
  static const int ledRed = 1;
  static const int ledGreen = 2;
  static const int ledBlue = 3;

  // Maximum physical inventory per color
  static const int maxPawnsPerColor = 8;
  static const int maxRooksPerColor = 2;
  static const int maxKnightsPerColor = 2;
  static const int maxBishopsPerColor = 2;
  static const int maxQueensPerColor = 2;
  static const int maxKingsPerColor = 1;
  static const int maxPiecesPerColorOnBoard = 16;
  static const int totalNominalPieces = 34;

  // Timing constants
  static const Duration stabilityDuration = Duration(milliseconds: 350);
  static const Duration mismatchGraceDuration = Duration(milliseconds: 1750);
  static const Duration batteryPollInterval = Duration(minutes: 5);
}
