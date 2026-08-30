#ifndef RELAY_RECORDER_TYPES_H_
#define RELAY_RECORDER_TYPES_H_

#include <windows.h>

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

namespace relay {

// Mirrors RecorderErrorCode in recorder_platform_interface. The enumerator name
// is what crosses the channel as PlatformException.code, so the spelling here is
// part of the contract.
enum class RecorderErrorCode {
  kPermissionDenied,
  kSourceUnavailable,
  kSourceClosed,
  kCameraUnavailable,
  kMicrophoneUnavailable,
  kSystemAudioUnavailable,
  kCaptureFailed,
  kEncodingFailed,
  kDiskFull,
  kFinalizationFailed,
  kInvalidState,
  kUnsupported,
  kUnknown,
};

const char* ErrorCodeName(RecorderErrorCode code);

struct RecorderError {
  RecorderErrorCode code = RecorderErrorCode::kUnknown;
  std::string message;
  std::string details;
  // False degrades the session (an optional input dropped out); true ends it.
  bool fatal = true;
};

// Mirrors PlatformRecorderState.
enum class SessionState {
  kIdle,
  kPreparing,
  kPrepared,
  kRecording,
  kPaused,
  kStopping,
  kFinalizing,
  kFinalized,
  kFailed,
};

const char* SessionStateName(SessionState state);

enum class CaptureSourceType { kDisplay, kWindow };

// ── input devices (spec 33.2) ────────────────────────────────────────────────

// Mirrors MediaDeviceKind in recorder_platform_interface. The enumerator name
// is what crosses the channel, so the spelling here is part of the contract.
enum class MediaDeviceKind {
  kCamera,
  kMicrophone,
  // The render endpoint whose output is looped back. Selectable here, where
  // WASAPI loopback is per endpoint; macOS delivers the system mix and has
  // nothing to choose.
  kSystemAudio,
};

// Members of MediaDeviceKind, for the fixed-size tables below.
inline constexpr size_t kMediaDeviceKindCount = 3;

const char* MediaDeviceKindName(MediaDeviceKind kind);

// False for a name this build does not know, leaving `out` untouched.
// Deliberately not a fallback: a decoding mismatch that resolved to any member
// would file a camera under the microphone.
bool MediaDeviceKindFromName(const std::string& name, MediaDeviceKind* out);

// Which kinds offer a choice of device on Windows, and which can report a
// live level. Both cross the wire as capability lists, and the UI reads those
// rather than asking which operating system it is running on (spec 20, 28).
bool IsSelectableDeviceKind(MediaDeviceKind kind);
bool IsMeterableDeviceKind(MediaDeviceKind kind);
std::vector<std::string> SelectableDeviceKindNames();
std::vector<std::string> MeterableDeviceKindNames();

// One enumerated input, before marshalling.
struct MediaDeviceInfo {
  // Opaque and platform-owned: an endpoint id for audio, a Media Foundation
  // symbolic link for a camera. Never parsed by Dart.
  std::string id;
  MediaDeviceKind kind = MediaDeviceKind::kMicrophone;
  // What the user reads. Empty is allowed; Dart substitutes the kind's own
  // word rather than showing a blank row.
  std::string label;
  // The device the platform would use if nothing were chosen. A null device id
  // in the recording configuration means exactly this one.
  bool is_system_default = false;
  // False for a device listed but not openable right now.
  bool is_available = true;
};

// Contract ordering: the system default first, then the platform's own order.
// A rotate rather than a swap, so every other entry keeps its place and a list
// that changes only in which device is default does not reshuffle under the
// user's cursor.
void OrderDevicesDefaultFirst(std::vector<MediaDeviceInfo>* devices);

// The camera list both halves of the plugin have to agree on.
//
// Drops the sources a caller could never choose — a virtual camera with no
// Media Foundation symbolic link has no id, so it can be neither listed nor
// persisted — and marks the first survivor as the default, because Media
// Foundation names no default camera and the recorder opens the first source it
// can name. Enumeration and capture both build their list through this: when
// only one of them dropped the nameless entries, the camera `getInputDevices`
// called the default was not the camera an unconfigured prepare opened.
//
// `source_indices`, when given, receives the enumeration index each survivor
// came from, so a caller holding the enumerated sources can map the selection
// back onto its own array.
void RetainSelectableCameras(std::vector<MediaDeviceInfo>* devices,
                             std::vector<size_t>* source_indices = nullptr);

// No entry: what SelectDeviceIndex answers for an empty list.
inline constexpr size_t kNoDeviceIndex = static_cast<size_t>(-1);

// Which enumerated device a configured id selects: the requested one while it
// still resolves, otherwise the system default, otherwise the first entry.
// A stale id therefore degrades to the default and never fails prepare — a
// wrong microphone is a degraded recording, a refused prepare is no recording
// at all.
size_t SelectDeviceIndex(const std::vector<MediaDeviceInfo>& devices,
                         const std::string& requested_id);

// A metering sample for one input: linear amplitude in [0, 1], never decibels
// and never a buffer. Raw media stays native (spec 3); this is a measurement of
// it, which is what a level bar needs.
struct InputLevelSample {
  double peak = 0;
  double rms = 0;
};

// Clamped to [0, 1]. A value above full scale is clipping, and the bar has
// nowhere to draw it past the end. Also maps NaN to silence.
double ClampUnitLevel(double value);

enum class PipCorner { kTopLeft, kTopRight, kBottomLeft, kBottomRight };

PipCorner PipCornerFromName(const std::string& name);

// The three shapes and sizes the tile comes in (spec 33.5). Mirrors
// CameraPipPreset in recorder_platform_interface; the enumerator name is what
// crosses the channel, so the spelling here is part of the contract.
enum class CameraPipPreset { kCamera, kSquare, kCircle };

const char* CameraPipPresetName(CameraPipPreset preset);

// An unknown name is the `camera` preset — the default, and the behaviour that
// shipped before presets existed. A fallback rather than a refusal here, and
// deliberately unlike MediaDeviceKindFromName: a preset nobody recognises still
// has to draw a picture-in-picture, and the one it draws is the one that crops
// nothing.
CameraPipPreset CameraPipPresetFromName(const std::string& name);

// How the camera frame fills its tile (spec 33.5).
enum class CameraPipFit {
  // The whole frame, letterboxed if the tile is a different shape. Nothing is
  // lost.
  kContain,
  // The centre of the frame, cropped to the tile's shape. Something is lost,
  // and the user asked for it by choosing a shape the camera is not.
  kCover,
};

const char* CameraPipFitName(CameraPipFit fit);
CameraPipFit CameraPipFitFromName(const std::string& name);

// The bounds spec 33.5 states, mirrored from CameraOverlayConfiguration in
// Dart. A tile below the floor cannot be read; one above the ceiling is no
// longer picture-in-picture.
inline constexpr double kCameraPresetWidthCap = 0.16;
inline constexpr double kSmallPresetWidthRatio = 0.10;
inline constexpr double kMinPipWidthRatio = 0.08;
inline constexpr double kMaxPipWidthRatio = 0.50;
// The roundest a tile can be, as a fraction of its own width: at exactly half
// the width of a square tile the rounded rectangle is a circle, and there is no
// shape beyond it. Mirrors the assertion CameraOverlayConfiguration makes in
// Dart, so a ratio that arrives out of range is clamped rather than drawn.
inline constexpr double kMaxCornerRadiusRatio = 0.50;
// How close to a corner the tile snaps, as a fraction of canvas width.
inline constexpr double kPipSnapRatio = 0.02;

// Camera picture-in-picture geometry. Every value is configuration pushed from
// Dart; the compositor must not hard-code any of it (spec 7, 28).
struct CameraOverlayConfig {
  CameraPipPreset preset = CameraPipPreset::kCamera;
  double width_ratio = kCameraPresetWidthCap;
  // The tile's shape when the camera's own shape is unknown, or when
  // follows_source_aspect_ratio is off.
  double aspect_ratio = 16.0 / 9.0;
  // Give the tile the camera's own shape. A differently shaped tile can only be
  // filled by cropping the frame or stretching it; taking the camera's shape
  // removes the choice (spec 7).
  bool follows_source_aspect_ratio = true;
  // Corner radius as a fraction of the tile's *width*; 0.5 is a circle. A ratio
  // and not pixels, because one configuration has to describe the same shape on
  // a 720p and a 1080p canvas (spec 33.5).
  double corner_radius_ratio = 0.0;
  double margin_ratio = 0.01;
  PipCorner corner = PipCorner::kBottomRight;
  CameraPipFit fit = CameraPipFit::kContain;
  // The tile's top-left as a fraction of the canvas. False is not "unset": it
  // is a live reference to `corner`, so a canvas that changes shape keeps the
  // tile in the corner rather than at whatever fraction that corner used to be.
  bool has_position = false;
  double position_x = 0;
  double position_y = 0;
  bool mirror_preview = true;
  bool mirror_output = false;
};

enum class AspectRatioPolicy { kContainWithinPreset, kLetterboxIntoReferenceCanvas };

// Only one policy exists; spec 4.4/30.3 is still open.
enum class GeometryChangePolicy { kFixedCanvasLetterbox };

struct CompositionConfig {
  AspectRatioPolicy aspect_policy = AspectRatioPolicy::kContainWithinPreset;
  GeometryChangePolicy geometry_policy = GeometryChangePolicy::kFixedCanvasLetterbox;
};

struct RecordingConfig {
  std::string source_id;
  CaptureSourceType source_type = CaptureSourceType::kDisplay;
  uint32_t source_width = 0;
  uint32_t source_height = 0;
  std::string recording_id;
  std::wstring output_directory;
  std::string quality;
  uint32_t target_height = 720;
  uint32_t frame_rate = 30;
  bool camera_enabled = false;
  bool microphone_enabled = true;
  bool system_audio_enabled = true;
  bool show_cursor = true;
  // Chosen input devices, or empty for the platform's own default — which is
  // exactly what this plugin opened before device selection existed, so an
  // unconfigured session records what it always recorded (spec 33.2).
  std::string camera_device_id;
  std::string microphone_device_id;
  std::string system_audio_device_id;
  CameraOverlayConfig camera;
  CompositionConfig composition;

