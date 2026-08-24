#include "capture_engine.h"

#include <d3d11_4.h>
#include <dxgi.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Foundation.Metadata.h>
#include <winrt/Windows.Graphics.h>

#include "capture_source_enumerator.h"

namespace relay {

namespace {

using winrt::Windows::Foundation::IInspectable;
using winrt::Windows::Foundation::Metadata::ApiInformation;
using winrt::Windows::Graphics::SizeInt32;
using winrt::Windows::Graphics::Capture::Direct3D11CaptureFrame;
using winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool;
using winrt::Windows::Graphics::Capture::GraphicsCaptureItem;
using winrt::Windows::Graphics::DirectX::DirectXPixelFormat;

// Two buffers is the documented minimum for a free-threaded pool and keeps the
// GPU-side backlog short: a frame we cannot compose in time is better dropped
// by the pool than queued (media-pipeline "Backpressure").
constexpr int32_t kFramePoolBuffers = 2;

constexpr wchar_t kSessionTypeName[] =
    L"Windows.Graphics.Capture.GraphicsCaptureSession";

}  // namespace

CaptureEngine::CaptureEngine() = default;

CaptureEngine::~CaptureEngine() {
  Stop();
}

bool CaptureEngine::EnsureDevice(std::string* error) {
  if (device_) {
    return true;
  }
  const D3D_FEATURE_LEVEL levels[] = {
      D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1,
      D3D_FEATURE_LEVEL_10_0};
  const UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
  HRESULT hr = ::D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags,
                                   levels, ARRAYSIZE(levels), D3D11_SDK_VERSION,
                                   device_.put(), nullptr, context_.put());
  if (FAILED(hr)) {
    device_ = nullptr;
    context_ = nullptr;
    hr = ::D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags, levels,
                             ARRAYSIZE(levels), D3D11_SDK_VERSION, device_.put(),
                             nullptr, context_.put());
  }
  if (FAILED(hr)) {
    *error = "Direct3D 11 device creation failed (" + HResultToString(hr) + ").";
    return false;
  }

  // The capture worker thread, the camera thread and the encoder thread all
  // reach this device; one owner, one immediate context, driver-level
  // serialization.
  const winrt::com_ptr<ID3D11Multithread> multithread =
      context_.try_as<ID3D11Multithread>();
  if (multithread) {
    multithread->SetMultithreadProtected(TRUE);
  }

  const winrt::com_ptr<IDXGIDevice> dxgi_device = device_.try_as<IDXGIDevice>();
  if (!dxgi_device) {
    *error = "The Direct3D device does not expose IDXGIDevice.";
    return false;
  }
  winrt::com_ptr<::IInspectable> inspectable;
  hr = ::CreateDirect3D11DeviceFromDXGIDevice(dxgi_device.get(), inspectable.put());
  if (FAILED(hr)) {
    *error = "CreateDirect3D11DeviceFromDXGIDevice failed (" + HResultToString(hr) + ").";
    return false;
  }
  winrt_device_ =
      inspectable.as<winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice>();
  return true;
}

bool CaptureEngine::Open(const std::string& source_id, CaptureSourceType type,
                         std::string* error) {
  if (!EnsureDevice(error)) {
    return false;
  }
  if (!winrt::Windows::Graphics::Capture::GraphicsCaptureSession::IsSupported()) {
    *error = "Windows.Graphics.Capture is not available on this system.";
    return false;
  }

  try {
    const auto interop =
        winrt::get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
    if (type == CaptureSourceType::kDisplay) {
      const HMONITOR monitor = ParseMonitorSourceId(source_id);
      if (monitor == nullptr) {
        *error = "The selected display is no longer connected.";
        return false;
      }
      winrt::check_hresult(interop->CreateForMonitor(
          monitor, winrt::guid_of<GraphicsCaptureItem>(), winrt::put_abi(item_)));
    } else {
      const HWND window = ParseWindowSourceId(source_id);
      if (window == nullptr || ::IsWindow(window) == FALSE) {
        *error = "The selected window has been closed.";
        return false;
      }
      winrt::check_hresult(interop->CreateForWindow(
          window, winrt::guid_of<GraphicsCaptureItem>(), winrt::put_abi(item_)));
    }
  } catch (const winrt::hresult_error& e) {
    *error = "Capture item creation failed (" + HResultToString(e.code()) + ").";
    return false;
  }

  if (!item_) {
    *error = "The capture source could not be opened.";
    return false;
  }
  const SizeInt32 size = item_.Size();
  content_width_.store(static_cast<uint32_t>(size.Width));
  content_height_.store(static_cast<uint32_t>(size.Height));
  return true;
}

