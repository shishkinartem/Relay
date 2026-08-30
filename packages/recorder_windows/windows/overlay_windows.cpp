#include "overlay_windows.h"

#include <flutter/dart_project.h>
#include <flutter/standard_method_codec.h>
#include <shellscalingapi.h>

#include <algorithm>
#include <cmath>
#include <cwchar>
#include <iterator>
#include <memory>
#include <optional>
#include <sstream>
#include <utility>
#include <variant>

#include "capture_source_enumerator.h"

namespace relay {

namespace {

constexpr wchar_t kOverlayClassName[] = L"RelayOverlayHostWindow";
// Applies a measured content size on a later turn of the message loop. See
// OverlayWindow::HandleCall for why it cannot be applied where it arrives.
constexpr UINT kApplyContentSizeMessage = WM_APP + 0x51;
// Enters the operating system's window-drag loop on a later turn of the message
// loop. See OverlayWindow::HandleCall for why it cannot be entered where the
// beginMove call arrives.
constexpr UINT kBeginMoveMessage = WM_APP + 0x52;
constexpr char kOverlayViewChannel[] = "relay/overlay/view";
// The overlay engines run these Dart entrypoints (contract: relay/overlay/view).
constexpr char kControlStripEntrypoint[] = "controlStripMain";
constexpr char kCameraPreviewEntrypoint[] = "cameraPreviewMain";
constexpr char kInputMenuEntrypoint[] = "inputMenuMain";

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

bool BoolAt(const flutter::EncodableMap& map, const char* key, bool fallback) {
  const flutter::EncodableValue* value = Find(map, key);
  if (value == nullptr) {
    return fallback;
  }
  const auto* flag = std::get_if<bool>(value);
  return flag == nullptr ? fallback : *flag;
}

// A key that is present and holds a string, distinguished from one that is
// absent or null. `System default` is a null device id, and a device whose id
// happens to be empty is a different answer (spec 33.4).
std::optional<std::string> OptionalStringAt(const flutter::EncodableMap& map,
                                            const char* key) {
  const flutter::EncodableValue* value = Find(map, key);
  if (value == nullptr) {
    return std::nullopt;
  }
  const auto* text = std::get_if<std::string>(value);
  return text == nullptr ? std::nullopt : std::optional<std::string>(*text);
}

// The same, for a number: absent and null both read as "no anchor", which is a
// command that came from something other than a chevron.
std::optional<double> OptionalDoubleAt(const flutter::EncodableMap& map,
                                       const char* key) {
  const flutter::EncodableValue* value = Find(map, key);
  if (value == nullptr) {
    return std::nullopt;
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
  return std::nullopt;
}

// Rounds a canvas coordinate onto the pixel grid, away from zero, the way every
// other placement in this file does.
LONG RoundToPixel(double value) {
  return static_cast<LONG>(value < 0 ? value - 0.5 : value + 0.5);
}

// The display a strip belongs to: the one holding its centre (spec 33.3).
//
// Deliberately not MonitorFromWindow's largest-intersection rule — a strip
// dragged across the seam belongs to the display its centre ended on, which is
// what the drag looks like to the person doing it.
HMONITOR MonitorForStrip(HWND window) {
  RECT frame{};
  if (window == nullptr || ::GetWindowRect(window, &frame) == FALSE) {
    return ::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
  }
  const POINT centre{frame.left + (frame.right - frame.left) / 2,
                     frame.top + (frame.bottom - frame.top) / 2};
  // NEAREST rather than NULL: a centre that lands in the gap between two
  // monitors, or off the desktop entirely, still has to resolve to a display.
  return ::MonitorFromPoint(centre, MONITOR_DEFAULTTONEAREST);
}

// The geometry of `monitor`, or false when it has none to report.
//
// GetMonitorInfoW's return is not decoration: a monitor removed between the
// check that its handle was live and this call fails here and leaves the
// structure zeroed, and a zeroed usable area would place the strip at the
// virtual desktop's origin rather than on a screen.
bool MonitorGeometry(HMONITOR monitor, MONITORINFO* out) {
  if (monitor == nullptr || out == nullptr) {
    return false;
  }
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (::GetMonitorInfoW(monitor, &info) == FALSE || !IsUsableWorkArea(info.rcWork)) {
    return false;
  }
  *out = info;
  return true;
}

// The geometry to resolve a placement against: `monitor`'s when it reports any,
// the primary display's when it does not.
//
// SPI_GETWORKAREA is the fallback because it has no handle to go stale under
// it. It answers with a usable area and nothing else, so rcMonitor is filled
// from it too: an absolute placement resolved against that is off by the
// taskbar rather than off the desktop. When even that fails the structure stays
// zeroed and the frame lands at the desktop's origin at the size it asked for,
// which is the least wrong thing to hand a window that is about to exist
// regardless.
MONITORINFO GeometryOrPrimary(HMONITOR monitor) {
  MONITORINFO info{};
  if (MonitorGeometry(monitor, &info)) {
    return info;
  }
  RECT work_area{};
  if (::SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0) != FALSE &&
      IsUsableWorkArea(work_area)) {
    info.rcWork = work_area;
    info.rcMonitor = work_area;
  }
  return info;
}

// The usable area of `monitor` — rcWork, never rcMonitor (spec 6).
bool WorkAreaOf(HMONITOR monitor, RECT* out) {
  MONITORINFO info{};
  if (out == nullptr || !MonitorGeometry(monitor, &info)) {
    return false;
  }
  *out = info.rcWork;
  return true;
}

// A window's own frame and the usable area it is on, in one step: every
// placement decision below needs both or neither.
bool WindowAndWorkArea(HWND window, RECT* frame, RECT* work_area) {
  if (window == nullptr || frame == nullptr || work_area == nullptr) {
    return false;
  }
  return ::GetWindowRect(window, frame) != FALSE &&
         WorkAreaOf(MonitorForStrip(window), work_area);
}

// Whether `point` is over one of this process's overlay windows.
//
// Asked by the menu's dismissal hook, which runs on the platform thread and
// must therefore touch no member of anything: the window class is what every
// overlay shares and nothing else does, so the answer comes from the desktop
// rather than from state that would need a lock.
//
// A press on the strip is the strip's own — the chevron that replaces this
// sheet with the next one is such a press — so it is never swallowed (spec
// 33.7, "Two chevrons in quick succession").
bool PointIsOverOwnOverlay(POINT point) {
  const HWND under = ::WindowFromPoint(point);
  if (under == nullptr) {
    return false;
  }
  const HWND root = ::GetAncestor(under, GA_ROOT);
  wchar_t class_name[64]{};
  const int length =
      ::GetClassNameW(root, class_name, static_cast<int>(std::size(class_name)));
  return length > 0 && std::wcscmp(class_name, kOverlayClassName) == 0;
}

}  // namespace

OverlayWindows* OverlayWindows::hooked_ = nullptr;
HHOOK OverlayWindows::mouse_hook_ = nullptr;
HHOOK OverlayWindows::keyboard_hook_ = nullptr;
UINT OverlayWindows::swallowed_button_up_ = 0;

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
  // Absent for a strip that has never been moved, and the anchor above is then
  // the whole placement (spec 33.3).
  if (const flutter::EncodableValue* position = Find(map, "position")) {
    if (const auto* spot = std::get_if<flutter::EncodableMap>(position)) {
      std::string display_id = StringAt(*spot, "displayId");
      // A position that cannot name a display is no position: it would resolve
      // against whichever monitor happened to be current, which is the anchor's
      // job. Dart drops the same shape on the way in.
      if (!display_id.empty()) {
        placement.has_position = true;
        placement.position_display_id = std::move(display_id);
        placement.position_x = DoubleAt(*spot, "x", 0);
        placement.position_y = DoubleAt(*spot, "y", 0);
      }
    }
  }
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

void OverlayWindows::SetMenuSelectionHandler(MenuSelectionHandler handler) {
  std::lock_guard<std::mutex> lock(mutex_);
  on_menu_selection_ = std::move(handler);
}

void OverlayWindows::SetMenuDismissHandler(DismissHandler handler) {
  std::lock_guard<std::mutex> lock(mutex_);
  on_menu_dismiss_ = std::move(handler);
}

void OverlayWindows::SetCameraMovedHandler(CameraMovedHandler handler) {
  std::lock_guard<std::mutex> lock(mutex_);
  on_camera_moved_ = std::move(handler);
}

void OverlayWindows::NoteCommand(const std::string& command,
                                 std::optional<double> anchor_x) {
  // Kept, not forwarded: the menu that needs it is opened by a later call from
  // Dart, once the application has decided which devices to offer. The value
  // first, the flag second, so a reader that sees the flag set sees the x that
  // goes with it.
  command_anchor_x_.store(anchor_x.value_or(0));
  has_command_anchor_.store(anchor_x.has_value());
  if (on_command_) {
    on_command_(command, anchor_x);
  }
}

void OverlayWindows::RequestMenuDismissal(bool host_initiated) const {
  if (on_menu_dismiss_) {
    on_menu_dismiss_(host_initiated);
  }
}

void OverlayWindows::InstallMenuHooks() {
  if (mouse_hook_ != nullptr || keyboard_hook_ != nullptr) {
    return;
  }
  hooked_ = this;
  swallowed_button_up_ = 0;
  const HINSTANCE instance = ::GetModuleHandleW(nullptr);
  mouse_hook_ =
      ::SetWindowsHookExW(WH_MOUSE_LL, &OverlayWindows::MouseHook, instance, 0);
  keyboard_hook_ =
      ::SetWindowsHookExW(WH_KEYBOARD_LL, &OverlayWindows::KeyboardHook, instance, 0);
  if (mouse_hook_ == nullptr && keyboard_hook_ == nullptr) {
    // Neither hook could be installed — a policy that forbids them, or a
    // desktop this process cannot reach. The menu still closes on a choice, on
    // the strip moving, on a display change and with the session; it just does
    // not close by itself when the user looks away.
    hooked_ = nullptr;
  }
}

void OverlayWindows::RemoveMenuHooks() {
  if (mouse_hook_ != nullptr) {
    ::UnhookWindowsHookEx(mouse_hook_);
    mouse_hook_ = nullptr;
  }
  if (keyboard_hook_ != nullptr) {
    ::UnhookWindowsHookEx(keyboard_hook_);
    keyboard_hook_ = nullptr;
  }
  hooked_ = nullptr;
  swallowed_button_up_ = 0;
}

LRESULT CALLBACK OverlayWindows::MouseHook(int code, WPARAM wparam, LPARAM lparam) {
  // A hook that is not asked to act passes the message on untouched, and does
  // it first: everything below runs on every mouse event in the session.
  if (code != HC_ACTION || hooked_ == nullptr) {
    return ::CallNextHookEx(nullptr, code, wparam, lparam);
  }
  const UINT message = static_cast<UINT>(wparam);
  if (swallowed_button_up_ != 0 && message == swallowed_button_up_) {
    // The press that closed the menu was swallowed, so its release is too: a
    // window left holding a button nobody pressed is worse than a lost click.
    swallowed_button_up_ = 0;
    return 1;
  }
  UINT release = 0;
  switch (message) {
    case WM_LBUTTONDOWN:
      release = WM_LBUTTONUP;
      break;
    case WM_RBUTTONDOWN:
      release = WM_RBUTTONUP;
      break;
    case WM_MBUTTONDOWN:
      release = WM_MBUTTONUP;
      break;
    default:
      return ::CallNextHookEx(nullptr, code, wparam, lparam);
  }
  const auto* mouse = reinterpret_cast<const MSLLHOOKSTRUCT*>(lparam);
  if (mouse == nullptr || PointIsOverOwnOverlay(mouse->pt)) {
    // Inside the menu, or on the strip: the menu's own rows and the chevron
    // that replaces it both have to receive their click.
    return ::CallNextHookEx(nullptr, code, wparam, lparam);
  }
  swallowed_button_up_ = release;
  hooked_->RequestMenuDismissal(/*host_initiated=*/true);
  // Not forwarded to what is underneath (spec 33.7): the click closed a sheet
  // the user had open, and pressing whatever was behind it as well is a second
  // action they did not ask for.
  return 1;
}

LRESULT CALLBACK OverlayWindows::KeyboardHook(int code, WPARAM wparam,
                                              LPARAM lparam) {
  if (code != HC_ACTION || hooked_ == nullptr) {
    return ::CallNextHookEx(nullptr, code, wparam, lparam);
  }
  const auto* key = reinterpret_cast<const KBDLLHOOKSTRUCT*>(lparam);
  const bool pressed = wparam == WM_KEYDOWN || wparam == WM_SYSKEYDOWN;
  if (!pressed || key == nullptr || key->vkCode != VK_ESCAPE) {
    return ::CallNextHookEx(nullptr, code, wparam, lparam);
  }
  hooked_->RequestMenuDismissal(/*host_initiated=*/true);
  // Esc closed the sheet and nothing else. Forwarding it as well would also
  // cancel whatever dialog the recorded application happens to have open.
  return 1;
}

RECT OverlayWindows::ResolveFrame(const OverlayPlacement& placement,
                                  bool* from_remembered_position) const {
  // A remembered position names its own display; everything else lands on the
  // current one (spec 5).
  //
  // An HMONITOR is not stable across a display change: Windows may never hand
  // that value out again, and may hand it to a different monitor. Both ends are
  // survivable, which is why a stored display id can only ever be a hint.
  // ParseMonitorSourceId — the same reader getAvailableSources' ids go through —
  // rejects a handle that names no live monitor, so a stale id falls back to the
  // anchor on the current display (spec 33.7, "Stored display no longer
  // exists"); a recycled one resolves the fraction against a real monitor's
  // usable area, clamped like any other, so the worst case is the right spot on
  // the wrong display rather than a strip nobody can reach.
  const HMONITOR remembered =
      placement.has_position ? ParseMonitorSourceId(placement.position_display_id)
                             : nullptr;
  // The read is the second half of that check, and the one that catches a
  // display removed between the two calls: a handle that was live a moment ago
  // reports no geometry now, and a fraction of nothing is not a position. Such
  // a placement takes the same fallback a stale id does.
  MONITORINFO info{};
  const bool on_remembered = MonitorGeometry(remembered, &info);
  const HMONITOR monitor =
      on_remembered ? remembered
                    : (main_window_ != nullptr
                           ? ::MonitorFromWindow(main_window_, MONITOR_DEFAULTTONEAREST)
                           : ::MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY));
  if (!on_remembered) {
    info = GeometryOrPrimary(monitor);
  }
  if (from_remembered_position != nullptr) {
    *from_remembered_position = on_remembered;
  }
  const double scale = MonitorScale(monitor);

