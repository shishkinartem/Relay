#ifndef RELAY_OVERLAY_WINDOWS_H_
#define RELAY_OVERLAY_WINDOWS_H_

#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar.h>
#include <flutter/texture_registrar.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "recorder_types.h"

namespace relay {

// Placement request in logical points on the current display (spec 5).
struct OverlayPlacement {
  enum class Anchor { kTopCenter, kBottomCenter };

  bool absolute = false;
  double x = 0;
  double y = 0;
  double width = 0;
  double height = 0;
  double margin = 8;
  Anchor anchor = Anchor::kTopCenter;

  static OverlayPlacement FromMap(const flutter::EncodableMap& map);
};

// The application's always-on-top surfaces: the control strip and the camera
// preview (spec 6, 7).
//
// Each is a separate top-level window — never a child of a captured window —
// marked WDA_EXCLUDEFROMCAPTURE, and reported from excludedWindowIds. With a
// display source that marking is the only thing keeping them out of the file.
class OverlayWindows {
 public:
  using CommandHandler = std::function<void(const std::string& command)>;

  OverlayWindows();
  ~OverlayWindows();

  OverlayWindows(const OverlayWindows&) = delete;
  OverlayWindows& operator=(const OverlayWindows&) = delete;

  void SetMainWindow(HWND main_window);
  void SetCommandHandler(CommandHandler handler);

  bool ShowControlStrip(const OverlayPlacement& placement, std::string* error);
  void HideControlStrip();
  bool ShowCameraPreview(const OverlayPlacement& placement, std::string* error);
  void HideCameraPreview();

  void UpdateControlStrip(const flutter::EncodableMap& state);
  void UpdateCameraPreview(bool mirrored, bool matches_composited_pip,
                           double aspect_ratio);

  // A frame for the preview texture. Latest-wins single slot: the previous
  // frame is overwritten rather than queued.
  void PushCameraPreviewFrame(const uint8_t* bgra, uint32_t width, uint32_t height,
                              uint32_t stride);

  std::vector<std::string> ExcludedWindowIds() const;
  std::vector<HWND> ExcludedWindows() const;

  // The main panel is ordinary chrome, not an excluded overlay, so a display
  // recording would otherwise contain it.
  void SetMainWindowVisible(bool visible);

  void DisposeAll();

 private:
  // One overlay: a layered, non-activating, top-most host window with a
  // secondary Flutter engine parented into it.
  class OverlayWindow {
   public:
    OverlayWindow(std::string entrypoint, std::string channel_owner);
    ~OverlayWindow();

    bool Create(const RECT& frame, CommandHandler on_command,
                std::function<void(double, double)> on_content_size, bool wants_texture,
                std::string* error);
    void Destroy();
    void SetFrame(const RECT& frame);
    void Invoke(const std::string& method, const flutter::EncodableValue& arguments);
    HWND window() const { return window_; }
    int64_t texture_id() const { return texture_id_; }
    void PushFrame(const uint8_t* bgra, uint32_t width, uint32_t height, uint32_t stride);

   private:
    static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                       LPARAM lparam);
    LRESULT HandleMessage(HWND window, UINT message, WPARAM wparam, LPARAM lparam);
    void ApplyPendingContentSize();
    void HandleCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

    const std::string entrypoint_;
    const std::string channel_owner_;
    HWND window_ = nullptr;
    std::unique_ptr<flutter::FlutterViewController> controller_;
    std::unique_ptr<flutter::PluginRegistrar> registrar_;
    std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
    std::unique_ptr<flutter::TextureVariant> texture_;
    int64_t texture_id_ = -1;
    CommandHandler on_command_;
    std::function<void(double, double)> on_content_size_;

    // What the engine last measured itself at, waiting to be applied on a
    // later turn of the message loop. Touched only on the platform thread --
    // both the channel handler that fills it and the window procedure that
    // consumes it run there -- so it needs no lock of its own.
    double pending_width_ = 0;
    double pending_height_ = 0;

    // Single-slot preview buffer. The engine holds it between the copy callback
    // and the release callback, so the mutex spans exactly that window.
    std::mutex frame_mutex_;
    std::vector<uint8_t> frame_pixels_;
    FlutterDesktopPixelBuffer descriptor_{};
    uint32_t frame_width_ = 0;
    uint32_t frame_height_ = 0;
  };

  RECT ResolveFrame(const OverlayPlacement& placement) const;

  HWND main_window_ = nullptr;
  bool main_window_hidden_ = false;
  CommandHandler on_command_;
  // The size the strip last measured itself at, in logical points. The window
  // and its engine outlive a session, and the engine only reports a size when
  // its own content changes -- so on a second recording ShowControlStrip would
  // otherwise reset the window to the placement's requested size, narrower than
  // the strip, leaving Pause and Stop rendered outside it and unclickable.
  bool has_strip_content_size_ = false;
  double strip_content_width_ = 0;
  double strip_content_height_ = 0;
  std::unique_ptr<OverlayWindow> control_strip_;
  std::unique_ptr<OverlayWindow> camera_preview_;
  mutable std::mutex mutex_;
};

}  // namespace relay

#endif  // RELAY_OVERLAY_WINDOWS_H_
