#ifndef RELAY_OVERLAY_WINDOWS_H_
#define RELAY_OVERLAY_WINDOWS_H_

#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar.h>
#include <flutter/texture_registrar.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
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

// Everything the camera preview needs to be the picture-in-picture rather than
// a window that merely looks like it (design 1p, spec 33.5).
//
// In display mode the preview *is* the tile: it is dragged, it is cropped and
// it is masked, and every one of those is resolved by the same recorder_types
// arithmetic the compositor draws with. In window mode it is a separate
// captioned object (design 1e) and none of this applies — `is_tile` is what says
// which.
struct CameraPreviewGeometry {
  bool is_tile = false;
  // Where the encoder canvas lands on screen, in physical pixels: the recorded
  // display's own rectangle. A drag is measured against this and nothing else,
  // so the tile stays on the display being recorded however far the pointer
  // travels.
  RECT canvas_bounds{};
  double canvas_width = 0;
  double canvas_height = 0;
  CameraOverlayConfig camera;
  // The camera's own frame size, 0 while nothing has been captured.
  uint32_t frame_width = 0;
  uint32_t frame_height = 0;
};

// The application's always-on-top surfaces: the control strip, the camera
// preview and the input menu (spec 6, 7, 33.4).
//
// Each is a separate top-level window — never a child of a captured window —
// marked WDA_EXCLUDEFROMCAPTURE, and reported from excludedWindowIds. With a
// display source that marking is the only thing keeping them out of the file.
class OverlayWindows {
 public:
  // A command raised by an overlay, and where in that overlay's own window it
  // came from. The x is present for the chevrons and absent for everything
  // else: only Flutter knows where a control ended up, and the input menu has
  // to open under the one that was pressed (spec 33.4).
  using CommandHandler = std::function<void(const std::string& command,
                                            std::optional<double> anchor_x)>;
  // A choice was made in the input menu: the arguments map exactly as the menu
  // engine sent it (spec 33.4).
  //
  // Forwarded whole rather than unpacked, because none of what a choice *means*
  // is this layer's business. The shapes it arrives in — a device row, a shape
  // preset, a corner, `Reset position` — differ only in which keys they carry,
  // and passing the map through is what let the camera sheet's three extra
  // answers reach the application without the host learning a single field.
  using MenuSelectionHandler =
      std::function<void(const flutter::EncodableMap& choice)>;
  // The menu asked to be closed — Esc, a click outside, the strip moving, a
  // display change, or a choice just made.
  //
  // Deliberately not "close it here": the request arrives on the menu engine's
  // own channel, or from inside the menu window's procedure, and destroying a
  // Flutter engine from inside its own callback frees the object whose stack is
  // running. The plugin answers this by posting HideInputMenu to a later turn of
  // the platform thread's loop, which is where every other deferred teardown
  // already goes.
  //
  // `host_initiated` separates a close the application has to be *told* about
  // from one it already knows about. The application draws the chevron, so a
  // menu the host closed behind its back would leave the next press on that
  // chevron read as the toggle that closes a window which is no longer there
  // (spec 33.4, platform-channel-contract "input-menu map"). A choice is not
  // one of those: it travels on the same channel as a selection, and the
  // application closes the menu itself in response.
  using DismissHandler = std::function<void(bool host_initiated)>;
  // The preview was dragged, and came to rest at this fraction of the canvas.
  // The host applies it to the live compositor so the file follows the window.
  using CameraMovedHandler = std::function<void(double x, double y)>;

  OverlayWindows();
  ~OverlayWindows();

  OverlayWindows(const OverlayWindows&) = delete;
  OverlayWindows& operator=(const OverlayWindows&) = delete;

  void SetMainWindow(HWND main_window);
  void SetCommandHandler(CommandHandler handler);
  void SetMenuSelectionHandler(MenuSelectionHandler handler);
  void SetMenuDismissHandler(DismissHandler handler);
  void SetCameraMovedHandler(CameraMovedHandler handler);

  bool ShowControlStrip(const OverlayPlacement& placement, std::string* error);
  void HideControlStrip();
  bool ShowCameraPreview(const OverlayPlacement& placement, std::string* error);
  // Re-frames a preview that is already on screen, and answers false when there
  // is none: a configuration change must never conjure a preview the session
  // did not ask for.
  bool MoveCameraPreview(const OverlayPlacement& placement);
  void HideCameraPreview();

  // The device list a chevron opened (spec 33.4).
  //
  // One at a time: showing it again re-places and re-renders the window that is
  // already there rather than opening a second one. Non-activating and
  // capture-excluded on exactly the same terms as the other two, because it is
  // the same window class.
  bool ShowInputMenu(const OverlayPlacement& placement,
                     const flutter::EncodableMap& state, std::string* error);
  void UpdateInputMenu(const flutter::EncodableMap& state);
  void HideInputMenu();

  // Moves the strip by `dx`, `dy` logical points and settles it exactly as the
  // end of a drag does (spec 33.3). A no-op when there is no strip.
  void NudgeControlStrip(double dx, double dy);

