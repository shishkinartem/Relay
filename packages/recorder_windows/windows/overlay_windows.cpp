#include "overlay_windows.h"

#include <flutter/dart_project.h>
#include <flutter/standard_method_codec.h>
#include <shellscalingapi.h>

#include <algorithm>
#include <optional>
#include <sstream>
#include <variant>

namespace relay {

namespace {

constexpr wchar_t kOverlayClassName[] = L"RelayOverlayHostWindow";
// Applies a measured content size on a later turn of the message loop. See
// OverlayWindow::HandleCall for why it cannot be applied where it arrives.
constexpr UINT kApplyContentSizeMessage = WM_APP + 0x51;
constexpr char kOverlayViewChannel[] = "relay/overlay/view";
// The overlay engines run these Dart entrypoints (contract: relay/overlay/view).
constexpr char kControlStripEntrypoint[] = "controlStripMain";
constexpr char kCameraPreviewEntrypoint[] = "cameraPreviewMain";

double MonitorScale(HMONITOR monitor) {
  UINT dpi_x = USER_DEFAULT_SCREEN_DPI;
  UINT dpi_y = USER_DEFAULT_SCREEN_DPI;
  if (FAILED(::GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y)) ||
      dpi_x == 0) {
    return 1.0;
  }
  return static_cast<double>(dpi_x) / USER_DEFAULT_SCREEN_DPI;
}

const flutter::EncodableValue* Find(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(flutter::EncodableValue(std::string(key)));
  return it == map.end() ? nullptr : &it->second;
}

double DoubleAt(const flutter::EncodableMap& map, const char* key, double fallback) {
  const flutter::EncodableValue* value = Find(map, key);
  if (value == nullptr) {
    return fallback;
  }
  if (const auto* number = std::get_if<double>(value)) {
    return *number;
  }
  if (const auto* integer = std::get_if<int32_t>(value)) {
    return static_cast<double>(*integer);
  }
  if (const auto* big = std::get_if<int64_t>(value)) {
    return static_cast<double>(*big);
  }
  return fallback;
}

std::string StringAt(const flutter::EncodableMap& map, const char* key) {
  const flutter::EncodableValue* value = Find(map, key);
  if (value == nullptr) {
    return std::string();
  }
  const auto* text = std::get_if<std::string>(value);
  return text == nullptr ? std::string() : *text;
}

}  // namespace

OverlayPlacement OverlayPlacement::FromMap(const flutter::EncodableMap& map) {
  OverlayPlacement placement;
  placement.margin = DoubleAt(map, "margin", 8);
  const flutter::EncodableValue* frame = Find(map, "frame");
  if (frame != nullptr) {
    if (const auto* rect = std::get_if<flutter::EncodableMap>(frame)) {
      placement.absolute = true;
      placement.x = DoubleAt(*rect, "x", 0);
      placement.y = DoubleAt(*rect, "y", 0);
      placement.width = DoubleAt(*rect, "width", 0);
      placement.height = DoubleAt(*rect, "height", 0);
      return placement;
    }
  }
  placement.width = DoubleAt(map, "width", 0);
  placement.height = DoubleAt(map, "height", 0);
  placement.anchor = StringAt(map, "anchor") == "bottomCenter"
                         ? OverlayPlacement::Anchor::kBottomCenter
                         : OverlayPlacement::Anchor::kTopCenter;
  return placement;
}

OverlayWindows::OverlayWindows() = default;

OverlayWindows::~OverlayWindows() {
  DisposeAll();
}

void OverlayWindows::SetMainWindow(HWND main_window) {
  std::lock_guard<std::mutex> lock(mutex_);
  main_window_ = main_window;
}

void OverlayWindows::SetCommandHandler(CommandHandler handler) {
  std::lock_guard<std::mutex> lock(mutex_);
  on_command_ = std::move(handler);
}