  const LONG width = static_cast<LONG>(placement.width * scale + 0.5);
  const LONG height = static_cast<LONG>(placement.height * scale + 0.5);
  RECT frame{};
  if (placement.absolute) {
    frame.left = info.rcMonitor.left + static_cast<LONG>(placement.x * scale + 0.5);
    frame.top = info.rcMonitor.top + static_cast<LONG>(placement.y * scale + 0.5);
    frame.right = frame.left + width;
    frame.bottom = frame.top + height;
    // Returned unclamped, alone among the three: this frame is the composited
    // picture-in-picture's own rectangle, and nudging it would break design
    // 1p's promise that the preview and the tile are one object.
    return frame;
  }
  if (on_remembered) {
    // Resolved against the usable area and clamped into it, which is what keeps
    // the taskbar uncovered whatever fraction was stored (spec 6, 33.3).
    return FractionalStripFrame(info.rcWork, placement.position_x, placement.position_y,
                                width, height);
  }
  const LONG work_width = info.rcWork.right - info.rcWork.left;
  const LONG margin = static_cast<LONG>(placement.margin * scale + 0.5);
  frame.left = info.rcWork.left + (work_width - width) / 2;
  frame.top = placement.anchor == OverlayPlacement::Anchor::kBottomCenter
                  ? info.rcWork.bottom - margin - height
                  : info.rcWork.top + margin;
  frame.right = frame.left + width;
  frame.bottom = frame.top + height;
  // The default dock is inside the usable area by construction — but only for a
  // strip that fits on the display, and this is the one place that says so.
  return ClampToWorkArea(info.rcWork, frame);
}