  // What the preview is to the picture-in-picture, and everything a drag, a
  // crop and a mask are resolved from. Pushed by the host whenever the camera
  // configuration or the camera itself changes.
  void SetCameraPreviewGeometry(const CameraPreviewGeometry& geometry);

  // Where the preview is now, as a fraction of the canvas (spec 33.5).
  //
  // False when there is no preview, and false in window mode, where the preview
  // is not the tile and dragging it moves nothing else (design 1e). That is the
  // null cameraPreviewPosition answers with.
  bool CameraPreviewPosition(double* x, double* y) const;

  // Where the control strip is now: the display holding its centre, and its
  // top-left as a fraction of that display's usable area (spec 33.3).
  //
  // False when no strip is on screen or its display cannot be named, which the
  // contract spells as a null reply. Deliberately not a zero position: failing
  // to read where the strip is is not the user having moved it back, and Dart
  // keeps whatever it had stored.
  bool ControlStripPosition(std::string* display_id, double* x, double* y) const;

  void UpdateControlStrip(const flutter::EncodableMap& state);
  // The `cameraPreviewState` map (platform-channel-contract
  // "relay/overlay/view"). `draw` carries the shape, the crop and the mask the
  // host resolved, which the preview cannot work out for itself and which have
  // to agree with the compositor to the pixel (design 1p, spec 33.5).
  void UpdateCameraPreview(bool mirrored, bool matches_composited_pip,
                           const CameraPreviewDraw& draw);

  // A frame for the preview texture. Latest-wins single slot: the previous
  // frame is overwritten rather than queued.
  void PushCameraPreviewFrame(const uint8_t* bgra, uint32_t width, uint32_t height,
                              uint32_t stride);

  // The overlay layer's rows of spec 19.1's census.
  //
  // This host destroys each window and its engine on hide, so both the
  // engines and the preview's texture return to zero after a session — a
  // different lifetime from macOS's, and 19.1's second table permits either.
  // `docs/development/compatibility-matrix.md` records which is which.
  //
  // The low-level hooks are counted as event monitors: they are installed for
  // exactly as long as a menu is open and are what 19.1 means by "low-level
  // input hooks".
  ResourceCensus DebugCensus() const;

  std::vector<std::string> ExcludedWindowIds() const;
  std::vector<HWND> ExcludedWindows() const;

  // The main panel is ordinary chrome, not an excluded overlay, so a display
  // recording would otherwise contain it.
  void SetMainWindowVisible(bool visible);

  void DisposeAll();

 private:
  // Which overlay a window is. The three behave differently once they are on
  // screen — only the strip re-clamps itself to the usable area, only the
  // preview is the picture-in-picture, only the menu re-places itself when it
  // measures — and a role is how each says so without three flags that can
  // disagree.
  enum class OverlayRole { kControlStrip, kCameraPreview, kInputMenu };

  // One overlay: a layered, non-activating, top-most host window with a
  // secondary Flutter engine parented into it.
  class OverlayWindow {
   public:
    explicit OverlayWindow(std::string entrypoint, std::string channel_owner,
                           OverlayRole role);
    ~OverlayWindow();

    bool Create(const RECT& frame, CommandHandler on_command,
                std::function<void(double, double)> on_content_size, bool wants_texture,
                std::string* error);
    void Destroy();
    // Whether this window has a platform texture registered against its engine
    // — the camera preview's, today (spec 19.1).
    bool has_texture() const { return texture_ != nullptr; }
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

    // Moves the strip by `dx`, `dy` physical pixels, then snaps, clamps and
    // remembers exactly as the end of a drag does (spec 33.3).
    void Nudge(LONG dx, LONG dy);

    // What the preview is to the picture-in-picture. Held on the window rather
    // than looked up when it is needed, because the window procedure resolves a
    // drag and a resize without taking OverlayWindows' lock — which is what
    // keeps a modal move loop out of it.
    void SetPreviewGeometry(const CameraPreviewGeometry& geometry);
    const CameraPreviewGeometry& preview_geometry() const { return geometry_; }
    // Where the preview sits now, as a fraction of the canvas. False in window
    // mode and for anything that is not the preview.
    bool PreviewPosition(double* x, double* y) const;
    void SetCameraMovedHandler(CameraMovedHandler handler);