RECT OverlayWindows::ResolveFrame(const OverlayPlacement& placement) const {
  const HMONITOR monitor =
      main_window_ != nullptr
          ? ::MonitorFromWindow(main_window_, MONITOR_DEFAULTTONEAREST)
          : ::MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  ::GetMonitorInfoW(monitor, &info);
  const double scale = MonitorScale(monitor);

  const LONG width = static_cast<LONG>(placement.width * scale + 0.5);
  const LONG height = static_cast<LONG>(placement.height * scale + 0.5);
  RECT frame{};
  if (placement.absolute) {
    frame.left = info.rcMonitor.left + static_cast<LONG>(placement.x * scale + 0.5);
    frame.top = info.rcMonitor.top + static_cast<LONG>(placement.y * scale + 0.5);
  } else {
    const LONG work_width = info.rcWork.right - info.rcWork.left;
    const LONG margin = static_cast<LONG>(placement.margin * scale + 0.5);
    frame.left = info.rcWork.left + (work_width - width) / 2;
    frame.top = placement.anchor == OverlayPlacement::Anchor::kBottomCenter
                    ? info.rcWork.bottom - margin - height
                    : info.rcWork.top + margin;
  }
  frame.right = frame.left + width;
  frame.bottom = frame.top + height;
  return frame;
}

bool OverlayWindows::ShowControlStrip(const OverlayPlacement& placement,
                                      std::string* error) {
  std::lock_guard<std::mutex> lock(mutex_);
  OverlayPlacement resolved = placement;
  if (has_strip_content_size_) {
    resolved.width = strip_content_width_;
    resolved.height = strip_content_height_;
  }
  const RECT frame = ResolveFrame(resolved);
  if (control_strip_) {
    control_strip_->SetFrame(frame);
    return true;
  }
  auto window = std::make_unique<OverlayWindow>(kControlStripEntrypoint, "control_strip");
  const CommandHandler handler = on_command_;
  if (!window->Create(
          frame, [handler](const std::string& command) {
            if (handler) {
              handler(command);
            }
          },
          // Remembers the measurement and nothing else. The window is resized
          // by the window itself, on a later turn of the message loop; doing
          // it here would mean resizing a Flutter-hosting window from inside
          // that engine's own channel handler, and taking this lock again
          // underneath the call that installed this callback.
          [this](double width, double height) {
            if (width <= 1 || height <= 1) {
              return;
            }
            std::lock_guard<std::mutex> inner(mutex_);
            has_strip_content_size_ = true;
            strip_content_width_ = width;
            strip_content_height_ = height;
          },
          false, error)) {
    return false;
  }
  control_strip_ = std::move(window);
  return true;
}

void OverlayWindows::HideControlStrip() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (control_strip_) {
    control_strip_->Destroy();
    control_strip_.reset();
  }
}

bool OverlayWindows::ShowCameraPreview(const OverlayPlacement& placement,
                                       std::string* error) {
  std::lock_guard<std::mutex> lock(mutex_);
  const RECT frame = ResolveFrame(placement);
  if (camera_preview_) {
    camera_preview_->SetFrame(frame);
    return true;
  }
  auto window =
      std::make_unique<OverlayWindow>(kCameraPreviewEntrypoint, "camera_preview");
  const CommandHandler handler = on_command_;
  if (!window->Create(
          frame, [handler](const std::string& command) {
            if (handler) {
              handler(command);
            }
          },
          [](double, double) {}, true, error)) {
    return false;
  }
  camera_preview_ = std::move(window);
  return true;
}

void OverlayWindows::HideCameraPreview() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (camera_preview_) {
    camera_preview_->Destroy();
    camera_preview_.reset();
  }
}

void OverlayWindows::UpdateControlStrip(const flutter::EncodableMap& state) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (control_strip_) {
    control_strip_->Invoke("controlStripState", flutter::EncodableValue(state));
  }
}

void OverlayWindows::UpdateCameraPreview(bool mirrored, bool matches_composited_pip,
                                         double aspect_ratio) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!camera_preview_) {
    return;
  }
  flutter::EncodableMap state;
  // The texture id belongs to the preview engine's own registry and is
  // meaningful only inside that engine.
  state[flutter::EncodableValue("textureId")] =
      flutter::EncodableValue(camera_preview_->texture_id());
  state[flutter::EncodableValue("mirrored")] = flutter::EncodableValue(mirrored);
  state[flutter::EncodableValue("matchesCompositedPip")] =
      flutter::EncodableValue(matches_composited_pip);
  state[flutter::EncodableValue("aspectRatio")] = flutter::EncodableValue(aspect_ratio);
  camera_preview_->Invoke("cameraPreviewState", flutter::EncodableValue(state));
}

