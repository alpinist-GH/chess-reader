import 'dart:async';

import 'package:flutter/services.dart';

/// The Chessnut Evo's on-device board service, reached through the Android
/// plugin in `EvoBoardService.kt`.
abstract class EvoBoardPort {
  /// Whether the Evo board service is installed on this device.
  Future<bool> isAvailable();
  Future<void> connect();
  Future<void> disconnect();
  Future<String?> getFen();

  /// [on] holds 64 on/off bytes and [rgb] 192 colour bytes, in service order.
  Future<void> setLed(Uint8List on, Uint8List rgb);

  /// `{event: fen, fen: ...}` and `{event: disconnected}` messages.
  Stream<Map<Object?, Object?>> get events;
}

class EvoBoardChannel implements EvoBoardPort {
  static const deviceId = 'chessnut-evo-service';
  static const _methods = MethodChannel('chess_reader/evo_board');
  static const _events = EventChannel('chess_reader/evo_board/events');

  Stream<Map<Object?, Object?>>? _stream;

  @override
  Future<bool> isAvailable() async {
    try {
      return await _methods.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> connect() => _methods.invokeMethod<void>('connect');

  @override
  Future<void> disconnect() => _methods.invokeMethod<void>('disconnect');

  @override
  Future<String?> getFen() => _methods.invokeMethod<String>('getFen');

  @override
  Future<void> setLed(Uint8List on, Uint8List rgb) =>
      _methods.invokeMethod<void>('setLed', {'on': on, 'rgb': rgb});

  @override
  Stream<Map<Object?, Object?>> get events => _stream ??= _events
      .receiveBroadcastStream()
      .where((event) => event is Map)
      .map((event) => event as Map<Object?, Object?>);
}