  std::wstring PartPath() const;
  std::wstring FinalPath() const;
};

struct RectD {
  double x = 0;
  double y = 0;
  double width = 0;
  double height = 0;
};

// The width the tile is drawn at, as a fraction of the canvas (spec 33.5).
//
// `source_width` is the camera's own width in pixels, 0 when nothing has been
// captured yet. On the `camera` preset it lowers the width so a small sensor is
// never upscaled past its own pixels; it does nothing to the fixed presets,
// whose size is the point. Mirrors
// CameraOverlayConfiguration.effectiveWidthRatio.
double EffectivePipWidthRatio(const CameraOverlayConfig& config, double canvas_width,
                              uint32_t source_width);

// Pure geometry, shared by the compositor and the preview placement so the
// picture-in-picture the user sees matches the one in the file.
// source_aspect_ratio is the camera's own width/height; 0 means unknown, in
// which case the configured fallback aspect ratio is used.
//
// The result is always fully inside the canvas and never closer to an edge than
// the margin, whatever `position_x`/`position_y` said — the bounds live here
// rather than in whatever dragged the tile, so they hold however the value
// arrived. A free position that stops within kPipSnapRatio of a margin lands on
// it exactly (spec 33.5). Mirrors CameraOverlayConfiguration.resolveRect.
RectD ResolvePipRect(const CameraOverlayConfig& config, double canvas_width,
                     double canvas_height, double source_aspect_ratio = 0,
                     uint32_t source_width = 0);

// The fraction a tile at `left`, `top` on this canvas would be stored as: the
// inverse of ResolvePipRect's free branch, so a drag that reports pixels can be
// turned back into a position that survives a canvas of another size.
//
// False when the canvas has no extent to measure against — a fraction of
// nothing says nothing, and the caller must keep whatever it had rather than
// report a position of 0, 0. That is the null cameraPreviewPosition asks for.
bool PipPositionRatio(double left, double top, double canvas_width,
                      double canvas_height, double* out_x, double* out_y);

// One drawn picture-in-picture: which part of the camera frame is read, where
// on the canvas it lands, and the corner radius of the mask between them.
//
// The single authority for both the composited tile and the preview window, so
// a circle in the preview cannot be a square in the file (design 1p, 33.7's
// "Preview and output disagree about the crop").
struct PipDraw {
  // The part of the camera frame that reaches the canvas, in frame pixels. The
  // whole frame under kContain; the centred crop of the tile's shape under
  // kCover.
  RectD source;
  // Where it is drawn, in canvas pixels.
  RectD dest;
  // In canvas pixels, never more than half the shorter side of `dest` — at
  // exactly half of a square tile it is a circle.
  double corner_radius = 0;
};

PipDraw ResolvePipDraw(const CameraOverlayConfig& config, double canvas_width,
                       double canvas_height, uint32_t frame_width,
                       uint32_t frame_height);

// What the preview window is told to draw its texture as — the three fields of
// `cameraPreviewState` only the host can resolve (spec 33.5,
// platform-channel-contract "relay/overlay/view").
//
// Dart has neither the camera's own shape nor the encoder canvas, so it cannot
// work out either the shape of the picture it is being handed or the crop and
// mask the preset asks for. Design 1p promises the preview *is* the composited
// picture-in-picture, and a circle on screen with a square in the file is the
// defect that promise exists to prevent.
struct CameraPreviewDraw {
  // The shape the texture the host is pushing actually has, which is not always
  // the camera's: in display mode the frame is cropped to the tile before it is
  // uploaded, so the preview draws it at the tile's shape.
  double aspect_ratio = 16.0 / 9.0;
  // The shape of the BOX the picture is drawn into, where `aspect_ratio` is the
  // shape of the texture. Equal in display mode, where the window is the tile;
  // in window mode the texture is the whole camera frame while the box is the
  // tile's — 1:1 for Square and Circle.
  double pip_aspect_ratio = 16.0 / 9.0;
  CameraPipFit fit = CameraPipFit::kContain;
  double corner_radius_ratio = 0.0;
};

// `is_tile` is the resolved answer OverlayWindows crops frames by — display
// mode *and* a recorded display that can still be named — not merely the source
// type, because the two halves have to describe the same picture.
//
// The preset's crop and mask travel in BOTH modes: the compositor applies them
// whatever the source is, so a preview that ignored them in window mode showed
// the same picture for all three presets while the file differed. What the mode
// decides is which box they are applied to — the whole window in display mode,
// and the picture inside a captioned panel in window mode, where the panel keeps
// its own rectangle and caption (design 1e).
CameraPreviewDraw ResolveCameraPreviewDraw(const CameraOverlayConfig& config,
                                           bool is_tile, const PipDraw& draw,
                                           uint32_t frame_width,
                                           uint32_t frame_height);

// The alpha mask baked into a camera frame before it is uploaded, in *camera
// frame* pixels (video_compositor.h explains why the mask travels in the frame's
// alpha channel rather than as a mask texture).
//
// The crop always has the tile's shape, so one scale maps the tile onto the
// frame on both axes and a circle inscribed in the tile is a circle inscribed in
// the crop.
struct CameraFrameMask {
  RectD crop;
  double corner_radius = 0;
};

CameraFrameMask ResolveCameraFrameMask(const CameraOverlayConfig& config,
                                       double canvas_width, double canvas_height,
                                       uint32_t frame_width, uint32_t frame_height);

// How much of the pixel centred on `x`, `y` the mask covers, in [0, 1].
//
// A rounded mask ramps across one pixel at its boundary rather than cutting
// hard: a hard cut leaves a circle drawn as a staircase, and the alpha channel
// this lands in carries the coverage for nothing. A rectangular one cuts hard,
// because its edge is the tile's own edge and nothing is being shaped.
double CameraMaskCoverage(const CameraFrameMask& mask, double x, double y);

// Writes one scanline's coverage into the alpha byte of each pixel of `bgra`,
// which holds `width` BGRA pixels and is left otherwise untouched.
//
// A row at a time and not a pixel at a time because the only expensive part of
// a rounded rectangle is its corners: every row is one fully covered span with
// at most a pixel of ramp at each end, and finding that span costs one square
// root for the row rather than one for every pixel in it. Same arithmetic as
// CameraMaskCoverage, which is asserted rather than assumed.
void ApplyCameraMaskRow(const CameraFrameMask& mask, double y, uint32_t width,
                        uint8_t* bgra);

// True when the mask takes a plain rectangle out of the frame, which is every
// preset but the circle — and the case the compositor draws without asking
// anything of the frame's alpha channel at all.
bool CameraMaskIsRectangular(const CameraFrameMask& mask);

// Largest centred rectangle of the source aspect ratio that fits the canvas.
// Produces the letterbox/pillarbox bars required by fixedCanvasLetterbox.
RectD LetterboxRect(double source_width, double source_height,
                    double canvas_width, double canvas_height);

// Encoded canvas for a source under a quality preset, mirroring
// VideoCompositionConfiguration.resolveCanvasSize in Dart. Even dimensions:
// H.264 4:2:0 chroma subsampling requires it.
void ResolveCanvasSize(const CompositionConfig& composition, uint32_t source_width,
                       uint32_t source_height, uint32_t target_height,
                       uint32_t* out_width, uint32_t* out_height);

// ── the movable control strip (spec 33.3) ────────────────────────────────────
//
// Pure geometry in the physical pixels MONITORINFO reports, kept here so ctest
// executes it rather than only a person with two monitors
// (docs/adr/2026-08-30-movable-control-strip-and-input-menus.md). Every
// rectangle is measured against MONITORINFO.rcWork, never rcMonitor: the usable
// area is what keeps the taskbar uncovered (spec 6, 33.3).

// How close to a usable-area edge, or to that area's horizontal centre, a drag
// has to end for the strip to land exactly on it. Logical points; the pixel
// distance on a given monitor is StripSnapPixels.
inline constexpr double kStripSnapPoints = 24.0;

// kStripSnapPoints in physical pixels on a monitor at `scale`. A non-positive
// or NaN scale reads as 1.0 rather than collapsing the snap to nothing.
LONG StripSnapPixels(double scale);

// Whether `work_area` is an area a strip can be placed in at all.
//
// GetMonitorInfoW leaves its MONITORINFO zeroed when it fails — a monitor
// removed between the check that it was live and the read — and a usable area
// of no extent is not a very small screen: everything below would resolve
// against it and put the strip at the virtual desktop's origin, which on a
// multi-monitor desktop need not be on a display at all.
bool IsUsableWorkArea(const RECT& work_area);

// Whether a choice made in the input menu closes the sheet (spec 33.4).
//
// A device row does, the `Off` row included: the choice is made and the window
// has done its job. The camera sheet's three extra answers do not — a shape
// preset, a corner and `Reset position` all change the tile on screen
// *underneath* the sheet, and comparing them should not cost a reopen each
// time — so the host forwards them and leaves the window exactly where it is. A
// close that did not happen also raises no dismissal: there is nothing for the
// application to stop believing.
bool MenuChoiceClosesMenu(bool has_preset, bool has_corner, bool resets_position);

// How far the input menu sits from the strip it hangs off, in logical points.
inline constexpr double kInputMenuGapPoints = 6.0;

// Whether a beginMove that has reached the front of the message queue should
// still be handed to the operating system's move loop (spec 33.3, 33.5).
//
// `button_down` is the state of the pointer's button now, not when the gesture
// was posted: the request is acted on a later turn of the loop, and by then the
// user may have let go. A move loop entered with nothing held has nothing to
// end it — the platform tracks the pointer until the *next* press — so the
// window would follow the cursor across the desktop until the user clicked.
//
// `draggable` is the strip always, and the camera preview only in display mode,
// where the preview *is* the picture-in-picture (design 1p). In window mode the
// preview is a separate captioned object and dragging it would move a window
// that stands for nothing (design 1e).
bool ShouldBeginOverlayMove(bool draggable, bool move_in_flight, bool button_down);

// Moves `frame` back inside `work_area`, keeping its size.
//
// A strip larger than the usable area is pinned to the left/top edge rather
// than centred on it: the controls are laid out from there, so that is the half
// worth keeping reachable.
RECT ClampToWorkArea(const RECT& work_area, const RECT& frame);

// The frame for a remembered fraction of `work_area`, clamped into it.
//
// `x`/`y` are the top-left as a fraction of the usable area's width and height.
// A fraction outside [0, 1] is clamped rather than refused, exactly as
// OverlayStripPosition.tryFrom does in Dart: a fraction slightly outside the
// unit square is a rounding artefact of a resolution change, not a lost spot.
RECT FractionalStripFrame(const RECT& work_area, double x, double y, LONG width,
                          LONG height);

// Where `frame`'s top-left sits as a fraction of `work_area`, each in [0, 1].
//
// False when the usable area has no extent to measure against — a fraction of
// nothing says nothing, and the caller must keep whatever it had rather than
// report a position of 0, 0. That is the null the controlStripPosition contract
// asks for.
bool StripPositionRatio(const RECT& work_area, const RECT& frame, double* out_x,
                        double* out_y);

// Where a drag ends: on a usable-area edge or on that area's horizontal centre
// when the frame stopped within `snap` pixels of one, and inside the usable
// area either way.
//
// The nearest candidate wins, and the clamp is applied after the snap, so a
// snap that would push a strip wider than the usable area off the edge cannot.
// Idempotent: an already-snapped frame finds its own edge at distance zero.
RECT SnapStripFrame(const RECT& work_area, const RECT& frame, LONG snap);

// The keyboard path onto the same arithmetic (spec 33.3): move by `dx`, `dy`
// physical pixels, then snap and clamp exactly as the end of a drag does, so
// arrow keys and a pointer cannot leave the strip in two different places.
RECT NudgeStripFrame(const RECT& work_area, const RECT& frame, LONG dx, LONG dy,
                     LONG snap);

// Where the input menu goes: below the strip when there is room under it, above
// it otherwise, horizontally centred on the control that asked for it, and
// clamped to the usable area (spec 33.4).
//
// `anchor_frame` is the strip's frame and `anchor_x` the pressed control's
// centre, both in screen pixels — only Flutter knows where a control ended up
// inside the strip, so the x travels in from there (relay/overlay/view's
// `anchorX`). `gap` is the distance between the strip and the menu.
//
// Neither side fitting means the menu is taller than the usable area; it then
// takes the space below and is clamped, because a menu overlapping the strip is
// legible and a menu off the screen is not.
RECT ResolveInputMenuFrame(const RECT& work_area, const RECT& anchor_frame,
                           LONG anchor_x, LONG width, LONG height, LONG gap);

std::wstring Widen(const std::string& utf8);
std::string Narrow(const std::wstring& wide);
std::string HResultToString(HRESULT hr);
std::wstring JoinPath(const std::wstring& directory, const std::wstring& leaf);

// Monotonic clock. QueryPerformanceCounter only: wall-clock time is never used
// for media timing (spec 8, 22).
//
// Everything downstream works in 100 ns units since boot, which is the base
// Direct3D11CaptureFrame::SystemRelativeTime and the WASAPI QPC positions
// already report, so video and audio share one timeline without conversion.
int64_t QpcNow();
int64_t QpcFrequency();
int64_t QpcTo100ns(int64_t qpc_ticks);
int64_t Now100ns();

// Session timeline. Paused intervals are subtracted, so the encoded duration
// equals the elapsed time the control strip shows (spec 9, design 1g).
class SessionClock {
 public:
  void Start(int64_t now_100ns);
  void Pause(int64_t now_100ns);
  void Resume(int64_t now_100ns);
  void Stop(int64_t now_100ns);
  bool running() const;
  bool paused() const;
  // Media time in 100 ns units, or -1 while paused/stopped: samples captured
  // during a paused interval have no place on the output timeline.
  int64_t MediaTime100ns(int64_t capture_100ns) const;
  int64_t ElapsedMs() const;