bool OverlayWindows::ShowControlStrip(const OverlayPlacement& placement,
                                      std::string* error) {
  std::lock_guard<std::mutex> lock(mutex_);
  OverlayPlacement resolved = placement;
  if (has_strip_content_size_) {
    resolved.width = strip_content_width_;
    resolved.height = strip_content_height_;
  }
  bool from_remembered_position = false;
  const RECT frame = ResolveFrame(resolved, &from_remembered_position);
  if (control_strip_) {
    control_strip_->SetFrame(frame);
    RememberStripPlacement(resolved, from_remembered_position);
    return true;
  }
  auto window = std::make_unique<OverlayWindow>(kControlStripEntrypoint, "control_strip",
                                               OverlayRole::kControlStrip);
  // The strip closes the sheet when it starts to move (spec 33.7); it asks the
  // host to do it rather than doing it itself, for the same reason the menu
  // does — nothing may destroy a window from inside a stack that window owns.
  window->SetDismissHandler(on_menu_dismiss_);
  if (!window->Create(
          frame,
          [this](const std::string& command, std::optional<double> anchor_x) {
            NoteCommand(command, anchor_x);
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
  RememberStripPlacement(resolved, from_remembered_position);
  return true;
}

// The spot a display change re-resolves the strip to, after a show has just put
// it somewhere (spec 33.3).
//
// A restored position is adopted as the number Dart stored, not re-measured
// from the window: resolving a fraction clamps it into the usable area, and
// measuring the clamped result back would hand the next display change a spot
// the user never chose. A placement with no position to restore is the anchor,
// and the anchor is where the strip now is.
void OverlayWindows::RememberStripPlacement(const OverlayPlacement& placement,
                                            bool from_remembered_position) {
  if (!control_strip_) {
    return;
  }
  if (from_remembered_position) {
    control_strip_->RememberRestoredPosition(placement.position_x,
                                             placement.position_y);
    return;
  }
  control_strip_->RememberPosition();
}

void OverlayWindows::HideControlStrip() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (control_strip_) {
    control_strip_->Destroy();
    control_strip_.reset();
  }
  // The menu hangs off the strip and cannot outlive it: the session ending is
  // exactly the case 33.7 spells "the sheet closes with the session". Closed
  // here rather than deferred, because the call that asked for it is on the
  // platform thread and nothing of the menu's is on the stack.
  if (input_menu_) {
    RemoveMenuHooks();
    input_menu_->Destroy();
    input_menu_.reset();
  }
  has_command_anchor_.store(false);
}

bool OverlayWindows::ShowCameraPreview(const OverlayPlacement& placement,
                                       std::string* error) {
  std::lock_guard<std::mutex> lock(mutex_);
  const RECT frame = ResolveFrame(placement);
  if (camera_preview_) {
    camera_preview_->SetPreviewGeometry(preview_geometry_);
    camera_preview_->SetFrame(frame);
    return true;
  }
  auto window = std::make_unique<OverlayWindow>(kCameraPreviewEntrypoint,
                                               "camera_preview",
                                               OverlayRole::kCameraPreview);
  window->SetPreviewGeometry(preview_geometry_);
  window->SetCameraMovedHandler(on_camera_moved_);
  if (!window->Create(
          frame,
          [this](const std::string& command, std::optional<double> anchor_x) {
            NoteCommand(command, anchor_x);
          },
          [](double, double) {}, true, error)) {
    return false;
  }
  camera_preview_ = std::move(window);
  // After the window exists, so the region is applied to a real frame.
  camera_preview_->SetFrame(frame);
  return true;
}

bool OverlayWindows::MoveCameraPreview(const OverlayPlacement& placement) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!camera_preview_) {
    return false;
  }
  camera_preview_->SetFrame(ResolveFrame(placement));
  return true;
}

void OverlayWindows::HideCameraPreview() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (camera_preview_) {
    camera_preview_->Destroy();
    camera_preview_.reset();
  }
}

void OverlayWindows::SetCameraPreviewGeometry(
    const CameraPreviewGeometry& geometry) {
  std::lock_guard<std::mutex> lock(mutex_);
  preview_geometry_ = geometry;
  if (camera_preview_) {
    camera_preview_->SetPreviewGeometry(geometry);
  }
}

bool OverlayWindows::CameraPreviewPosition(double* x, double* y) const {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!camera_preview_) {
    return false;
  }
  return camera_preview_->PreviewPosition(x, y);
}