bool CaptureEngine::Start(bool show_cursor, FrameHandler on_frame, ErrorHandler on_error,
                          std::string* error) {
  if (!item_) {
    *error = "Start called before a capture item was opened.";
    return false;
  }
  if (running_.load()) {
    return true;
  }
  {
    std::lock_guard<std::mutex> lock(handler_mutex_);
    on_frame_ = std::move(on_frame);
    on_error_ = std::move(on_error);
  }

  try {
    const SizeInt32 size = item_.Size();
    frame_pool_ = Direct3D11CaptureFramePool::CreateFreeThreaded(
        winrt_device_, DirectXPixelFormat::B8G8R8A8UIntNormalized, kFramePoolBuffers,
        size);
    session_ = frame_pool_.CreateCaptureSession(item_);

    cursor_configurable_ =
        ApiInformation::IsPropertyPresent(kSessionTypeName, L"IsCursorCaptureEnabled");
    if (cursor_configurable_) {
      session_.IsCursorCaptureEnabled(show_cursor);
    }
    if (ApiInformation::IsPropertyPresent(kSessionTypeName, L"IsBorderRequired")) {
      try {
        // Cosmetic only, and access-gated on some builds: never fatal.
        session_.IsBorderRequired(false);
      } catch (const winrt::hresult_error&) {
      }
    }

    frame_arrived_ = frame_pool_.FrameArrived(winrt::auto_revoke,
                                              {this, &CaptureEngine::OnFrameArrived});
    item_closed_ = item_.Closed(winrt::auto_revoke, {this, &CaptureEngine::OnItemClosed});
    running_.store(true);
    session_.StartCapture();
  } catch (const winrt::hresult_error& e) {
    running_.store(false);
    *error = "Capture session start failed (" + HResultToString(e.code()) + ").";
    Stop();
    return false;
  }
  return true;
}

void CaptureEngine::Stop() {
  running_.store(false);
  {
    std::lock_guard<std::mutex> lock(handler_mutex_);
    on_frame_ = nullptr;
    on_error_ = nullptr;
  }
  frame_arrived_.revoke();
  item_closed_.revoke();
  if (session_) {
    try {
      session_.Close();
    } catch (const winrt::hresult_error&) {
    }
    session_ = nullptr;
  }
  if (frame_pool_) {
    try {
      frame_pool_.Close();
    } catch (const winrt::hresult_error&) {
    }
    frame_pool_ = nullptr;
  }
  item_ = nullptr;
}

void CaptureEngine::OnFrameArrived(const Direct3D11CaptureFramePool& sender,
                                   const IInspectable& /*args*/) {
  if (!running_.load()) {
    return;
  }
  FrameHandler handler;
  {
    std::lock_guard<std::mutex> lock(handler_mutex_);
    handler = on_frame_;
  }

  bool content_resized = false;
  SizeInt32 new_size{};
  try {
    const Direct3D11CaptureFrame frame = sender.TryGetNextFrame();
    if (!frame) {
      return;
    }
    const SizeInt32 size = frame.ContentSize();
    if (static_cast<uint32_t>(size.Width) != content_width_.load() ||
        static_cast<uint32_t>(size.Height) != content_height_.load()) {
      content_resized = true;
      new_size = size;
      content_width_.store(static_cast<uint32_t>(size.Width));
      content_height_.store(static_cast<uint32_t>(size.Height));
    }

    const auto access =
        frame.Surface()
            .as<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
    winrt::com_ptr<ID3D11Texture2D> texture;
    winrt::check_hresult(
        access->GetInterface(__uuidof(ID3D11Texture2D), texture.put_void()));

    captured_frames_.fetch_add(1);
    if (handler) {
      Frame delivered;
      delivered.texture = texture.get();
      delivered.width = static_cast<uint32_t>(size.Width);
      delivered.height = static_cast<uint32_t>(size.Height);
      delivered.timestamp_100ns = frame.SystemRelativeTime().count();
      handler(delivered);
    }
  } catch (const winrt::hresult_error& e) {
    ReportError(RecorderErrorCode::kCaptureFailed, "A captured frame could not be read.",
                HResultToString(e.code()), true);
    return;
  }

  if (content_resized && new_size.Width > 0 && new_size.Height > 0) {
    // The source changed shape. Only the frame pool follows it; the encoder
    // canvas established at prepare time is fixed for the whole session and the
    // compositor letterboxes into it (fixedCanvasLetterbox, spec 4.4/30.3).
    try {
      sender.Recreate(winrt_device_, DirectXPixelFormat::B8G8R8A8UIntNormalized,
                      kFramePoolBuffers, new_size);
    } catch (const winrt::hresult_error& e) {
      ReportError(RecorderErrorCode::kCaptureFailed,
                  "The capture surface could not follow the source resize.",
                  HResultToString(e.code()), true);
    }
  }
}

void CaptureEngine::OnItemClosed(const GraphicsCaptureItem& /*sender*/,
                                 const IInspectable& /*args*/) {
  ReportError(RecorderErrorCode::kSourceClosed,
              "The capture source was closed or became unavailable.", "", true);
}

void CaptureEngine::ReportError(RecorderErrorCode code, std::string message,
                                std::string details, bool fatal) {
  ErrorHandler handler;
  {
    std::lock_guard<std::mutex> lock(handler_mutex_);
    handler = on_error_;
  }
  if (handler) {
    RecorderError error;
    error.code = code;
    error.message = std::move(message);
    error.details = std::move(details);
    error.fatal = fatal;
    handler(error);
  }
}

}  // namespace relay