 private:
  mutable std::mutex mutex_;
  bool running_ = false;
  bool paused_ = false;
  int64_t start_100ns_ = 0;
  int64_t pause_started_100ns_ = 0;
  int64_t paused_total_100ns_ = 0;
  int64_t stopped_media_100ns_ = -1;
};

// Peak and RMS for one input, filled by whichever thread captures the audio and
// drained by the meter at ~20 Hz (spec 33.2).
//
// Disabled until something is metering, so a capture nobody is watching does no
// level arithmetic at all, and marked live for as long as a capture holds the
// device — the meter then reads its levels from here instead of opening a
// second handle on a device the session already has open. Safe from any thread.
class LevelAccumulator {
 public:
  // Switching either flag off discards the interval in progress, so a meter
  // switched back on never opens on a stale peak.
  void SetEnabled(bool enabled);
  bool enabled() const;
  void SetLive(bool live);
  bool live() const;

  // Interleaved linear PCM. A null block with a non-zero count records that
  // many silent samples: silence is a level, not the absence of one, and a
  // pause between words has to pull the bar down.
  void Add(const float* samples, size_t count);

  // The level accumulated since the previous call, and the start of a fresh
  // interval. Silence when nothing was added.
  InputLevelSample Take();

 private:
  mutable std::mutex mutex_;
  bool enabled_ = false;
  bool live_ = false;
  double peak_ = 0;
  double square_sum_ = 0;
  uint64_t samples_ = 0;
};

// Reference-counted metering taps (spec 33.2): two callers make one tap, and
// the tap closes when the last one stops. Never a stack — a stop with nothing
// running is a no-op, not an error.
class MeteringSubscriptions {
 public:
  // True when this call took the first reference for the kind, which is the
  // caller's cue to open the tap.
  bool Retain(MediaDeviceKind kind);
  // True when this call dropped the last one, which is the cue to close it.
  bool Release(MediaDeviceKind kind);
  bool IsActive(MediaDeviceKind kind) const;
  bool AnyActive() const;
  // Drops every reference, reporting whether anything was open. A tap must not
  // outlive the recorder that owns it.
  bool Clear();