RECT OverlayWindows::ResolveMenuFrame(const OverlayPlacement& placement) const {
  const HWND strip = control_strip_ ? control_strip_->window() : nullptr;
  const HMONITOR monitor =
      strip != nullptr ? MonitorForStrip(strip)
                       : (main_window_ != nullptr
                              ? ::MonitorFromWindow(main_window_, MONITOR_DEFAULTTONEAREST)
                              : ::MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY));
  const MONITORINFO info = GeometryOrPrimary(monitor);
  const double scale = MonitorScale(monitor);
  const LONG width = static_cast<LONG>(placement.width * scale + 0.5);
  const LONG height = static_cast<LONG>(placement.height * scale + 0.5);
  const LONG gap = static_cast<LONG>(kInputMenuGapPoints * scale + 0.5);

  RECT anchor_frame{};
  if (strip == nullptr || ::GetWindowRect(strip, &anchor_frame) == FALSE) {
    // No strip to hang off: the menu is placed as if the strip were a point at
    // the top centre of the usable area, which is where the strip's default
    // dock is. It cannot be left unplaced — Dart asked for a window.
    const LONG centre = info.rcWork.left + (info.rcWork.right - info.rcWork.left) / 2;
    anchor_frame.left = centre;
    anchor_frame.right = centre;
    anchor_frame.top = info.rcWork.top;
    anchor_frame.bottom = info.rcWork.top;
  }
  // The chevron's centre in the strip's own coordinates, in logical points, so
  // the menu opens under the control that was pressed. Without one — a command
  // that named no spot — the strip's own centre is the honest fallback.
  const LONG anchor_x =
      has_command_anchor_.load()
          ? anchor_frame.left +
                static_cast<LONG>(command_anchor_x_.load() * scale + 0.5)
          : anchor_frame.left + (anchor_frame.right - anchor_frame.left) / 2;
  if (input_menu_) {
    input_menu_->SetMenuAnchor(anchor_frame, anchor_x, gap);
  }
  return ResolveInputMenuFrame(info.rcWork, anchor_frame, anchor_x, width, height, gap);
}

bool OverlayWindows::ShowInputMenu(const OverlayPlacement& placement,
                                   const flutter::EncodableMap& state,
                                   std::string* error) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (input_menu_) {
    // One at a time: the second chevron re-places and re-renders the window the
    // first one opened rather than opening a second (spec 33.4).
    const RECT frame = ResolveMenuFrame(placement);
    input_menu_->SetFrame(frame);
    input_menu_->Invoke("inputMenuState", flutter::EncodableValue(state));
    return true;
  }
  auto window = std::make_unique<OverlayWindow>(kInputMenuEntrypoint, "input_menu",
                                               OverlayRole::kInputMenu);
  window->SetDismissHandler(on_menu_dismiss_);
  window->SetMenuSelectionHandler(on_menu_selection_);
  input_menu_ = std::move(window);
  const RECT frame = ResolveMenuFrame(placement);
  if (!input_menu_->Create(
          frame,
          [this](const std::string& command, std::optional<double> anchor_x) {
            NoteCommand(command, anchor_x);
          },
          // The menu is the one overlay whose measured size re-places it: it
          // may have opened above the strip, and a window that grew about its
          // top-left from there would slide down over the strip it belongs to.
          [](double, double) {}, false, error)) {
    input_menu_.reset();
    return false;
  }
  input_menu_->Invoke("inputMenuState", flutter::EncodableValue(state));
  // Only once the window is really on screen: a hook installed for a menu that
  // failed to open would swallow the next click the user made anywhere.
  InstallMenuHooks();
  return true;
}

void OverlayWindows::UpdateInputMenu(const flutter::EncodableMap& state) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (input_menu_) {
    // Re-rendered in place, never reopened: a device that appears or disappears
    // must not close the sheet the user is reading (spec 33.7).
    input_menu_->Invoke("inputMenuState", flutter::EncodableValue(state));
  }
}

void OverlayWindows::HideInputMenu() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!input_menu_) {
    return;
  }
  RemoveMenuHooks();
  input_menu_->Destroy();
  input_menu_.reset();
}

void OverlayWindows::NudgeControlStrip(double dx, double dy) {
  std::unique_ptr<OverlayWindow> menu;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!control_strip_ || control_strip_->window() == nullptr) {
      return;
    }
    // Logical points in, physical pixels out, against the display the strip is
    // actually on: eight points is eight points on every monitor.
    const double scale = MonitorScale(MonitorForStrip(control_strip_->window()));
    control_strip_->Nudge(RoundToPixel(dx * scale), RoundToPixel(dy * scale));
    // The strip moved, so the sheet closes (spec 33.4). Taken out under the
    // lock and destroyed outside it, like every other teardown here.
    if (input_menu_) {
      RemoveMenuHooks();
      menu = std::move(input_menu_);
    }
  }
  if (menu) {
    menu->Destroy();
    // The strip moved out from under a sheet the application still believes is
    // open, and a keyboard nudge is the strip moving exactly as a drag is
    // (spec 33.3, 33.4). Reported after the lock is released, like every other
    // handler call here.
    RequestMenuDismissal(/*host_initiated=*/true);
  }
}

bool OverlayWindows::ControlStripPosition(std::string* display_id, double* x,
                                          double* y) const {
  std::lock_guard<std::mutex> lock(mutex_);
  if (display_id == nullptr || x == nullptr || y == nullptr || !control_strip_) {
    return false;
  }
  const HWND window = control_strip_->window();
  if (window == nullptr) {
    return false;
  }
  const HMONITOR monitor = MonitorForStrip(window);
  // The fraction the user established, not the pixels the strip is sitting at.
  //
  // The two agree except while the usable area is temporarily smaller than the
  // fraction asks for — a taskbar shown, a display in the middle of changing
  // mode — and then the window is clamped inwards and its measured fraction is
  // not the one to persist: storing it would move the strip a little further
  // from where the user put it every time that happened (spec 33.3). Measuring
  // is the fallback for a strip that has established no fraction at all.
  RECT frame{};
  RECT work_area{};
  if (!control_strip_->RememberedPosition(x, y) &&
      (::GetWindowRect(window, &frame) == FALSE || !WorkAreaOf(monitor, &work_area) ||
       !StripPositionRatio(work_area, frame, x, y))) {
    return false;
  }
  // capture_source_enumerator's spelling, reused rather than invented a second
  // time: "display:<HMONITOR as decimal>" is already the id getAvailableSources
  // gives Dart for a display (spec 4.1), and a second spelling for the same
  // thing is a second thing to keep in step.
  *display_id = MonitorSourceId(monitor);
  return true;
}

void OverlayWindows::UpdateControlStrip(const flutter::EncodableMap& state) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (control_strip_) {
    control_strip_->Invoke("controlStripState", flutter::EncodableValue(state));
  }
}