    // The strip the menu hangs off and the centre of the control that asked for
    // it, both in screen pixels. Kept so the menu can re-place itself when its
    // engine reports the size it measured.
    void SetMenuAnchor(const RECT& anchor_frame, LONG anchor_x, LONG gap);
    void SetDismissHandler(DismissHandler handler);
    void SetMenuSelectionHandler(MenuSelectionHandler handler);
    // Where the menu goes for a window of this size, from the anchor above.
    RECT MenuFrameFor(LONG width, LONG height) const;

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
    // The preview's own end of a drag: the window is where the user let go, and
    // the tile has to be re-resolved from it — clamped to the margin and
    // snapped to a corner by the same arithmetic the compositor uses — before
    // the window is put back on the result (spec 33.5).
    void FinishCameraMove();
    // The tile's rectangle in canvas coordinates, as a window rectangle on the
    // display being recorded.
    RECT CanvasRectToScreen(const RectD& rect) const;
    // Clips the window to the tile's shape. A circle in a recording is a circle
    // on screen because the window itself is one: the overlay deliberately does
    // not use WS_EX_LAYERED (see Create), so a region is what shows the desktop
    // through the corners.
    void ApplyPreviewShape();
    void HandleCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
    // Whether this window may be handed to the operating system's move loop:
    // the strip always, the preview only while it is the tile (spec 33.3, 33.5).
    bool draggable() const;

    const std::string entrypoint_;
    const std::string channel_owner_;
    const OverlayRole role_;
    HWND window_ = nullptr;
    std::unique_ptr<flutter::FlutterViewController> controller_;
    std::unique_ptr<flutter::PluginRegistrar> registrar_;
    std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
    std::unique_ptr<flutter::TextureVariant> texture_;
    int64_t texture_id_ = -1;
    CommandHandler on_command_;
    std::function<void(double, double)> on_content_size_;
    CameraMovedHandler on_camera_moved_;
    DismissHandler on_dismiss_;
    MenuSelectionHandler on_menu_selection_;

    // The preview's relationship to the composited tile. Meaningless for the
    // other two roles.
    CameraPreviewGeometry geometry_;

    // The menu's anchor, in screen pixels. Meaningless for the other two roles.
    bool has_anchor_ = false;
    RECT anchor_frame_{};
    LONG anchor_x_ = 0;
    LONG anchor_gap_ = 0;

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

  // Points the menu at the control that asked for it and resolves its frame.
  // Call with `mutex_` held.
  RECT ResolveMenuFrame(const OverlayPlacement& placement) const;

  // Asks the host to close the menu on a later turn of the message loop. Call
  // without `mutex_` held: it runs the handler.
  //
  // `host_initiated` is true for every close the application did not ask for —
  // a click outside, Esc, the strip moving, a display change — and false for a
  // choice, which the application hears as a selection on the same channel and
  // answers with its own `hideInputMenu` (spec 33.4).
  void RequestMenuDismissal(bool host_initiated) const;

  // Records where a command came from, then forwards it. The anchor is kept
  // rather than passed on, because the menu that needs it is opened by a later
  // call from Dart (spec 33.4).
  void NoteCommand(const std::string& command, std::optional<double> anchor_x);

  // Esc and a click outside, which a WS_EX_NOACTIVATE menu never sees itself
  // (spec 33.4). Low-level hooks are the only source of either; they are
  // installed for exactly as long as a menu is open and removed with it.
  //
  // Static because a hook callback has no `this`, and single-instance because
  // the plugin owns exactly one OverlayWindows. Installed, removed and called
  // only on the platform thread, so none of this needs a lock — and must not
  // take one: the callback can run while that same thread is inside a call that
  // holds `mutex_`.
  void InstallMenuHooks();
  void RemoveMenuHooks();
  static LRESULT CALLBACK MouseHook(int code, WPARAM wparam, LPARAM lparam);
  static LRESULT CALLBACK KeyboardHook(int code, WPARAM wparam, LPARAM lparam);

  static OverlayWindows* hooked_;
  static HHOOK mouse_hook_;
  static HHOOK keyboard_hook_;
  // The button whose release still has to be swallowed, because its press was.
  // Letting the release through on its own leaves the window underneath holding
  // a button nobody pressed.
  static UINT swallowed_button_up_;

  HWND main_window_ = nullptr;
  bool main_window_hidden_ = false;
  // Installed once by the plugin's constructor, before any overlay exists and
  // before any thread but the platform thread can reach this object. Read
  // without `mutex_` for that reason, which is what keeps a hook callback and a
  // window procedure out of a lock a modal move loop can be holding.
  CommandHandler on_command_;
  MenuSelectionHandler on_menu_selection_;
  DismissHandler on_menu_dismiss_;
  CameraMovedHandler on_camera_moved_;
  // The centre of the control that last raised a command, in the strip window's
  // own coordinates and in logical points. The chevrons carry one; everything
  // else clears it, so a menu never opens under a control nobody pressed.
  //
  // Atomic rather than guarded by `mutex_`, and for the same reason the
  // handlers above are read unguarded: a command arrives on the platform
  // thread, which is also the thread that can be inside a call holding that
  // lock while the message queue is pumped underneath it.
  std::atomic<bool> has_command_anchor_{false};
  std::atomic<double> command_anchor_x_{0};
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
  std::unique_ptr<OverlayWindow> input_menu_;
  CameraPreviewGeometry preview_geometry_;
  mutable std::mutex mutex_;
};

}  // namespace relay

#endif  // RELAY_OVERLAY_WINDOWS_H_