 private:
  mutable std::mutex mutex_;
  int counts_[kMediaDeviceKindCount] = {0, 0, 0};
};

// The device a meter is pointed at (spec 33.2).
//
// Metering carries a device id because the bar sits under a device row: a meter
// showing the system default while the user is choosing between two microphones
// answers a question nobody asked. An empty id is the platform default — the
// same meaning it has on RecordingConfig.
//
// Guarded by its owner rather than by itself: the meter takes one lock over
// this and the wait its thread makes, so a re-point cannot land between the two
// and be slept through.
class MeterTarget {
 public:
  // Points the tap at `device_id`, empty for the platform default. True when
  // that moved it — which is the caller's cue to wake its thread, because an
  // open tap on the old device now has to be re-pointed. Pointing at the device
  // it is already on is a no-op: a second meter on one microphone shares the
  // tap rather than opening a second one.
  bool Point(const std::string& device_id);

  // Drops the tap without changing the device. What a device-list change calls,
  // so the next tick resolves the default again instead of going on metering
  // the microphone that used to be it.
  void Reopen();

  // True while a tap has to be opened before a level can be read.
  bool wants_open() const { return !open_; }

  // The device to open, empty for the platform default.
  const std::string& device_id() const { return device_id_; }

  // A tap is open. Nothing opens again until the device changes, a device-list
  // change asks for it, or the tap is lost.
  void NoteOpened() { open_ = true; }