void OverlayWindows::PushCameraPreviewFrame(const uint8_t* bgra, uint32_t width,
                                            uint32_t height, uint32_t stride) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (camera_preview_) {
    camera_preview_->PushFrame(bgra, width, height, stride);
  }
}

std::vector<HWND> OverlayWindows::ExcludedWindows() const {
  std::lock_guard<std::mutex> lock(mutex_);
  std::vector<HWND> windows;
  if (control_strip_ && control_strip_->window() != nullptr) {
    windows.push_back(control_strip_->window());
  }
  if (camera_preview_ && camera_preview_->window() != nullptr) {
    windows.push_back(camera_preview_->window());
  }
  return windows;
}

std::vector<std::string> OverlayWindows::ExcludedWindowIds() const {
  std::vector<std::string> ids;
  for (const HWND window : ExcludedWindows()) {
    std::ostringstream stream;
    stream << reinterpret_cast<uintptr_t>(window);
    ids.push_back(stream.str());
  }
  return ids;
}

void OverlayWindows::SetMainWindowVisible(bool visible) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (main_window_ == nullptr) {
    return;
  }
  if (visible) {
    if (main_window_hidden_) {
      ::ShowWindow(main_window_, SW_SHOW);
      main_window_hidden_ = false;
    }
    return;
  }
  if (!main_window_hidden_) {
    ::ShowWindow(main_window_, SW_HIDE);
    main_window_hidden_ = true;
  }
}

void OverlayWindows::DisposeAll() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (control_strip_) {
    control_strip_->Destroy();
    control_strip_.reset();
  }
  if (camera_preview_) {
    camera_preview_->Destroy();
    camera_preview_.reset();
  }
  if (main_window_hidden_ && main_window_ != nullptr) {
    ::ShowWindow(main_window_, SW_SHOW);
    main_window_hidden_ = false;
  }
}

OverlayWindows::OverlayWindow::OverlayWindow(std::string entrypoint,
                                             std::string channel_owner)
    : entrypoint_(std::move(entrypoint)), channel_owner_(std::move(channel_owner)) {}

OverlayWindows::OverlayWindow::~OverlayWindow() {
  Destroy();
}

bool OverlayWindows::OverlayWindow::Create(
    const RECT& frame, CommandHandler on_command,
    std::function<void(double, double)> on_content_size, bool wants_texture,
    std::string* error) {
  on_command_ = std::move(on_command);
  on_content_size_ = std::move(on_content_size);

  const HINSTANCE instance = ::GetModuleHandleW(nullptr);
  WNDCLASSEXW window_class{};
  window_class.cbSize = sizeof(window_class);
  window_class.lpfnWndProc = OverlayWindow::WindowProc;
  window_class.hInstance = instance;
  window_class.lpszClassName = kOverlayClassName;
  window_class.hCursor = ::LoadCursorW(nullptr, IDC_ARROW);
  ::RegisterClassExW(&window_class);

  const int width = (std::max)(1L, frame.right - frame.left);
  const int height = (std::max)(1L, frame.bottom - frame.top);
  // Deliberately not WS_EX_LAYERED. The strip is fully opaque, so a layered
  // window would buy nothing -- the only alpha it can offer with a child
  // render surface is per-window, and the value was 255 -- while putting the
  // hosted Flutter view, which is a child HWND drawing through ANGLE, inside a
  // window whose composition path is the one case where child HWNDs are known
  // not to be composed reliably. An always-on-top window that renders nothing
  // is indistinguishable from an overlay that failed to appear.
  window_ = ::CreateWindowExW(
      WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST, kOverlayClassName, L"",
      WS_POPUP, frame.left, frame.top, width, height, nullptr, nullptr, instance,
      this);
  if (window_ == nullptr) {
    *error = "The overlay window could not be created.";
    return false;
  }

  // Before anything is shown and long before capture starts: this is the only
  // mechanism keeping the overlay out of a display recording (spec 6).
  if (::SetWindowDisplayAffinity(window_, WDA_EXCLUDEFROMCAPTURE) == FALSE) {
    ::DestroyWindow(window_);
    window_ = nullptr;
    *error =
        "This system cannot exclude the recorder overlay from capture, so the "
        "overlay would be recorded.";
    return false;
  }

  flutter::DartProject project(L"data");
  project.set_dart_entrypoint(entrypoint_);
  controller_ = std::make_unique<flutter::FlutterViewController>(width, height, project);
  if (controller_->view() == nullptr) {
    Destroy();
    *error = "The overlay engine could not be started.";
    return false;
  }
  const HWND view = controller_->view()->GetNativeWindow();
  ::SetParent(view, window_);
  ::MoveWindow(view, 0, 0, width, height, TRUE);

  registrar_ = std::make_unique<flutter::PluginRegistrar>(
      controller_->engine()->GetRegistrarForPlugin("relay.overlay." + channel_owner_));
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar_->messenger(), kOverlayViewChannel,
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        HandleCall(call, std::move(result));
      });

  if (wants_texture) {
    texture_ = std::make_unique<flutter::TextureVariant>(flutter::PixelBufferTexture(
        [this](size_t /*width*/, size_t /*height*/) -> const FlutterDesktopPixelBuffer* {
          frame_mutex_.lock();
          if (frame_pixels_.empty()) {
            frame_mutex_.unlock();
            return nullptr;
          }
          descriptor_.buffer = frame_pixels_.data();
          descriptor_.width = frame_width_;
          descriptor_.height = frame_height_;
          descriptor_.release_context = this;
          descriptor_.release_callback = [](void* context) {
            static_cast<OverlayWindow*>(context)->frame_mutex_.unlock();
          };
          return &descriptor_;
        }));
    texture_id_ = registrar_->texture_registrar()->RegisterTexture(texture_.get());
  }

  ::ShowWindow(window_, SW_SHOWNOACTIVATE);
  ::SetWindowPos(window_, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  return true;
}

