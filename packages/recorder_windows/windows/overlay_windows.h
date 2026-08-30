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

  // The spot the user last left the strip at (spec 33.3). False when the strip
  // has never been moved, and the anchor above is the placement.
  //
  // position_x / position_y are the top-left as a fraction of the *usable* area
  // of the display named by position_display_id, which is spelled the way
  // capture_source_enumerator spells a display id. A fraction resolves against
  // any resolution; a point survives none of them.
  bool has_position = false;
  std::string position_display_id;
  double position_x = 0;
  double position_y = 0;

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

  // Where the control strip is now: the display holding its centre, and its
  // top-left as a fraction of that display's usable area (spec 33.3).
  //
  // False when no strip is on screen or its display cannot be named, which the
  // contract spells as a null reply. Deliberately not a zero position: failing
  // to read where the strip is is not the user having moved it back, and Dart
  // keeps whatever it had stored.
  bool ControlStripPosition(std::string* display_id, double* x, double* y) const;

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
    // `movable` is the control strip and nothing else: it is the only overlay
    // the user drags (spec 33.3), and the only one that re-clamps itself when
    // the usable area changes underneath it. The camera preview's frame is the
    // composited picture-in-picture's and is set by the compositor, so moving
    // or clamping it would break design `1p`'s promise that they are one
    // object.
    OverlayWindow(std::string entrypoint, std::string channel_owner, bool movable);
    ~OverlayWindow();

    bool Create(const RECT& frame, CommandHandler on_command,
                std::function<void(double, double)> on_content_size, bool wants_texture,
                std::string* error);
    void Destroy();
    void SetFrame(const RECT& frame);
    // Records where the strip is now as the spot to re-resolve it to when the
    // ground moves under it, as a fraction of the usable area (spec 33.3).
    //
    // Called only for something the *user* did — a drag ending, or the
    // placement a show was asked for. Deliberately not from a clamp or a
    // re-resolve: a usable area that shrinks and grows back again would
    // otherwise ratchet the strip a little further towards the near edge on
    // every taskbar change, and the fraction the session persists with it.
    void RememberPosition();
    // The same, for the fraction Dart restored: adopted verbatim rather than
    // re-derived from the pixels it landed on, because resolving a fraction
    // clamps it into the usable area and storing that back is the same ratchet.
    void RememberRestoredPosition(double x, double y);
    // The remembered fraction, or false when nothing has established one.
    bool RememberedPosition(double* x, double* y) const;
    void Invoke(const std::string& method, const flutter::EncodableValue& arguments);
    HWND window() const { return window_; }
    int64_t texture_id() const { return texture_id_; }
    void PushFrame(const uint8_t* bgra, uint32_t width, uint32_t height, uint32_t stride);

   private:
    static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                       LPARAM lparam);
    LRESULT HandleMessage(HWND window, UINT message, WPARAM wparam, LPARAM lparam);
    void ApplyPendingContentSize();
    // Hands the gesture to the operating system's own window-drag loop and
    // snaps when it ends (spec 33.3).
    void BeginMove();
    // The drag is over, however it ended: snap, clamp, remember.
    void FinishMove();
    // The usable area moved under a strip that has no fraction to re-resolve.
    // Keeps the position, changes only what it is measured against — and never
    // the remembered fraction, which a clamp does not get to decide.
    void ClampIntoWorkArea();
    // The ground moved under a placed strip: a display added, removed or
    // reshaped, or a taskbar shown, hidden or moved. The remembered fraction is
    // resolved again, so the strip stays proportionally where the user put it
    // and comes back to where it was when the usable area does (spec 33.7,
    // "Resolution or scale factor changes", "Dock or taskbar shown, hidden or
    // moved").
    void ReresolveRememberedFraction();
    void HandleCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

    const std::string entrypoint_;
    const std::string channel_owner_;
    const bool movable_;
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

    // A drag this window started and has not closed out yet. Set before the
    // move loop is entered and cleared by whichever of WM_EXITSIZEMOVE and the
    // move loop's return gets there first, so the snap happens exactly once.
    // Platform thread only, like the pending size above.
    bool move_pending_ = false;

    // False once this window has been destroyed, in a control block that
    // outlives the window itself.
    //
    // The move loop the drag hands the gesture to is modal: it pumps the
    // platform thread's message queue, which is exactly how Dart's calls to
    // this plugin are delivered. hideControlStrip — a fatal capture error, a
    // stop, a quit — or dispose can therefore run while that loop is on the
    // stack and free this object underneath it. The drag holds its own copy of
    // this flag, so the check after the loop reads memory its stack frame owns
    // rather than a member of a window that is no longer there.
    std::shared_ptr<bool> alive_ = std::make_shared<bool>(true);

    // The spot the user left the strip at, as a fraction of the usable area,
    // kept so a display change can re-resolve it — and re-resolve it again the
    // next time, from the same number rather than from the last clamp's answer.
    // Meaningless until something has established one: a window whose usable
    // area had no extent has no fraction, and re-resolving from a fabricated
    // 0, 0 would move the strip to the corner.
    bool has_ratio_ = false;
    double ratio_x_ = 0;
    double ratio_y_ = 0;

    // Single-slot preview buffer. The engine holds it between the copy callback
    // and the release callback, so the mutex spans exactly that window.
    std::mutex frame_mutex_;
    std::vector<uint8_t> frame_pixels_;
    FlutterDesktopPixelBuffer descriptor_{};
    uint32_t frame_width_ = 0;
    uint32_t frame_height_ = 0;
  };

  // `from_remembered_position`, when given, reports whether the frame came from
  // the placement's remembered fraction on the display it names, rather than
  // from the anchor on the current one. The caller needs it to seed the strip's
  // fraction from the number the user established instead of from the pixels
  // the clamp left it at.
  RECT ResolveFrame(const OverlayPlacement& placement,
                    bool* from_remembered_position = nullptr) const;

  // Seeds the strip's remembered fraction from the placement a show resolved.
  // Call with `mutex_` held, as both callers already do.
  void RememberStripPlacement(const OverlayPlacement& placement,
                              bool from_remembered_position);

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