  // The tap is gone: closed on purpose, or it stopped delivering.
  void NoteClosed() { open_ = false; }

 private:
  std::string device_id_;
  bool open_ = false;
};

// Backs off a retry that keeps failing (spec 33.2).
//
// The meter ticks at a fixed interval while it has an endpoint. With no capture
// endpoint at all that tick is a fresh CoCreateInstance and
// GetDefaultAudioEndpoint every 50 ms, for as long as a meter nothing can feed
// stays on screen. Doubling to a ceiling keeps a machine with no microphone
// from paying for a bar that cannot move, and still notices the microphone that
// is finally plugged in.
class RetryBackoff {
 public:
  RetryBackoff(std::chrono::milliseconds first, std::chrono::milliseconds ceiling);

  // The delay to wait before the next attempt, doubling on each call up to the
  // ceiling.
  std::chrono::milliseconds Next();

  // Back to the first delay: something worked.
  void Reset();

 private:
  const std::chrono::milliseconds first_;
  const std::chrono::milliseconds ceiling_;
  std::chrono::milliseconds current_;
};

// Collapses a burst of raw device notifications into one event (spec 33.2).
//
// Windows raises an IMMNotificationClient callback per endpoint and per role,
// so one headset arriving is about ten of them. Dart answers each with three
// getInputDevices calls, and thirty tasks on a sixteen-slot reject-newest queue
// is the user's next Record answered with "The recorder is busy". One event per
// burst is also the only honest reading: the list changed once.
//
// Trailing edge, so the enumeration that follows sees the settled list rather
// than the machine mid-plug. `ceiling` bounds a device that never settles: a
// flapping endpoint still reports, just no faster than that.
//
// Guarded by its owner, for the same reason MeterTarget is: the watcher holds
// one lock over this and the wait its thread makes, so a notification cannot
// arrive between the two.
class ChangeCoalescer {
 public:
  ChangeCoalescer(int64_t window_ms, int64_t ceiling_ms);