void OverlayWindows::OverlayWindow::Destroy() {
  if (texture_id_ >= 0 && registrar_ != nullptr) {
    registrar_->texture_registrar()->UnregisterTexture(texture_id_);
    texture_id_ = -1;
  }
  texture_ = nullptr;
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
    channel_ = nullptr;
  }
  registrar_ = nullptr;
  controller_ = nullptr;
  if (window_ != nullptr) {
    ::SetWindowLongPtrW(window_, GWLP_USERDATA, 0);
    ::DestroyWindow(window_);
    window_ = nullptr;
  }
}

void OverlayWindows::OverlayWindow::SetFrame(const RECT& frame) {
  if (window_ == nullptr) {
    return;
  }
  const int width = (std::max)(1L, frame.right - frame.left);
  const int height = (std::max)(1L, frame.bottom - frame.top);
  ::SetWindowPos(window_, HWND_TOPMOST, frame.left, frame.top, width, height,
                 SWP_NOACTIVATE);
  if (controller_ != nullptr && controller_->view() != nullptr) {
    ::MoveWindow(controller_->view()->GetNativeWindow(), 0, 0, width, height, TRUE);
  }
}

// Grows the window about its own top-left, to the size the engine measured.
//
// The measurement is in logical points and the frame is in physical pixels, so
// it is scaled by the monitor the window is actually on rather than the one the
// placement was resolved against.
void OverlayWindows::OverlayWindow::ApplyPendingContentSize() {
  if (window_ == nullptr || pending_width_ <= 1 || pending_height_ <= 1) {
    return;
  }
  const double width = pending_width_;
  const double height = pending_height_;
  pending_width_ = 0;
  pending_height_ = 0;

  RECT current{};
  ::GetWindowRect(window_, &current);
  const double scale = MonitorScale(::MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST));
  RECT frame = current;
  frame.right = frame.left + static_cast<LONG>(width * scale + 0.5);
  frame.bottom = frame.top + static_cast<LONG>(height * scale + 0.5);
  if (frame.right == current.right && frame.bottom == current.bottom) {
    return;
  }
  SetFrame(frame);
  if (on_content_size_) {
    on_content_size_(width, height);
  }
}

void OverlayWindows::OverlayWindow::Invoke(const std::string& method,
                                           const flutter::EncodableValue& arguments) {
  if (channel_) {
    channel_->InvokeMethod(method,
                           std::make_unique<flutter::EncodableValue>(arguments));
  }
}

