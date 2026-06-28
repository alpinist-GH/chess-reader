#ifndef RUNNER_NATIVE_OCR_H_
#define RUNNER_NATIVE_OCR_H_

#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>

#include <functional>
#include <memory>

// Backs the `chess_reader/native_ocr` method channel with the Windows on-device
// OCR engine (Windows.Media.Ocr), so the Dart NativeTextRecognizer works on
// Windows just like Apple Vision (iOS/macOS) and ML Kit (Android) — no bundled
// ONNX models needed.
//
// Recognition runs on a background thread (it blocks on a WinRT async op) and
// its result is marshaled back to the platform thread, where Flutter requires
// the method result to be completed, via a message-only window owned here. Keep
// the instance alive for the engine's lifetime.
class NativeOcr {
 public:
  static std::unique_ptr<NativeOcr> Register(flutter::BinaryMessenger* messenger);
  ~NativeOcr();

  NativeOcr(const NativeOcr&) = delete;
  NativeOcr& operator=(const NativeOcr&) = delete;

 private:
  NativeOcr() = default;

  void HandleRecognize(
      const flutter::EncodableValue* args,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  static LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND message_window_ = nullptr;
};

#endif  // RUNNER_NATIVE_OCR_H_