void OverlayWindows::UpdateCameraPreview(bool mirrored, bool matches_composited_pip,
                                         const CameraPreviewDraw& draw) {
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
  state[flutter::EncodableValue("aspectRatio")] =
      flutter::EncodableValue(draw.aspect_ratio);
  // The shape of the box the picture goes in, which is the tile's in both
  // modes. In display mode it equals aspectRatio because the window IS the
  // tile; in window mode the texture is the whole camera frame and this is what
  // lets a captioned panel show the tile's shape without becoming it.
  state[flutter::EncodableValue("pipAspectRatio")] =
      flutter::EncodableValue(draw.pip_aspect_ratio);
  // The crop and the mask travel with the shape, because the preview has to
  // draw what the compositor draws: design 1p promises they are the same
  // object, and a letterboxed rectangle on screen with a cropped circle in the
  // file is the defect that promise exists to prevent (spec 33.5). They travel
  // in BOTH modes — the compositor crops whatever the source is, so a window
  // recording showed one picture for all three presets while the file differed.
  // Resolved by the host — ResolveCameraPreviewDraw — because Dart has neither
  // the camera's shape nor the encoder canvas to work them out from.
  state[flutter::EncodableValue("fit")] =
      flutter::EncodableValue(std::string(CameraPipFitName(draw.fit)));
  state[flutter::EncodableValue("cornerRadiusRatio")] =
      flutter::EncodableValue(draw.corner_radius_ratio);
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
  // The third overlay is in the exclusion set on exactly the same terms as the
  // other two. A menu that appears in the recording is the failure spec 6 is
  // written about (spec 33.4).
  if (input_menu_ && input_menu_->window() != nullptr) {
    windows.push_back(input_menu_->window());
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
  // The hooks first: they are global, they name this object, and nothing may
  // reach a destroyed one through them.
  RemoveMenuHooks();
  if (input_menu_) {
    input_menu_->Destroy();
    input_menu_.reset();
  }
  if (control_strip_) {
    control_strip_->Destroy();
    control_strip_.reset();
  }
  if (camera_preview_) {
    camera_preview_->Destroy();
    camera_preview_.reset();
  }
  has_command_anchor_.store(false);
  if (main_window_hidden_ && main_window_ != nullptr) {
    ::ShowWindow(main_window_, SW_SHOW);
    main_window_hidden_ = false;
  }
}

OverlayWindows::OverlayWindow::OverlayWindow(std::string entrypoint,
                                             std::string channel_owner,
                                             OverlayRole role)
    : entrypoint_(std::move(entrypoint)),
      channel_owner_(std::move(channel_owner)),
      role_(role) {}

OverlayWindows::OverlayWindow::~OverlayWindow() {
  Destroy();
}

bool OverlayWindows::OverlayWindow::draggable() const {
  switch (role_) {
    case OverlayRole::kControlStrip:
      return true;
    case OverlayRole::kCameraPreview:
      // Only in display mode, where the preview *is* the picture-in-picture
      // (design 1p). In window mode it is a separate captioned object and
      // dragging it would move a window that stands for nothing (design 1e).
      return geometry_.is_tile;
    case OverlayRole::kInputMenu:
      break;
  }
  return false;
}

void OverlayWindows::OverlayWindow::SetPreviewGeometry(
    const CameraPreviewGeometry& geometry) {
  geometry_ = geometry;
  ApplyPreviewShape();
}

void OverlayWindows::OverlayWindow::SetCameraMovedHandler(
    CameraMovedHandler handler) {
  on_camera_moved_ = std::move(handler);
}

void OverlayWindows::OverlayWindow::SetDismissHandler(DismissHandler handler) {
  on_dismiss_ = std::move(handler);
}

void OverlayWindows::OverlayWindow::SetMenuSelectionHandler(
    MenuSelectionHandler handler) {
  on_menu_selection_ = std::move(handler);
}

void OverlayWindows::OverlayWindow::SetMenuAnchor(const RECT& anchor_frame,
                                                  LONG anchor_x, LONG gap) {
  has_anchor_ = true;
  anchor_frame_ = anchor_frame;
  anchor_x_ = anchor_x;
  anchor_gap_ = gap;
}

RECT OverlayWindows::OverlayWindow::MenuFrameFor(LONG width, LONG height) const {
  RECT work_area{};
  if (!has_anchor_ || !WorkAreaOf(MonitorForStrip(window_), &work_area)) {
    // Nothing to resolve against. The caller keeps the frame it has, which is
    // where the menu already is.
    RECT current{};
    if (window_ != nullptr) {
      ::GetWindowRect(window_, &current);
    }
    return current;
  }
  return ResolveInputMenuFrame(work_area, anchor_frame_, anchor_x_, width, height,
                               anchor_gap_);
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
  // The fraction to re-resolve this window against is seeded by the caller,
  // which is the only place that knows whether the placement restored a
  // position or fell back to the anchor.
  return true;
}

void OverlayWindows::OverlayWindow::Destroy() {
  // Before anything else is torn down: a drag whose modal loop is still on the
  // stack reads this flag when that loop returns, and everything below is a
  // reason for it not to touch this object again.
  *alive_ = false;
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
  // The region is in window coordinates, so every resize invalidates it. Every
  // path that resizes this window ends here, which makes this the one place it
  // has to be re-applied.
  ApplyPreviewShape();
  // Deliberately does not remember where that put the strip. Every path that
  // moves the window ends here, and most of them are the ground moving under
  // it rather than the user moving it: a clamp that wrote its result back would
  // ratchet the fraction towards the near edge on every taskbar change. Only
  // the paths that are the user's own doing remember, and they say so.
}

void OverlayWindows::OverlayWindow::ApplyPreviewShape() {
  if (role_ != OverlayRole::kCameraPreview || window_ == nullptr) {
    return;
  }
  RECT frame{};
  if (::GetWindowRect(window_, &frame) == FALSE) {
    return;
  }
  const LONG width = frame.right - frame.left;
  const LONG height = frame.bottom - frame.top;
  const double radius =
      geometry_.is_tile
          ? (std::min)(geometry_.camera.corner_radius_ratio * width,
                       (std::min)(width, height) / 2.0)
          : 0.0;
  if (width <= 0 || height <= 0 || !(radius > 0)) {
    // A square tile is the whole window. Clearing the region rather than
    // setting a rectangular one, so a preset changed back leaves nothing
    // behind.
    ::SetWindowRgn(window_, nullptr, TRUE);
    return;
  }
  // Right and bottom are exclusive, so a region that is to include the last row
  // and column is built one larger than the window.
  const int diameter = static_cast<int>(radius * 2.0 + 0.5);
  const HRGN region =
      diameter >= (std::min)(width, height)
          ? ::CreateEllipticRgn(0, 0, width + 1, height + 1)
          : ::CreateRoundRectRgn(0, 0, width + 1, height + 1, diameter, diameter);
  if (region == nullptr) {
    return;
  }
  // SetWindowRgn takes ownership on success and the system frees it; on failure
  // it is still this function's to delete.
  if (::SetWindowRgn(window_, region, TRUE) == 0) {
    ::DeleteObject(region);
  }
}

// The whole drag protocol (spec 33.3), and deliberately not a per-move message
// over the channel: 3 keeps that channel for commands, and the operating system
// already owns a loop that tracks the pointer at the display's own rate.
void OverlayWindows::OverlayWindow::BeginMove() {
  if (window_ == nullptr) {
    return;
  }
  // The button the gesture is being held with — the right one when the user has
  // swapped them, since WM_LBUTTONDOWN comes from the primary button whichever
  // side of the mouse it is on.
  //
  // Asked now rather than when the request was posted: this runs a turn of the
  // message loop later, and a request whose button is already up is dropped. A
  // move loop entered with nothing held is ended by nothing — DefWindowProc
  // tracks the pointer until the *next* press — so the strip would follow the
  // cursor across the desktop until the user clicked to put it down.
  //
  // The refusal for a second request inside the loop the first one started is
  // in the same gate: the modal loop pumps the message queue, so a posted
  // message is dispatched mid-drag, and nesting two loops behind one finger
  // would leave one of them running with nobody's finger down.
  const bool button_down =
      ::GetAsyncKeyState(VK_LBUTTON) < 0 ||
      (::GetSystemMetrics(SM_SWAPBUTTON) != 0 && ::GetAsyncKeyState(VK_RBUTTON) < 0);
  if (!ShouldBeginOverlayMove(draggable(), move_pending_, button_down)) {
    return;
  }
  move_pending_ = true;
  // The strip moving closes whatever sheet is open (spec 33.7), and asking for
  // it before the modal loop is entered is what keeps this off the stack of a
  // loop that can free this object. Host-initiated: the user dragged the strip,
  // not the menu, so nothing has told the application the sheet is gone.
  if (role_ == OverlayRole::kControlStrip && on_dismiss_) {
    on_dismiss_(/*host_initiated=*/true);
  }
  // ReleaseCapture drops the capture the hosted Flutter view took on the press;
  // without it the move loop never sees the mouse. WM_NCLBUTTONDOWN with
  // HTCAPTION then starts that loop on a window that has no caption to click,
  // which is the standard idiom for a borderless one.
  //
  // Nothing clamps *during* the drag, on purpose: a strip held inside the
  // current monitor's usable area could never be dragged onto a second display,
  // which 33.3 allows. The clamp belongs at the end.
  ::ReleaseCapture();
  // A copy of the liveness flag, taken before the loop and read after it. That
  // loop is modal and pumps the platform thread's message queue, which is how
  // Dart's calls into this plugin are delivered: hideControlStrip and dispose
  // can both run inside it and destroy this window — and free this object —
  // while the call below is still on the stack. Nothing may touch a member
  // afterwards without asking this first, because asking any member is already
  // the read that would be too late.
  const std::shared_ptr<bool> alive = alive_;
  // SendMessage is synchronous and the loop it starts is modal, so the drag is
  // over by the time this returns. WM_EXITSIZEMOVE normally gets there first —
  // it is also the end of a move the user started some other way — and this is
  // the fallback for a DefWindowProc that never entered the loop at all.
  ::SendMessageW(window_, WM_NCLBUTTONDOWN, HTCAPTION, 0);
  if (!*alive) {
    return;
  }
  if (move_pending_) {
    FinishMove();
  }
}

void OverlayWindows::OverlayWindow::FinishMove() {
  move_pending_ = false;
  if (window_ == nullptr) {
    return;
  }
  if (role_ == OverlayRole::kCameraPreview) {
    FinishCameraMove();
    return;
  }
  if (role_ != OverlayRole::kControlStrip) {
    return;
  }
  RECT frame{};
  RECT work_area{};
  if (!WindowAndWorkArea(window_, &frame, &work_area)) {
    return;
  }
  const RECT snapped = SnapStripFrame(
      work_area, frame, StripSnapPixels(MonitorScale(MonitorForStrip(window_))));
  // The snap never changes the size, so the corner is the whole comparison.
  // Skipping an unchanged frame keeps a click that crossed the threshold and
  // went nowhere from repainting the hosted view.
  if (snapped.left != frame.left || snapped.top != frame.top) {
    SetFrame(snapped);
  }
  // A drag ending is the one thing that establishes where the user wants the
  // strip, so it is the one thing that rewrites the fraction.
  RememberPosition();
}

RECT OverlayWindows::OverlayWindow::CanvasRectToScreen(const RectD& rect) const {
  const RECT& bounds = geometry_.canvas_bounds;
  const double bounds_width = static_cast<double>(bounds.right - bounds.left);
  const double bounds_height = static_cast<double>(bounds.bottom - bounds.top);
  RECT frame{};
  if (bounds_width <= 0 || bounds_height <= 0 || geometry_.canvas_width <= 0 ||
      geometry_.canvas_height <= 0) {
    return frame;
  }
  const double to_screen_x = bounds_width / geometry_.canvas_width;
  const double to_screen_y = bounds_height / geometry_.canvas_height;
  frame.left = bounds.left + RoundToPixel(rect.x * to_screen_x);
  frame.top = bounds.top + RoundToPixel(rect.y * to_screen_y);
  frame.right = frame.left + RoundToPixel(rect.width * to_screen_x);
  frame.bottom = frame.top + RoundToPixel(rect.height * to_screen_y);
  return frame;
}

bool OverlayWindows::OverlayWindow::PreviewPosition(double* x, double* y) const {
  if (role_ != OverlayRole::kCameraPreview || !geometry_.is_tile ||
      window_ == nullptr || x == nullptr || y == nullptr) {
    // Window mode answers null on purpose: the preview there is a separate
    // captioned object, and reporting its corner as the tile's would move the
    // picture-in-picture to wherever the user parked a window that does not
    // stand for it (design 1e).
    return false;
  }
  const RECT& bounds = geometry_.canvas_bounds;
  const double bounds_width = static_cast<double>(bounds.right - bounds.left);
  const double bounds_height = static_cast<double>(bounds.bottom - bounds.top);
  RECT frame{};
  if (bounds_width <= 0 || bounds_height <= 0 ||
      ::GetWindowRect(window_, &frame) == FALSE) {
    return false;
  }
  return PipPositionRatio(
      (frame.left - bounds.left) * geometry_.canvas_width / bounds_width,
      (frame.top - bounds.top) * geometry_.canvas_height / bounds_height,
      geometry_.canvas_width, geometry_.canvas_height, x, y);
}

void OverlayWindows::OverlayWindow::FinishCameraMove() {
  if (!geometry_.is_tile || window_ == nullptr) {
    return;
  }
  CameraOverlayConfig moved = geometry_.camera;
  if (!PreviewPosition(&moved.position_x, &moved.position_y)) {
    return;
  }
  moved.has_position = true;
  // Through the compositor's own arithmetic, so the window cannot come to rest
  // anywhere the tile could not: clamped to the margin, and snapped onto a
  // corner from within 2% of the canvas width (spec 33.5).
  const PipDraw draw =
      ResolvePipDraw(moved, geometry_.canvas_width, geometry_.canvas_height,
                     geometry_.frame_width, geometry_.frame_height);
  // The settled fraction, read back off the rectangle that resolution landed
  // on: what the host stores and what the compositor draws have to be the same
  // number, or the file and the window disagree by a snap.
  if (!PipPositionRatio(draw.dest.x, draw.dest.y, geometry_.canvas_width,
                        geometry_.canvas_height, &moved.position_x,
                        &moved.position_y)) {
    return;
  }
  const RECT frame = CanvasRectToScreen(draw.dest);
  if (frame.right > frame.left && frame.bottom > frame.top) {
    SetFrame(frame);
  }
  // The moved configuration is deliberately not written back here. This runs on
  // the platform thread without OverlayWindows' lock — a drag cannot take it,
  // because the modal move loop pumps the queue that lock is held across — and
  // `geometry_` is read on the camera thread by PushFrame under exactly that
  // lock. The host writes it instead, through SetCameraPreviewGeometry, on the
  // way back from this call.
  if (on_camera_moved_) {
    on_camera_moved_(moved.position_x, moved.position_y);
  }
}

void OverlayWindows::OverlayWindow::Nudge(LONG dx, LONG dy) {
  if (role_ != OverlayRole::kControlStrip || window_ == nullptr) {
    return;
  }
  RECT frame{};
  RECT work_area{};
  if (!WindowAndWorkArea(window_, &frame, &work_area)) {
    return;
  }
  const RECT moved = NudgeStripFrame(
      work_area, frame, dx, dy,
      StripSnapPixels(MonitorScale(MonitorForStrip(window_))));
  if (moved.left != frame.left || moved.top != frame.top) {
    SetFrame(moved);
  }
  // The keyboard is the user moving the strip exactly as a drag is, so it
  // rewrites the fraction the same way (spec 33.3).
  RememberPosition();
}

void OverlayWindows::OverlayWindow::ClampIntoWorkArea() {
  if (role_ != OverlayRole::kControlStrip || window_ == nullptr) {
    return;
  }
  RECT frame{};
  RECT work_area{};
  if (!WindowAndWorkArea(window_, &frame, &work_area)) {
    return;
  }
  const RECT clamped = ClampToWorkArea(work_area, frame);
  if (clamped.left != frame.left || clamped.top != frame.top) {
    SetFrame(clamped);
  }
  // Reached only for a strip that has no remembered fraction to re-resolve, and
  // it deliberately does not invent one: where a clamp had to put the strip is
  // not somewhere the user chose to put it.
}

void OverlayWindows::OverlayWindow::ReresolveRememberedFraction() {
  if (role_ != OverlayRole::kControlStrip || window_ == nullptr) {
    return;
  }
  if (!has_ratio_) {
    // Nothing proportional to restore; the usable area still moved.
    ClampIntoWorkArea();
    return;
  }
  RECT frame{};
  RECT work_area{};
  if (!WindowAndWorkArea(window_, &frame, &work_area)) {
    return;
  }
  // Against whichever display holds the strip now: when a monitor is
  // disconnected Windows has already moved the window onto a surviving one, and
  // resolving the fraction there is exactly 33.7's "the strip moves to the
  // current display, at its stored fraction there".
  const RECT resolved =
      FractionalStripFrame(work_area, ratio_x_, ratio_y_, frame.right - frame.left,
                           frame.bottom - frame.top);
  if (resolved.left != frame.left || resolved.top != frame.top) {
    SetFrame(resolved);
  }
  // The fraction is the input here, never the output. FractionalStripFrame
  // clamps what it resolves, and measuring the clamped result back would make
  // a display that is briefly smaller — or a taskbar that appeared — a
  // permanent move towards the near edge: the strip would come back to 0.719
  // of a display it was left at 0.80 of, and lose a little more every time.
}

void OverlayWindows::OverlayWindow::RememberPosition() {
  if (role_ != OverlayRole::kControlStrip || window_ == nullptr) {
    return;
  }
  RECT frame{};
  RECT work_area{};
  if (!WindowAndWorkArea(window_, &frame, &work_area)) {
    return;
  }
  // Left as it was when the usable area has no extent to measure against: a
  // fabricated 0, 0 would move the strip to the corner the next time a display
  // change re-resolved it.
  double x = 0;
  double y = 0;
  if (StripPositionRatio(work_area, frame, &x, &y)) {
    has_ratio_ = true;
    ratio_x_ = x;
    ratio_y_ = y;
  }
}

void OverlayWindows::OverlayWindow::RememberRestoredPosition(double x, double y) {
  // A fraction that is not a number is not a position, and the last one is
  // better than a fabricated corner.
  if (role_ != OverlayRole::kControlStrip || std::isnan(x) || std::isnan(y)) {
    return;
  }
  has_ratio_ = true;
  // Into the unit square, the way StripPositionRatio reports one and Dart's
  // OverlayStripPosition.tryFrom stores one. This is the clamp of a *fraction*
  // — idempotent, and the same number back on a display of any size. The
  // ratchet is the other clamp, the one that re-derives a fraction from pixels
  // a shrunken usable area pushed inwards.
  ratio_x_ = (std::min)(1.0, (std::max)(0.0, x));
  ratio_y_ = (std::min)(1.0, (std::max)(0.0, y));
}

bool OverlayWindows::OverlayWindow::RememberedPosition(double* x, double* y) const {
  if (!has_ratio_ || x == nullptr || y == nullptr) {
    return false;
  }
  *x = ratio_x_;
  *y = ratio_y_;
  return true;
}

// Grows the window about its own top-left, to the size the engine measured.
//
// The measurement is in logical points and the frame is in physical pixels, so
// it is scaled by the display the strip is on rather than the one the placement
// was resolved against — and by 33.3's rule for which display that is, the one
// holding the strip's centre, so that the scale and the clamp below cannot end
// up asking two different monitors.
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
  // One monitor for both the scale and the clamp, resolved once: with
  // MonitorFromWindow's largest-intersection rule for the scale and the centre
  // rule for the clamp, a strip straddling a seam would be sized against one
  // display and placed on the other.
  const HMONITOR monitor = MonitorForStrip(window_);
  const double scale = MonitorScale(monitor);
  const LONG measured_width = static_cast<LONG>(width * scale + 0.5);
  const LONG measured_height = static_cast<LONG>(height * scale + 0.5);
  RECT frame = current;
  frame.right = frame.left + measured_width;
  frame.bottom = frame.top + measured_height;
  if (frame.right == current.right && frame.bottom == current.bottom) {
    return;
  }
  if (role_ == OverlayRole::kInputMenu) {
    // The menu is placed, not grown. It may have opened *above* the strip, and
    // a window that grew about its top-left from there would slide down over
    // the strip it belongs to; re-resolving from the anchor puts it on
    // whichever side its real size fits (spec 33.4).
    SetFrame(MenuFrameFor(measured_width, measured_height));
    if (on_content_size_) {
      on_content_size_(width, height);
    }
    return;
  }
  // A strip parked against the right or bottom edge of the usable area would
  // otherwise grow straight out of it: the window grows about its top-left, and
  // 33.3 clamps on every show, not only on the first one.
  RECT work_area{};
  if (role_ == OverlayRole::kControlStrip && WorkAreaOf(monitor, &work_area)) {
    frame = ClampToWorkArea(work_area, frame);
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
  // The part of the frame the compositor is going to draw, resolved by the same
  // call it draws with. The preview shows the crop rather than the whole
  // sensor, because the tile it stands for is the crop (design 1p, spec 33.5).
  // A window-mode preview has no tile, and shows the frame whole.
  uint32_t crop_x = 0;
  uint32_t crop_y = 0;
  uint32_t crop_width = width;
  uint32_t crop_height = height;
  if (geometry_.is_tile) {
    const RectD source =
        ResolvePipDraw(geometry_.camera, geometry_.canvas_width,
                       geometry_.canvas_height, width, height)
            .source;
    // Clamped into the frame that actually arrived: the geometry may describe
    // the camera that was running a moment ago.
    const double left = (std::max)(0.0, source.x);
    const double top = (std::max)(0.0, source.y);
    crop_x = static_cast<uint32_t>(left);
    crop_y = static_cast<uint32_t>(top);
    crop_width = crop_x >= width
                     ? 0
                     : (std::min)(width - crop_x, static_cast<uint32_t>(source.width));
    crop_height =
        crop_y >= height
            ? 0
            : (std::min)(height - crop_y, static_cast<uint32_t>(source.height));
  }
  if (crop_width == 0 || crop_height == 0) {
    return;
  }
  {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    const size_t row_bytes = static_cast<size_t>(crop_width) * 4;
    frame_pixels_.resize(row_bytes * crop_height);
    // The engine uploads a pixel-buffer texture as RGBA8888
    // (external_texture_pixelbuffer.cc), while the camera path is BGRA
    // throughout, so the channels are swapped exactly here — once, on the
    // small preview image, and never on the encoded frame.
    //
    // Alpha is forced opaque rather than copied: the camera frame carries the
    // tile's mask there (video_compositor.h), and the preview's own shape is
    // the window region, not a transparency the unlayered overlay could show
    // anyway.
    for (uint32_t row = 0; row < crop_height; ++row) {
      const uint8_t* source =
          bgra + static_cast<size_t>(row + crop_y) * stride +
          static_cast<size_t>(crop_x) * 4;
      uint8_t* destination = frame_pixels_.data() + row * row_bytes;
      for (uint32_t column = 0; column < crop_width; ++column) {
        destination[column * 4 + 0] = source[column * 4 + 2];
        destination[column * 4 + 1] = source[column * 4 + 1];
        destination[column * 4 + 2] = source[column * 4 + 0];
        destination[column * 4 + 3] = 0xFF;
      }
    }
    frame_width_ = crop_width;
    frame_height_ = crop_height;
  }
  registrar_->texture_registrar()->MarkTextureFrameAvailable(texture_id_);
}

void OverlayWindows::OverlayWindow::HandleCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
  if (call.method_name() == "command") {
    if (arguments != nullptr && on_command_) {
      // The anchor rides on this call rather than on the event channel, so that
      // channel goes on emitting bare command names and a decoder that has not
      // learned the chevrons ignores them (spec 33.4).
      on_command_(StringAt(*arguments, "command"),
                  OptionalDoubleAt(*arguments, "anchorX"));
    }
    result->Success();
    return;
  }
  if (call.method_name() == "chooseInputDevice") {
    if (arguments == nullptr) {
      result->NotImplemented();
      return;
    }
    if (on_menu_selection_) {
      // The map as it arrived. What the choice means is the application's
      // business, not this layer's (spec 33.4).
      on_menu_selection_(*arguments);
    }
    // A device row closes the menu, and asks the host to do it: a window
    // destroyed from inside its own engine's channel callback would free the
    // stack that is running. The camera sheet's shape presets, its corners and
    // `Reset position` leave it open — the tile changes underneath it.
    //
    // Not host-initiated: the choice above is already on its way to the
    // application, which closes the menu itself in response. A dismissal beside
    // it would report the same close twice.
    if (MenuChoiceClosesMenu(OptionalStringAt(*arguments, "preset").has_value(),
                             OptionalStringAt(*arguments, "corner").has_value(),
                             BoolAt(*arguments, "resetPosition", false)) &&
        on_dismiss_) {
      on_dismiss_(/*host_initiated=*/false);
    }
    result->Success();
    return;
  }
  if (call.method_name() == "dismissInputMenu") {
    // Esc, while the menu window happens to hold focus. The application never
    // saw the key — the menu runs in its own engine — so this is a close it has
    // to be told about, and the host reports it as a dismissal on
    // `relay/overlay/events` (spec 33.4).
    if (on_dismiss_) {
      on_dismiss_(/*host_initiated=*/true);
    }
    result->Success();
    return;
  }
  if (call.method_name() == "beginMove") {
    // The strip always, the preview only while it is the tile (design 1p). A
    // window-mode preview drag moves nothing, so nothing is started.
    //
    // Answered as a success rather than NotImplemented: on the Dart side
    // `invokeMethod` turns NotImplemented into a thrown MissingPluginException,
    // and the drag handler calls this unawaited, so the throw would surface as
    // an unhandled async error during an ordinary gesture. The method plainly
    // exists; what does not exist is a window to move. The two also disagree by
    // construction — Dart mounts the handler on `matchesCompositedPip` while
    // `draggable()` additionally requires the recorded display to still be
    // nameable — so this path is reachable in display mode too.
    if (!draggable() || window_ == nullptr) {
      result->Success();
      return;
    }
    // Posted, never run here, for the reason "contentSize" below is: the move
    // loop is modal and this handler is on the engine's own platform thread, so
    // entering it here would hold the channel call — and the Dart side of the
    // gesture — open for as long as the user drags. Posting hands it to the next
    // turn of the message loop, with the mouse button still down.
    if (::PostMessageW(window_, kBeginMoveMessage, 0, 0) == FALSE) {
      // A queue that would not take the message is a drag that will not happen,
      // and the strip asks once per gesture: answering Success would leave the
      // caller waiting for a move loop that was never entered, with no way to
      // tell that from one it is already inside.
      result->Error(ErrorCodeName(RecorderErrorCode::kUnknown),
                    "The overlay could not start a window move.");
      return;
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
  // Observed before the engine gets its refusal, and never consumed: each of
  // these says the ground moved under a window that is already placed, and
  // whether the hosted engine also wants the message is its own business. A
  // clamp that only ran when the engine happened not to handle a broadcast
  // would be a strip left under the taskbar (spec 33.7).
  switch (message) {
    case WM_EXITSIZEMOVE:
      // The authoritative end of a move loop, including one this window did not
      // start itself.
      FinishMove();
      break;
    case WM_DISPLAYCHANGE:
      ReresolveRememberedFraction();
      // The display configuration changed, so the sheet closes (spec 33.4).
      // Raised by whichever window sees it first, and by every other one after
      // it: closing a menu that is already closed is a no-op, and the host
      // reports the dismissal only for the menu it still believes is open.
      if (on_dismiss_) {
        on_dismiss_(/*host_initiated=*/true);
      }
      break;
    case WM_SETTINGCHANGE:
      // A taskbar shown, hidden, resized or moved to another edge. The strip
      // keeps the fraction the user left it at; the usable area it resolves
      // against is what changed — and resolving it again, rather than clamping
      // the pixels, is what brings the strip back when the taskbar goes away.
      if (wparam == static_cast<WPARAM>(SPI_SETWORKAREA)) {
        ReresolveRememberedFraction();
        if (on_dismiss_) {
          on_dismiss_(/*host_initiated=*/true);
        }
      }
      break;
    default:
      break;
  }
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
    case kBeginMoveMessage: {
      // Nothing may follow this that touches a member: the drag runs a modal
      // loop, that loop pumps the queue Dart's calls arrive on, and this window
      // can be destroyed and freed inside it. The return is deliberate.
      BeginMove();
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
