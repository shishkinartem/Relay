#ifndef RELAY_CAPTURE_ENGINE_H_
#define RELAY_CAPTURE_ENGINE_H_

// Minimum Windows version required by this implementation:
//
//   Windows 10, version 1903 (build 18362).
//
// Derivation:
//   * Windows.Graphics.Capture / GraphicsCaptureItem  -> 10.0.17134 (1803)
//   * Direct3D11CaptureFramePool::CreateFreeThreaded  -> 10.0.17763 (1809)
//   * GraphicsCaptureSession::IsCursorCaptureEnabled  -> 10.0.18362 (1903)
//     required because the cursor is part of the recording (spec 4.3) and the
//     property must be settable rather than assumed.
//   * SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE) -> 10.0.19041 (2004) for
//     the *capture-excluding* affinity used by the overlays; see
//     overlay_windows.h, which is the binding constraint in practice.
//   * GraphicsCaptureSession::IsBorderRequired         -> Windows 11 21H2 /
//     Windows 10 20348. Probed at runtime, never required.
//
// TECHNICAL_SPEC.md 30.9 ("minimum supported Windows version") is still open.
// The floor above is what the implemented API set demands; it is not a
// resolution of that open item and must not be treated as one.

#include <windows.h>

#include <d3d11.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>

#include <atomic>
#include <functional>
#include <mutex>
#include <string>

#include "recorder_types.h"

namespace relay {

// Owns the Windows.Graphics.Capture pipeline for one display or one window.
//
// Delivers frames on a Windows.Graphics.Capture worker thread (the frame pool
// is free-threaded). Handlers must not block on file or network I/O; the
// session hands work to its encoder thread instead (spec 22).
class CaptureEngine {
 public:
  struct Frame {
    ID3D11Texture2D* texture = nullptr;  // valid only for the callback's duration
    uint32_t width = 0;
    uint32_t height = 0;
    // Monotonic, 100 ns since boot (SystemRelativeTime); shares its base with
    // the WASAPI capture timestamps.
    int64_t timestamp_100ns = 0;
  };

  using FrameHandler = std::function<void(const Frame&)>;
  using ErrorHandler = std::function<void(const RecorderError&)>;

  CaptureEngine();
  ~CaptureEngine();

  CaptureEngine(const CaptureEngine&) = delete;
  CaptureEngine& operator=(const CaptureEngine&) = delete;

  // Creates the D3D11 device and resolves the capture item. Failure reasons are
  // returned in `error` and mapped to sourceUnavailable by the caller.
  bool Open(const std::string& source_id, CaptureSourceType type, std::string* error);

  bool Start(bool show_cursor, FrameHandler on_frame, ErrorHandler on_error,
             std::string* error);

  // Idempotent.
  void Stop();

  ID3D11Device* device() const { return device_.get(); }
  ID3D11DeviceContext* context() const { return context_.get(); }

  uint32_t content_width() const { return content_width_.load(); }
  uint32_t content_height() const { return content_height_.load(); }
  uint64_t captured_frames() const { return captured_frames_.load(); }
  bool cursor_capture_configurable() const { return cursor_configurable_; }

 private:
  bool EnsureDevice(std::string* error);
  void OnFrameArrived(
      const winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool& sender,
      const winrt::Windows::Foundation::IInspectable& args);
  void OnItemClosed(const winrt::Windows::Graphics::Capture::GraphicsCaptureItem& sender,
                    const winrt::Windows::Foundation::IInspectable& args);
  void ReportError(RecorderErrorCode code, std::string message, std::string details,
                   bool fatal);

  winrt::com_ptr<ID3D11Device> device_;
  winrt::com_ptr<ID3D11DeviceContext> context_;
  winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice winrt_device_{nullptr};
  winrt::Windows::Graphics::Capture::GraphicsCaptureItem item_{nullptr};
  winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool frame_pool_{nullptr};
  winrt::Windows::Graphics::Capture::GraphicsCaptureSession session_{nullptr};
  winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool::FrameArrived_revoker
      frame_arrived_;
  winrt::Windows::Graphics::Capture::GraphicsCaptureItem::Closed_revoker item_closed_;

  std::mutex handler_mutex_;
  FrameHandler on_frame_;
  ErrorHandler on_error_;

  std::atomic<uint32_t> content_width_{0};
  std::atomic<uint32_t> content_height_{0};
  std::atomic<uint64_t> captured_frames_{0};
  std::atomic<bool> running_{false};
  bool cursor_configurable_ = false;
};

}  // namespace relay

#endif  // RELAY_CAPTURE_ENGINE_H_