  // Records a raw notification that arrived at `now_ms`.
  void Note(int64_t now_ms);

  // Whether a notification is waiting to be delivered.
  bool pending() const { return pending_; }

  // Milliseconds still to wait before the pending notification is due. Zero
  // when it is due now, and zero when nothing is pending at all — the caller
  // waits to be woken instead.
  int64_t WaitMs(int64_t now_ms) const;

  // Takes the pending notification once it is due. False while the burst is
  // still running, and false when there was nothing to take.
  bool Take(int64_t now_ms);

 private:
  const int64_t window_ms_;
  const int64_t ceiling_ms_;
  bool pending_ = false;
  int64_t first_ms_ = 0;
  int64_t last_ms_ = 0;
};

// Bounded producer/consumer queue with an explicit drop-oldest policy.
//
// Capacity is supplied by the owner and documented at each call site. When the
// queue is full the oldest element is discarded and the drop counter advances,
// so a slow consumer costs frames rather than memory (spec 22, media-pipeline
// "Backpressure").
template <typename T>
class BoundedQueue {
 public:
  explicit BoundedQueue(size_t capacity) : capacity_(capacity) {}

  // Returns false when an element had to be dropped to make room.
  bool Push(T value) {
    bool dropped = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (closed_) {
        // The element is lost exactly like an overflow drop, so it is counted
        // like one: a queue that swallows elements silently cannot be
        // diagnosed from the stats.
        ++dropped_;
        return false;
      }
      while (items_.size() >= capacity_) {
        items_.pop_front();
        ++dropped_;
        dropped = true;
      }
      items_.push_back(std::move(value));
    }
    cv_.notify_one();
    return !dropped;
  }

