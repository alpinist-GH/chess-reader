#include "native_ocr.h"

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Globalization.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Security.Cryptography.h>
#include <winrt/Windows.Storage.Streams.h>

#include <flutter/method_call.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <thread>
#include <vector>

namespace {

// Custom window message carrying a heap-allocated std::function* to run on the
// platform thread (see NativeOcr::WndProc).
constexpr UINT kRunOnPlatformThread = WM_APP + 1;
constexpr wchar_t kWindowClassName[] = L"ChessReaderNativeOcrMarshal";

// The standard codec decodes a Dart int as int32 when it fits, else int64.
bool ReadInt(const flutter::EncodableValue& value, int* out) {
  if (const auto* p = std::get_if<int32_t>(&value)) {
    *out = *p;
    return true;
  }
  if (const auto* p = std::get_if<int64_t>(&value)) {
    *out = static_cast<int>(*p);
    return true;
  }
  return false;
}

// Marshals |fn| onto the platform thread that owns |window|. Takes a copy on the
// heap; the WndProc runs and frees it. Drops the call if the window is gone
// (only at shutdown), leaking nothing observable.
void PostToPlatformThread(HWND window, std::function<void()> fn) {
  auto* heap = new std::function<void()>(std::move(fn));
  if (!window ||
      !PostMessageW(window, kRunOnPlatformThread, 0,
                    reinterpret_cast<LPARAM>(heap))) {
    delete heap;
  }
}

// Runs Windows on-device OCR over a BGRA8888 raster. Returns the recognized
// lines as `[{text, l, t, w, h}]` in source-pixel coordinates (top-left origin),
// matching the iOS/macOS/Android plugins. Returns an empty list on any failure
// (e.g. no OCR language pack installed), so the Dart side falls back exactly as
// if no text were found. Runs on a background thread.
flutter::EncodableList RecognizeBgra(const std::vector<uint8_t>& bgra, int width,
                                     int height) {
  flutter::EncodableList out;
  if (width <= 0 || height <= 0 ||
      bgra.size() < static_cast<size_t>(width) * height * 4) {
    return out;
  }

  winrt::init_apartment(winrt::apartment_type::multi_threaded);
  try {
    using namespace winrt::Windows::Graphics::Imaging;
    using namespace winrt::Windows::Media::Ocr;
    using namespace winrt::Windows::Security::Cryptography;

    auto engine = OcrEngine::TryCreateFromUserProfileLanguages();
    if (engine) {
      auto buffer = CryptographicBuffer::CreateFromByteArray(
          winrt::array_view<uint8_t const>(bgra.data(),
                                           bgra.data() + bgra.size()));
      auto bitmap = SoftwareBitmap::CreateCopyFromBuffer(
          buffer, BitmapPixelFormat::Bgra8, width, height,
          BitmapAlphaMode::Premultiplied);

      auto result = engine.RecognizeAsync(bitmap).get();
      for (auto const& line : result.Lines()) {
        // Windows gives per-word boxes but no line box; union the words.
        bool have = false;
        float min_x = 0, min_y = 0, max_x = 0, max_y = 0;
        for (auto const& word : line.Words()) {
          auto r = word.BoundingRect();
          const float x2 = r.X + r.Width;
          const float y2 = r.Y + r.Height;
          if (!have) {
            min_x = r.X;
            min_y = r.Y;
            max_x = x2;
            max_y = y2;
            have = true;
          } else {
            min_x = std::min(min_x, r.X);
            min_y = std::min(min_y, r.Y);
            max_x = std::max(max_x, x2);
            max_y = std::max(max_y, y2);
          }
        }
        if (!have) continue;

        flutter::EncodableMap m;
        m[flutter::EncodableValue("text")] =
            flutter::EncodableValue(winrt::to_string(line.Text()));
        m[flutter::EncodableValue("l")] =
            flutter::EncodableValue(static_cast<int>(std::lround(min_x)));
        m[flutter::EncodableValue("t")] =
            flutter::EncodableValue(static_cast<int>(std::lround(min_y)));
        m[flutter::EncodableValue("w")] =
            flutter::EncodableValue(static_cast<int>(std::lround(max_x - min_x)));
        m[flutter::EncodableValue("h")] =
            flutter::EncodableValue(static_cast<int>(std::lround(max_y - min_y)));
        out.push_back(flutter::EncodableValue(std::move(m)));
      }
    }
  } catch (...) {
    out.clear();
  }
  winrt::uninit_apartment();
  return out;
}

}  // namespace

std::unique_ptr<NativeOcr> NativeOcr::Register(
    flutter::BinaryMessenger* messenger) {
  auto self = std::unique_ptr<NativeOcr>(new NativeOcr());

  WNDCLASSW wc{};
  wc.lpfnWndProc = NativeOcr::WndProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = kWindowClassName;
  RegisterClassW(&wc);  // Harmless if already registered.
  self->message_window_ =
      CreateWindowExW(0, kWindowClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                      nullptr, wc.hInstance, nullptr);

  self->channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "chess_reader/native_ocr",
          &flutter::StandardMethodCodec::GetInstance());

  NativeOcr* raw = self.get();
  self->channel_->SetMethodCallHandler(
      [raw](const flutter::MethodCall<flutter::EncodableValue>& call,
            std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                result) {
        if (call.method_name() != "recognize") {
          result->NotImplemented();
          return;
        }
        raw->HandleRecognize(call.arguments(), std::move(result));
      });

  return self;
}

NativeOcr::~NativeOcr() {
  if (channel_) channel_->SetMethodCallHandler(nullptr);
  if (message_window_) DestroyWindow(message_window_);
}

void NativeOcr::HandleRecognize(
    const flutter::EncodableValue* args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::vector<uint8_t> bytes;
  int width = 0;
  int height = 0;
  if (const auto* map = std::get_if<flutter::EncodableMap>(args)) {
    if (auto it = map->find(flutter::EncodableValue("bytes")); it != map->end()) {
      if (const auto* p = std::get_if<std::vector<uint8_t>>(&it->second)) {
        bytes = *p;
      }
    }
    if (auto it = map->find(flutter::EncodableValue("width")); it != map->end()) {
      ReadInt(it->second, &width);
    }
    if (auto it = map->find(flutter::EncodableValue("height"));
        it != map->end()) {
      ReadInt(it->second, &height);
    }
  }

  if (bytes.empty() || width <= 0 || height <= 0) {
    result->Success(flutter::EncodableValue(flutter::EncodableList{}));
    return;
  }

  // Flutter requires the result to be completed on the platform thread, so do
  // the (blocking) recognition on a worker and marshal the reply back.
  std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> shared =
      std::move(result);
  const HWND window = message_window_;
  std::thread([window, bytes = std::move(bytes), width, height,
               shared]() mutable {
    flutter::EncodableList lines = RecognizeBgra(bytes, width, height);
    PostToPlatformThread(window, [shared, lines = std::move(lines)]() mutable {
      shared->Success(flutter::EncodableValue(std::move(lines)));
    });
  }).detach();
}

LRESULT CALLBACK NativeOcr::WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                    LPARAM lparam) {
  if (message == kRunOnPlatformThread) {
    auto* fn = reinterpret_cast<std::function<void()>*>(lparam);
    if (fn) {
      (*fn)();
      delete fn;
    }
    return 0;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}