void OverlayWindows::OverlayWindow::PushFrame(const uint8_t* bgra, uint32_t width,
                                              uint32_t height, uint32_t stride) {
  if (bgra == nullptr || width == 0 || height == 0 || registrar_ == nullptr ||
      texture_id_ < 0) {
    return;
  }
  {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    const size_t row_bytes = static_cast<size_t>(width) * 4;
    frame_pixels_.resize(row_bytes * height);
    // The engine uploads a pixel-buffer texture as RGBA8888
    // (external_texture_pixelbuffer.cc), while the camera path is BGRA
    // throughout, so the channels are swapped exactly here — once, on the
    // small preview image, and never on the encoded frame.
    for (uint32_t row = 0; row < height; ++row) {
      const uint8_t* source = bgra + static_cast<size_t>(row) * stride;
      uint8_t* destination = frame_pixels_.data() + row * row_bytes;
      for (uint32_t column = 0; column < width; ++column) {
        destination[column * 4 + 0] = source[column * 4 + 2];
        destination[column * 4 + 1] = source[column * 4 + 1];
        destination[column * 4 + 2] = source[column * 4 + 0];
        destination[column * 4 + 3] = source[column * 4 + 3];
      }
    }
    frame_width_ = width;
    frame_height_ = height;
  }
  registrar_->texture_registrar()->MarkTextureFrameAvailable(texture_id_);
}

void OverlayWindows::OverlayWindow::HandleCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
  if (call.method_name() == "command") {
    if (arguments != nullptr && on_command_) {
      on_command_(StringAt(*arguments, "command"));
    }
    result->Success();
    return;
  }
  if (call.method_name() == "contentSize") {
    // Recorded and applied later, never here. Resizing a window that hosts a
    // Flutter view blocks the calling thread until that engine presents a
    // frame at the new size, and on Windows the engine's Dart task runner *is*
    // the platform thread -- the same thread this handler is running on. The
    // resize would be waiting for a frame that cannot be built until the
    // resize returns. Posting it hands the work to the next turn of the
    // message loop, after this handler is off the stack, and collapses a burst
    // of measurements into one resize.
    if (arguments != nullptr && window_ != nullptr) {
      pending_width_ = DoubleAt(*arguments, "width", 0);
      pending_height_ = DoubleAt(*arguments, "height", 0);
      ::PostMessageW(window_, kApplyContentSizeMessage, 0, 0);
    }
    result->Success();
    return;
  }
  result->NotImplemented();
}

LRESULT CALLBACK OverlayWindows::OverlayWindow::WindowProc(HWND window, UINT message,
                                                           WPARAM wparam,
                                                           LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    ::SetWindowLongPtrW(window, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  } else if (auto* self = reinterpret_cast<OverlayWindow*>(
                 ::GetWindowLongPtrW(window, GWLP_USERDATA))) {
    return self->HandleMessage(window, message, wparam, lparam);
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

LRESULT OverlayWindows::OverlayWindow::HandleMessage(HWND window, UINT message,
                                                     WPARAM wparam, LPARAM lparam) {
  if (controller_ != nullptr) {
    // Give the hosted engine first refusal, exactly as the runner's top-level
    // window does: DPI changes, IME and accessibility depend on it.
    const std::optional<LRESULT> handled =
        controller_->HandleTopLevelWindowProc(window, message, wparam, lparam);
    if (handled.has_value()) {
      return *handled;
    }
  }
  switch (message) {
    case kApplyContentSizeMessage: {
      ApplyPendingContentSize();
      return 0;
    }
    case WM_SIZE: {
      if (controller_ != nullptr && controller_->view() != nullptr) {
        RECT client{};
        ::GetClientRect(window, &client);
        ::MoveWindow(controller_->view()->GetNativeWindow(), 0, 0,
                     client.right - client.left, client.bottom - client.top, TRUE);
      }
      return 0;
    }
    case WM_MOUSEACTIVATE:
      // Never steal focus from whatever is being recorded.
      return MA_NOACTIVATE;
    case WM_DESTROY:
      window_ = nullptr;
      return 0;
    default:
      break;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

}  // namespace relay