  bool Pop(T* out, std::chrono::milliseconds timeout) {
    std::unique_lock<std::mutex> lock(mutex_);
    if (!cv_.wait_for(lock, timeout, [this] { return closed_ || !items_.empty(); })) {
      return false;
    }
    if (items_.empty()) {
      return false;
    }
    *out = std::move(items_.front());
    items_.pop_front();
    return true;
  }

  bool TryPop(T* out) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (items_.empty()) {
      return false;
    }
    *out = std::move(items_.front());
    items_.pop_front();
    return true;
  }

  void Close() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      closed_ = true;
    }
    cv_.notify_all();
  }

  void Clear() {
    std::lock_guard<std::mutex> lock(mutex_);
    items_.clear();
  }

  // Re-arms a closed queue for a new session: Close() is permanent otherwise,
  // and every later Push would be refused. Empties the queue and resets the
  // per-session drop counter with it.
  void Reopen() {
    std::lock_guard<std::mutex> lock(mutex_);
    items_.clear();
    dropped_ = 0;
    closed_ = false;
  }

  size_t size() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return items_.size();
  }

  // Asked by a producer that has to allocate a resource before it can push, so
  // the resource is never committed to an element the queue cannot take.
  bool full() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return closed_ || items_.size() >= capacity_;
  }

  uint64_t dropped() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return dropped_;
  }

  bool closed() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return closed_;
  }

 private:
  mutable std::mutex mutex_;
  std::condition_variable cv_;
  std::deque<T> items_;
  const size_t capacity_;
  uint64_t dropped_ = 0;
  bool closed_ = false;
};

// Marshals work back onto the Flutter platform thread.
//
// Channel replies and event-sink pushes are only legal there, while capture,
// encoding and enumeration all run on worker threads. Backed by a message-only
// window created on the platform thread, so the existing Win32 message loop
// drains it.
class PlatformDispatcher {
 public:
  PlatformDispatcher();
  ~PlatformDispatcher();

  PlatformDispatcher(const PlatformDispatcher&) = delete;
  PlatformDispatcher& operator=(const PlatformDispatcher&) = delete;

  // Safe from any thread. Work posted after Shutdown() is discarded.
  void Post(std::function<void()> work);
  void Shutdown();

 private:
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam);
  void Drain();

  HWND window_ = nullptr;
  std::mutex mutex_;
  std::vector<std::function<void()>> pending_;
  bool shutting_down_ = false;
};

}  // namespace relay

#endif  // RELAY_RECORDER_TYPES_H_
