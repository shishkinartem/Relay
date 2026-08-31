#include "recorder_types.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <sstream>

namespace relay {

namespace {

constexpr UINT kRunWorkMessage = WM_APP + 0x41;
constexpr wchar_t kDispatcherClassName[] = L"RelayRecorderDispatcherWindow";

// Every member of MediaDeviceKind, in declaration order. The capability lists
// and the name lookup share it, so a new kind cannot be added to one and
// forgotten in the other.
constexpr MediaDeviceKind kAllMediaDeviceKinds[kMediaDeviceKindCount] = {
    MediaDeviceKind::kCamera,
    MediaDeviceKind::kMicrophone,
    MediaDeviceKind::kSystemAudio,
};
static_assert(static_cast<size_t>(MediaDeviceKind::kSystemAudio) + 1 ==
                  kMediaDeviceKindCount,
              "MeteringSubscriptions indexes its counters by MediaDeviceKind");

uint32_t EvenAtLeast2(double value) {
  const int rounded = static_cast<int>(value + 0.5);
  const int clamped = (std::max)(2, rounded);
  return static_cast<uint32_t>((clamped % 2 == 0) ? clamped : clamped - 1);
}

LONG RectWidth(const RECT& rect) {
  return rect.right - rect.left;
}

LONG RectHeight(const RECT& rect) {
  return rect.bottom - rect.top;
}

// `fraction` of `extent`, with the fraction clamped to [0, 1]. Written as a
// failed `> 0` rather than a `< 0`, so a NaN from a malformed stored position
// reads as the near edge instead of propagating into a window rectangle.
LONG ScaleFraction(double fraction, LONG extent) {
  if (!(fraction > 0) || extent <= 0) {
    return 0;
  }
  const double clamped = fraction > 1 ? 1 : fraction;
  return static_cast<LONG>(clamped * static_cast<double>(extent) + 0.5);
}

// `value` held between `low` and `high`, with a NaN reading as `low`.
//
// Written as failed `>`/`<` tests for the reason ScaleFraction is: a malformed
// ratio that arrived over the channel must land on an edge of the canvas rather
// than propagate into a rectangle nobody can draw.
double ClampDouble(double value, double low, double high) {
  if (!(value > low)) {
    return low;
  }
  return value < high ? value : high;
}

// The first candidate within `distance` of `value`, or `value` when none is.
//
// First rather than nearest, mirroring CameraOverlayConfiguration._snap: the
// two targets are the two margins, and on a canvas narrow enough for both to be
// in range they are the same point anyway.
double SnapToFirst(double value, const double* targets, size_t count,
                   double distance) {
  for (size_t i = 0; i < count; ++i) {
    const double delta = value - targets[i];
    if ((delta < 0 ? -delta : delta) <= distance) {
      return targets[i];
    }
  }
  return value;
}

// Keeps one axis of the tile inside the canvas, margin included.
//
// A tile larger than the canvas is pinned to the near margin rather than
// centred: the leading edge on screen beats a tile that overhangs on both sides.
double ClampPipInside(double value, double extent, double canvas_extent,
                      double margin) {
  const double upper = canvas_extent - margin - extent;
  return upper <= margin ? margin : ClampDouble(value, margin, upper);
}

// One scanline of a camera-frame mask, resolved once for the whole row.
struct MaskRow {
  // Horizontal half-extent of the mask on this row, measured from the crop's
  // centre. Negative when the row lies outside the mask altogether.
  double half = -1;
  // Ramp the edge over a pixel. True for a rounded mask, whose diagonal would
  // otherwise be a staircase; false for a rectangle, whose edge is the tile's
  // own edge and needs no shaping.
  bool soft = false;
};

MaskRow ResolveMaskRow(const CameraFrameMask& mask, double y) {
  MaskRow row;
  const RectD& crop = mask.crop;
  if (crop.width <= 0 || crop.height <= 0) {
    // Nothing to mask: an unconfigured frame is drawn whole.
    row.half = std::numeric_limits<double>::infinity();
    return row;
  }
  const double half_width = crop.width / 2.0;
  const double half_height = crop.height / 2.0;
  const double radius = (std::min)(mask.corner_radius, (std::min)(half_width, half_height));
  const double distance = std::fabs(y - (crop.y + half_height));
  if (!(radius > 0)) {
    row.half = distance <= half_height ? half_width : -1;
    return row;
  }
  row.soft = true;
  const double straight = half_height - radius;
  if (distance <= straight) {
    row.half = half_width;
    return row;
  }
  // In the corner band the edge follows the circle: one square root gives the
  // row's whole extent.
  const double reach = radius * radius - (distance - straight) * (distance - straight);
  row.half = reach > 0 ? half_width - radius + std::sqrt(reach) : -1;
  return row;
}

double MaskCoverageAt(const RectD& crop, const MaskRow& row, double x) {
  if (!(row.half >= 0)) {
    return 0.0;
  }
  if (crop.width <= 0 || crop.height <= 0) {
    return 1.0;
  }
  const double centre_x = crop.x + crop.width / 2.0;
  const double low = centre_x - row.half;
  const double high = centre_x + row.half;
  if (!row.soft) {
    return x >= low && x <= high ? 1.0 : 0.0;
  }
  if (x >= low + 0.5 && x <= high - 0.5) {
    return 1.0;
  }
  if (x <= low - 0.5 || x >= high + 0.5) {
    return 0.0;
  }
  return x < centre_x ? x - (low - 0.5) : (high + 0.5) - x;
}

// The candidate nearest `value` within `snap`, or `value` when none is. Ties go
// to the earlier candidate, so the answer does not depend on the order two
// equidistant edges happen to be listed in.
LONG NearestWithin(LONG value, const LONG* candidates, size_t count, LONG snap) {
  LONG best = value;
  LONG best_distance = 0;
  bool found = false;
  for (size_t i = 0; i < count; ++i) {
    const LONG delta = candidates[i] - value;
    const LONG distance = delta < 0 ? -delta : delta;
    if (distance > snap) {
      continue;
    }
    if (!found || distance < best_distance) {
      found = true;
      best = candidates[i];
      best_distance = distance;
    }
  }
  return best;
}

}  // namespace

const char* ErrorCodeName(RecorderErrorCode code) {
  switch (code) {
    case RecorderErrorCode::kPermissionDenied:
      return "permissionDenied";
    case RecorderErrorCode::kSourceUnavailable:
      return "sourceUnavailable";
    case RecorderErrorCode::kSourceClosed:
      return "sourceClosed";
    case RecorderErrorCode::kCameraUnavailable:
      return "cameraUnavailable";
    case RecorderErrorCode::kMicrophoneUnavailable:
      return "microphoneUnavailable";
    case RecorderErrorCode::kSystemAudioUnavailable:
      return "systemAudioUnavailable";
    case RecorderErrorCode::kCaptureFailed:
      return "captureFailed";
    case RecorderErrorCode::kEncodingFailed:
      return "encodingFailed";
    case RecorderErrorCode::kDiskFull:
      return "diskFull";
    case RecorderErrorCode::kFinalizationFailed:
      return "finalizationFailed";
    case RecorderErrorCode::kInvalidState:
      return "invalidState";
    case RecorderErrorCode::kUnsupported:
      return "unsupported";
    case RecorderErrorCode::kUnknown:
      break;
  }
  return "unknown";
}

const char* SessionStateName(SessionState state) {
  switch (state) {
    case SessionState::kIdle:
      return "idle";
    case SessionState::kPreparing:
      return "preparing";
    case SessionState::kPrepared:
      return "prepared";
    case SessionState::kRecording:
      return "recording";
    case SessionState::kPaused:
      return "paused";
    case SessionState::kStopping:
      return "stopping";
    case SessionState::kFinalizing:
      return "finalizing";
    case SessionState::kFinalized:
      return "finalized";
    case SessionState::kFailed:
      break;
  }
  return "failed";
}

PipCorner PipCornerFromName(const std::string& name) {
  if (name == "topLeft") {
    return PipCorner::kTopLeft;
  }
  if (name == "topRight") {
    return PipCorner::kTopRight;
  }
  if (name == "bottomLeft") {
    return PipCorner::kBottomLeft;
  }
  return PipCorner::kBottomRight;
}

const char* CameraPipPresetName(CameraPipPreset preset) {
  switch (preset) {
    case CameraPipPreset::kSquare:
      return "square";
    case CameraPipPreset::kCircle:
      return "circle";
    case CameraPipPreset::kCamera:
      break;
  }
  return "camera";
}

CameraPipPreset CameraPipPresetFromName(const std::string& name) {
  if (name == "square") {
    return CameraPipPreset::kSquare;
  }
  if (name == "circle") {
    return CameraPipPreset::kCircle;
  }
  return CameraPipPreset::kCamera;
}

const char* CameraPipFitName(CameraPipFit fit) {
  switch (fit) {
    case CameraPipFit::kCover:
      return "cover";
    case CameraPipFit::kContain:
      break;
  }
  return "contain";
}

CameraPipFit CameraPipFitFromName(const std::string& name) {
  // `contain` for everything else, which is the fit that crops nothing: an
  // unrecognised name must not take pixels out of the recording.
  return name == "cover" ? CameraPipFit::kCover : CameraPipFit::kContain;
}

const char* MediaDeviceKindName(MediaDeviceKind kind) {
  switch (kind) {
    case MediaDeviceKind::kCamera:
      return "camera";
    case MediaDeviceKind::kSystemAudio:
      return "systemAudio";
    case MediaDeviceKind::kMicrophone:
      break;
  }
  return "microphone";
}

bool MediaDeviceKindFromName(const std::string& name, MediaDeviceKind* out) {
  if (out == nullptr) {
    return false;
  }
  for (const MediaDeviceKind kind : kAllMediaDeviceKinds) {
    if (name == MediaDeviceKindName(kind)) {
      *out = kind;
      return true;
    }
  }
  return false;
}

bool IsSelectableDeviceKind(MediaDeviceKind kind) {
  // All three, and each for its own reason: the microphone is one capture
  // endpoint among several, the camera one Media Foundation source among
  // several, and system audio is a loopback on one render endpoint rather than
  // a single system mix. Written out rather than returning true, so a fourth
  // kind is unselectable until someone decides otherwise.
  switch (kind) {
    case MediaDeviceKind::kCamera:
    case MediaDeviceKind::kMicrophone:
    case MediaDeviceKind::kSystemAudio:
      return true;
  }
  return false;
}

bool IsMeterableDeviceKind(MediaDeviceKind kind) {
  // Only the microphone, on either platform: a camera has no level, and what
  // the machine is playing is not something the user can act on from inside
  // this application.
  return kind == MediaDeviceKind::kMicrophone;
}

std::vector<std::string> SelectableDeviceKindNames() {
  std::vector<std::string> names;
  for (const MediaDeviceKind kind : kAllMediaDeviceKinds) {
    if (IsSelectableDeviceKind(kind)) {
      names.emplace_back(MediaDeviceKindName(kind));
    }
  }
  return names;
}

std::vector<std::string> MeterableDeviceKindNames() {
  std::vector<std::string> names;
  for (const MediaDeviceKind kind : kAllMediaDeviceKinds) {
    if (IsMeterableDeviceKind(kind)) {
      names.emplace_back(MediaDeviceKindName(kind));
    }
  }
  return names;
}

void OrderDevicesDefaultFirst(std::vector<MediaDeviceInfo>* devices) {
  if (devices == nullptr || devices->empty()) {
    return;
  }
  const auto first_default = std::find_if(
      devices->begin(), devices->end(),
      [](const MediaDeviceInfo& device) { return device.is_system_default; });
  if (first_default == devices->end() || first_default == devices->begin()) {
    return;
  }
  std::rotate(devices->begin(), first_default, first_default + 1);
}

void RetainSelectableCameras(std::vector<MediaDeviceInfo>* devices,
                             std::vector<size_t>* source_indices) {
  if (source_indices != nullptr) {
    source_indices->clear();
  }
  if (devices == nullptr) {
    return;
  }
  std::vector<MediaDeviceInfo> selectable;
  selectable.reserve(devices->size());
  for (size_t i = 0; i < devices->size(); ++i) {
    MediaDeviceInfo& device = (*devices)[i];
    if (device.id.empty()) {
      // Without an id a source can be neither selected nor persisted, so it is
      // not one the caller can be offered — and not one a capture may open
      // behind the list's back either.
      continue;
    }
    device.is_system_default = selectable.empty();
    if (source_indices != nullptr) {
      source_indices->push_back(i);
    }
    selectable.push_back(std::move(device));
  }
  *devices = std::move(selectable);
}

size_t SelectDeviceIndex(const std::vector<MediaDeviceInfo>& devices,
                         const std::string& requested_id) {
  if (devices.empty()) {
    return kNoDeviceIndex;
  }
  if (!requested_id.empty()) {
    for (size_t i = 0; i < devices.size(); ++i) {
      if (devices[i].id == requested_id) {
        return i;
      }
    }
  }
  for (size_t i = 0; i < devices.size(); ++i) {
    if (devices[i].is_system_default) {
      return i;
    }
  }
  return 0;
}

double ClampUnitLevel(double value) {
  // Written as a failed `> 0` rather than a `< 0`, so a NaN from a broken
  // device reads as silence instead of propagating into the bar.
  if (!(value > 0)) {
    return 0;
  }
  return value > 1 ? 1 : value;
}

void LevelAccumulator::SetEnabled(bool enabled) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (enabled_ == enabled) {
    return;
  }
  enabled_ = enabled;
  peak_ = 0;
  square_sum_ = 0;
  samples_ = 0;
}

bool LevelAccumulator::enabled() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return enabled_;
}

void LevelAccumulator::SetLive(bool live) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (live_ == live) {
    return;
  }
  live_ = live;
  peak_ = 0;
  square_sum_ = 0;
  samples_ = 0;
}

bool LevelAccumulator::live() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return live_;
}

void LevelAccumulator::Add(const float* samples, size_t count) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!enabled_ || count == 0) {
    return;
  }
  if (samples == nullptr) {
    samples_ += count;
    return;
  }
  for (size_t i = 0; i < count; ++i) {
    const double value = static_cast<double>(samples[i]);
    const double magnitude = value < 0 ? -value : value;
    if (magnitude > peak_) {
      peak_ = magnitude;
    }
    square_sum_ += value * value;
  }
  samples_ += count;
}

InputLevelSample LevelAccumulator::Take() {
  std::lock_guard<std::mutex> lock(mutex_);
  InputLevelSample sample;
  if (samples_ > 0) {
    sample.peak = ClampUnitLevel(peak_);
    sample.rms =
        ClampUnitLevel(std::sqrt(square_sum_ / static_cast<double>(samples_)));
  }
  peak_ = 0;
  square_sum_ = 0;
  samples_ = 0;
  return sample;
}

bool MeteringSubscriptions::Retain(MediaDeviceKind kind) {
  std::lock_guard<std::mutex> lock(mutex_);
  return ++counts_[static_cast<size_t>(kind)] == 1;
}

bool MeteringSubscriptions::Release(MediaDeviceKind kind) {
  std::lock_guard<std::mutex> lock(mutex_);
  int& count = counts_[static_cast<size_t>(kind)];
  if (count == 0) {
    return false;
  }
  return --count == 0;
}

bool MeteringSubscriptions::IsActive(MediaDeviceKind kind) const {
  std::lock_guard<std::mutex> lock(mutex_);
  return counts_[static_cast<size_t>(kind)] > 0;
}

bool MeteringSubscriptions::AnyActive() const {
  std::lock_guard<std::mutex> lock(mutex_);
  for (const int count : counts_) {
    if (count > 0) {
      return true;
    }
  }
  return false;
}

int MeteringSubscriptions::Total() const {
  std::lock_guard<std::mutex> lock(mutex_);
  int total = 0;
  for (const int count : counts_) {
    total += count;
  }
  return total;
}

ResourceCensus& ResourceCensus::operator+=(const ResourceCensus& other) {
  capture_streams += other.capture_streams;
  camera_sessions += other.camera_sessions;
  microphone_sessions += other.microphone_sessions;
  metering_taps += other.metering_taps;
  meter_subscriptions += other.meter_subscriptions;
  registered_textures += other.registered_textures;
  overlay_engines += other.overlay_engines;
  event_monitors += other.event_monitors;
  session_timers += other.session_timers;
  power_assertions += other.power_assertions;
  writers += other.writers;
  compositors += other.compositors;
  return *this;
}

bool ResourceCensus::session_resources_released() const {
  return capture_streams == 0 && camera_sessions == 0 &&
         microphone_sessions == 0 && metering_taps == 0 &&
         meter_subscriptions == 0 && registered_textures == 0 &&
         event_monitors == 0 && session_timers == 0 && power_assertions == 0 &&
         writers == 0 && compositors == 0;
}

ResourceCensus operator+(ResourceCensus lhs, const ResourceCensus& rhs) {
  lhs += rhs;
  return lhs;
}

bool operator==(const ResourceCensus& lhs, const ResourceCensus& rhs) {
  return lhs.capture_streams == rhs.capture_streams &&
         lhs.camera_sessions == rhs.camera_sessions &&
         lhs.microphone_sessions == rhs.microphone_sessions &&
         lhs.metering_taps == rhs.metering_taps &&
         lhs.meter_subscriptions == rhs.meter_subscriptions &&
         lhs.registered_textures == rhs.registered_textures &&
         lhs.overlay_engines == rhs.overlay_engines &&
         lhs.event_monitors == rhs.event_monitors &&
         lhs.session_timers == rhs.session_timers &&
         lhs.power_assertions == rhs.power_assertions &&
         lhs.writers == rhs.writers && lhs.compositors == rhs.compositors;
}

bool operator!=(const ResourceCensus& lhs, const ResourceCensus& rhs) {
  return !(lhs == rhs);
}

bool MeteringSubscriptions::Clear() {
  std::lock_guard<std::mutex> lock(mutex_);
  bool any = false;
  for (int& count : counts_) {
    any = any || count > 0;
    count = 0;
  }
  return any;
}

bool MeterTarget::Point(const std::string& device_id) {
  if (device_id == device_id_) {
    // Already pointed here: a second meter on the same microphone shares the
    // tap the first one opened, and one still waiting to open goes on waiting.
    return false;
  }
  device_id_ = device_id;
  // A tap open on the device this call pointed away from has to go; one that
  // had not opened yet simply opens on the new device instead.
  open_ = false;
  return true;
}

void MeterTarget::Reopen() {
  open_ = false;
}

RetryBackoff::RetryBackoff(std::chrono::milliseconds first,
                           std::chrono::milliseconds ceiling)
    : first_(first), ceiling_(ceiling), current_(first) {}

std::chrono::milliseconds RetryBackoff::Next() {
  const std::chrono::milliseconds delay = current_;
  current_ = (std::min)(current_ * 2, ceiling_);
  return delay;
}

void RetryBackoff::Reset() {
  current_ = first_;
}

ChangeCoalescer::ChangeCoalescer(int64_t window_ms, int64_t ceiling_ms)
    : window_ms_(window_ms), ceiling_ms_(ceiling_ms) {}

void ChangeCoalescer::Note(int64_t now_ms) {
  if (!pending_) {
    pending_ = true;
    first_ms_ = now_ms;
  }
  last_ms_ = now_ms;
}

int64_t ChangeCoalescer::WaitMs(int64_t now_ms) const {
  if (!pending_) {
    return 0;
  }
  // The quiet window, or whatever is left of the ceiling — whichever expires
  // first, so a device that never settles still reports.
  const int64_t quiet = window_ms_ - (now_ms - last_ms_);
  const int64_t capped = ceiling_ms_ - (now_ms - first_ms_);
  const int64_t remaining = (std::min)(quiet, capped);
  return remaining > 0 ? remaining : 0;
}

bool ChangeCoalescer::Take(int64_t now_ms) {
  if (!pending_ || WaitMs(now_ms) > 0) {
    return false;
  }
  pending_ = false;
  return true;
}

std::wstring RecordingConfig::PartPath() const {
  return JoinPath(output_directory, L"recording-" + Widen(recording_id) + L".part");
}

std::wstring RecordingConfig::FinalPath() const {
  return JoinPath(output_directory, L"recording-" + Widen(recording_id) + L".mp4");
}

double EffectivePipWidthRatio(const CameraOverlayConfig& config, double canvas_width,
                              uint32_t source_width) {
  // Only the `camera` preset takes the camera's own width as a cap; `square`
  // and `circle` are fixed sizes and that is the point of them.
  if (config.preset != CameraPipPreset::kCamera || source_width == 0 ||
      canvas_width <= 0) {
    return ClampDouble(config.width_ratio, kMinPipWidthRatio, kMaxPipWidthRatio);
  }
  const double natural = static_cast<double>(source_width) / canvas_width;
  return ClampDouble(
      ClampDouble(natural, kMinPipWidthRatio, config.width_ratio),
      kMinPipWidthRatio, kMaxPipWidthRatio);
}

RectD ResolvePipRect(const CameraOverlayConfig& config, double canvas_width,
                     double canvas_height, double source_aspect_ratio,
                     uint32_t source_width) {
  const double aspect =
      config.follows_source_aspect_ratio && source_aspect_ratio > 0
          ? source_aspect_ratio
          : config.aspect_ratio;
  RectD rect;
  rect.width =
      canvas_width * EffectivePipWidthRatio(config, canvas_width, source_width);
  // A non-positive fallback is a malformed configuration, not a shape. This
  // used to produce a square tile here and a 0.0001-ratio sliver in
  // CameraOverlayConfiguration.effectiveAspectRatio on macOS, so the same bad
  // input drew a different picture-in-picture on each platform. Both now fall
  // back to the default 16:9.
  const double effective = aspect > 0 ? aspect : 16.0 / 9.0;
  rect.height = rect.width / effective;
  const double margin = canvas_width * config.margin_ratio;
  if (!config.has_position) {
    switch (config.corner) {
      case PipCorner::kTopLeft:
        rect.x = margin;
        rect.y = margin;
        break;
      case PipCorner::kTopRight:
        rect.x = canvas_width - margin - rect.width;
        rect.y = margin;
        break;
      case PipCorner::kBottomLeft:
        rect.x = margin;
        rect.y = canvas_height - margin - rect.height;
        break;
      case PipCorner::kBottomRight:
        rect.x = canvas_width - margin - rect.width;
        rect.y = canvas_height - margin - rect.height;
        break;
    }
    return rect;
  }

  rect.x = ClampPipInside(config.position_x * canvas_width, rect.width, canvas_width,
                          margin);
  rect.y = ClampPipInside(config.position_y * canvas_height, rect.height,
                          canvas_height, margin);
  // "Put it back in the corner" is one gesture rather than a pixel hunt, and a
  // snap can never be the thing that pushes the tile out: the targets are the
  // margins themselves, which the clamp above already found acceptable.
  const double distance = canvas_width * kPipSnapRatio;
  const double lefts[] = {margin, canvas_width - margin - rect.width};
  const double tops[] = {margin, canvas_height - margin - rect.height};
  rect.x = SnapToFirst(rect.x, lefts, sizeof(lefts) / sizeof(lefts[0]), distance);
  rect.y = SnapToFirst(rect.y, tops, sizeof(tops) / sizeof(tops[0]), distance);
  return rect;
}

bool PipPositionRatio(double left, double top, double canvas_width,
                      double canvas_height, double* out_x, double* out_y) {
  if (out_x == nullptr || out_y == nullptr || canvas_width <= 0 ||
      canvas_height <= 0) {
    return false;
  }
  *out_x = ClampDouble(left / canvas_width, 0.0, 1.0);
  *out_y = ClampDouble(top / canvas_height, 0.0, 1.0);
  return true;
}

PipDraw ResolvePipDraw(const CameraOverlayConfig& config, double canvas_width,
                       double canvas_height, uint32_t frame_width,
                       uint32_t frame_height) {
  const double frame_w = static_cast<double>(frame_width);
  const double frame_h = static_cast<double>(frame_height);
  const double source_aspect = frame_height == 0 ? 0 : frame_w / frame_h;
  PipDraw draw;
  draw.dest = ResolvePipRect(config, canvas_width, canvas_height, source_aspect,
                             frame_width);
  draw.source = RectD{0, 0, frame_w, frame_h};
  if (frame_width == 0 || frame_height == 0 || draw.dest.width <= 0 ||
      draw.dest.height <= 0) {
    // Nothing has been captured yet, or the canvas has no room. The tile still
    // has a place — the preview is positioned before the first frame arrives —
    // and there is no crop to resolve for a frame that does not exist.
    return draw;
  }
  if (config.fit == CameraPipFit::kCover) {
    // The largest rectangle of the tile's shape that fits inside the frame,
    // centred: LetterboxRect read the other way round. Everything outside it is
    // what the user gave up by choosing a shape the camera is not.
    draw.source = LetterboxRect(draw.dest.width, draw.dest.height, frame_w, frame_h);
  } else {
    // The whole frame, letterboxed inside the tile. With the `camera` preset the
    // tile already has the frame's shape, so this is the tile exactly.
    RectD fitted =
        LetterboxRect(frame_w, frame_h, draw.dest.width, draw.dest.height);
    fitted.x += draw.dest.x;
    fitted.y += draw.dest.y;
    draw.dest = fitted;
  }
  const double half =
      (std::min)(draw.dest.width, draw.dest.height) / 2.0;
  draw.corner_radius =
      ClampDouble(config.corner_radius_ratio * draw.dest.width, 0.0, half);
  return draw;
}

CameraPreviewDraw ResolveCameraPreviewDraw(const CameraOverlayConfig& config,
                                           bool is_tile, const PipDraw& draw,
                                           uint32_t frame_width,
                                           uint32_t frame_height) {
  CameraPreviewDraw preview;
  // The preset's crop and mask travel in BOTH modes, because the compositor
  // applies them in both: a window recording gets the circle in the file
  // exactly as a display recording does. This once returned an uncropped,
  // unmasked frame in window mode on the grounds that the captioned preview is
  // not the tile (design 1e) — which is true of the PANEL and says nothing
  // about the picture inside it. The result was that Camera, Square and Circle
  // looked identical on screen while the MP4 differed (spec 33.5).
  preview.fit = config.fit;
  preview.corner_radius_ratio =
      ClampDouble(config.corner_radius_ratio, 0.0, kMaxCornerRadiusRatio);

  // Two ratios, and they are not the same question. `aspect_ratio` is the shape
  // of the TEXTURE being pushed; `pip_aspect_ratio` is the shape of the BOX the
  // picture is drawn into.
  if (!is_tile) {
    // Window mode. overlay_windows.cpp's PushFrame crops for the tile and
    // nothing else, so the texture is the camera's own frame, whole. Reporting
    // the tile's shape as the texture's would squash the picture by exactly the
    // crop the preview never received.
    preview.aspect_ratio =
        frame_width > 0 && frame_height > 0
            ? static_cast<double>(frame_width) / static_cast<double>(frame_height)
            // Nothing captured yet: the same configured fallback ResolvePipRect
            // uses, and 16:9 for a fallback that is not a shape.
            : (config.aspect_ratio > 0 ? config.aspect_ratio : 16.0 / 9.0);
    // The box is the tile's, so a captioned panel can show the shape the file
    // gets without becoming that shape itself.
    preview.pip_aspect_ratio =
        draw.dest.height > 0 ? draw.dest.width / draw.dest.height
                             : preview.aspect_ratio;
    return preview;
  }
  // Display mode: the preview *is* the tile (design 1p), the host has already
  // cropped the texture to it, so both ratios are the tile's.
  preview.aspect_ratio =
      draw.dest.height > 0 ? draw.dest.width / draw.dest.height : 16.0 / 9.0;
  preview.pip_aspect_ratio = preview.aspect_ratio;
  return preview;
}

CameraFrameMask ResolveCameraFrameMask(const CameraOverlayConfig& config,
                                       double canvas_width, double canvas_height,
                                       uint32_t frame_width,
                                       uint32_t frame_height) {
  const PipDraw draw = ResolvePipDraw(config, canvas_width, canvas_height,
                                      frame_width, frame_height);
  CameraFrameMask mask;
  mask.crop = draw.source;
  if (draw.dest.width > 0 && draw.source.width > 0) {
    // One scale for both axes: the crop and the tile are the same shape, so a
    // circle inscribed in the tile is a circle inscribed in the crop.
    mask.corner_radius = draw.corner_radius * (draw.source.width / draw.dest.width);
  }
  return mask;
}

bool CameraMaskIsRectangular(const CameraFrameMask& mask) {
  return !(mask.corner_radius > 0);
}

double CameraMaskCoverage(const CameraFrameMask& mask, double x, double y) {
  return MaskCoverageAt(mask.crop, ResolveMaskRow(mask, y), x);
}

void ApplyCameraMaskRow(const CameraFrameMask& mask, double y, uint32_t width,
                        uint8_t* bgra) {
  if (bgra == nullptr || width == 0) {
    return;
  }
  const MaskRow row = ResolveMaskRow(mask, y);
  for (uint32_t column = 0; column < width; ++column) {
    const double coverage =
        MaskCoverageAt(mask.crop, row, static_cast<double>(column) + 0.5);
    bgra[static_cast<size_t>(column) * 4 + 3] =
        static_cast<uint8_t>(coverage * 255.0 + 0.5);
  }
}

RectD LetterboxRect(double source_width, double source_height, double canvas_width,
                    double canvas_height) {
  RectD rect;
  if (source_width <= 0 || source_height <= 0) {
    rect.width = canvas_width;
    rect.height = canvas_height;
    return rect;
  }
  const double scale =
      (std::min)(canvas_width / source_width, canvas_height / source_height);
  rect.width = source_width * scale;
  rect.height = source_height * scale;
  rect.x = (canvas_width - rect.width) / 2.0;
  rect.y = (canvas_height - rect.height) / 2.0;
  return rect;
}

void ResolveCanvasSize(const CompositionConfig& composition, uint32_t source_width,
                       uint32_t source_height, uint32_t target_height,
                       uint32_t* out_width, uint32_t* out_height) {
  const double box_height = static_cast<double>(target_height);
  const double box_width = box_height * 16.0 / 9.0;
  if (source_width == 0 || source_height == 0 ||
      composition.aspect_policy == AspectRatioPolicy::kLetterboxIntoReferenceCanvas) {
    *out_width = EvenAtLeast2(box_width);
    *out_height = EvenAtLeast2(box_height);
    return;
  }
  const double scale = (std::min)(box_width / source_width, box_height / source_height);
  // Never upscale a source smaller than the preset box: it would spend bitrate
  // on invented pixels.
  const double applied = (std::min)(scale, 1.0);
  *out_width = EvenAtLeast2(source_width * applied);
  *out_height = EvenAtLeast2(source_height * applied);
}

LONG StripSnapPixels(double scale) {
  // A failed `> 0` again: a monitor that reports no usable scale, or a NaN,
  // snaps at the unscaled distance rather than not at all.
  const double factor = scale > 0 ? scale : 1.0;
  return static_cast<LONG>(kStripSnapPoints * factor + 0.5);
}

bool IsUsableWorkArea(const RECT& work_area) {
  return RectWidth(work_area) > 0 && RectHeight(work_area) > 0;
}

bool ShouldBeginOverlayMove(bool draggable, bool move_in_flight, bool button_down) {
  // Three separate refusals, and each of them is a drag that must not start:
  // the window-mode camera preview is not the picture-in-picture and so is not
  // draggable (spec 33.5), a second request inside the loop the first one
  // started would nest two move loops behind one finger, and a request whose
  // button is already up would start a drag nobody is holding.
  return draggable && !move_in_flight && button_down;
}

bool MenuChoiceClosesMenu(bool has_preset, bool has_corner) {
  // Everything that is not one of the camera sheet's two extra answers is a
  // device row — including `System default`, whose id is null, and `Off`, whose
  // row is the strip's own toggle. Both of those are choices the sheet exists
  // to make, and making one is what closes it (spec 33.4).
  return !has_preset && !has_corner;
}

RECT ClampToWorkArea(const RECT& work_area, const RECT& frame) {
  const LONG width = (std::max)(0L, RectWidth(frame));
  const LONG height = (std::max)(0L, RectHeight(frame));
  RECT clamped{};
  // The far edge first and the near edge second, so that for a strip larger
  // than the usable area — a 360-point strip on a 200-point-wide work area, or
  // a work area of no width at all — the near edge is the bound that survives.
  clamped.left = (std::max)((std::min)(frame.left, work_area.right - width),
                            work_area.left);
  clamped.top =
      (std::max)((std::min)(frame.top, work_area.bottom - height), work_area.top);
  clamped.right = clamped.left + width;
  clamped.bottom = clamped.top + height;
  return clamped;
}

RECT FractionalStripFrame(const RECT& work_area, double x, double y, LONG width,
                          LONG height) {
  RECT frame{};
  frame.left = work_area.left + ScaleFraction(x, RectWidth(work_area));
  frame.top = work_area.top + ScaleFraction(y, RectHeight(work_area));
  frame.right = frame.left + (std::max)(0L, width);
  frame.bottom = frame.top + (std::max)(0L, height);
  return ClampToWorkArea(work_area, frame);
}

bool StripPositionRatio(const RECT& work_area, const RECT& frame, double* out_x,
                        double* out_y) {
  if (out_x == nullptr || out_y == nullptr) {
    return false;
  }
  const LONG work_width = RectWidth(work_area);
  const LONG work_height = RectHeight(work_area);
  if (work_width <= 0 || work_height <= 0) {
    return false;
  }
  const double x =
      static_cast<double>(frame.left - work_area.left) / static_cast<double>(work_width);
  const double y =
      static_cast<double>(frame.top - work_area.top) / static_cast<double>(work_height);
  // Clamped because the caller may ask about a frame that has not been clamped
  // yet — a window Windows moved when a display was unplugged, say — and a
  // fraction outside the unit square is not one Dart will store.
  *out_x = x < 0 ? 0 : (x > 1 ? 1 : x);
  *out_y = y < 0 ? 0 : (y > 1 ? 1 : y);
  return true;
}

RECT SnapStripFrame(const RECT& work_area, const RECT& frame, LONG snap) {
  const LONG width = (std::max)(0L, RectWidth(frame));
  const LONG height = (std::max)(0L, RectHeight(frame));
  RECT snapped = frame;
  if (snap > 0) {
    // Left edge, right edge, horizontal centre. Measuring the distance between
    // the two left edges is the same measurement as between the two centres,
    // because the width is the strip's either way.
    const LONG lefts[] = {
        work_area.left,
        work_area.right - width,
        work_area.left + (RectWidth(work_area) - width) / 2,
    };
    // Top and bottom only: 33.3 snaps to an edge or to the *horizontal* centre.
    const LONG tops[] = {work_area.top, work_area.bottom - height};
    snapped.left = NearestWithin(frame.left, lefts, sizeof(lefts) / sizeof(lefts[0]), snap);
    snapped.top = NearestWithin(frame.top, tops, sizeof(tops) / sizeof(tops[0]), snap);
  }
  snapped.right = snapped.left + width;
  snapped.bottom = snapped.top + height;
  // After the snap, never before it: on a usable area narrower than the strip
  // the right-edge candidate sits left of the work area, and the clamp is what
  // puts it back.
  return ClampToWorkArea(work_area, snapped);
}

RECT NudgeStripFrame(const RECT& work_area, const RECT& frame, LONG dx, LONG dy,
                     LONG snap) {
  RECT moved = frame;
  moved.left += dx;
  moved.right += dx;
  moved.top += dy;
  moved.bottom += dy;
  // Through the same snap and clamp a drag end takes, so the keyboard cannot
  // put the strip anywhere the pointer could not (spec 33.3).
  return SnapStripFrame(work_area, moved, snap);
}

RECT ResolveInputMenuFrame(const RECT& work_area, const RECT& anchor_frame,
                           LONG anchor_x, LONG width, LONG height, LONG gap) {
  const LONG menu_width = (std::max)(0L, width);
  const LONG menu_height = (std::max)(0L, height);
  const LONG below = anchor_frame.bottom + gap;
  const LONG above = anchor_frame.top - gap - menu_height;
  RECT frame{};
  // Below when the whole menu fits under the strip, above it otherwise — and
  // below again when neither side fits, because a menu overlapping the strip is
  // still readable and one pushed off the screen is not (spec 33.4).
  frame.top = (below + menu_height <= work_area.bottom || above < work_area.top)
                  ? below
                  : above;
  // Centred on the control that asked for it, not on the strip: the chevron is
  // what the user pressed, and only Flutter knew where it ended up.
  frame.left = anchor_x - menu_width / 2;
  frame.right = frame.left + menu_width;
  frame.bottom = frame.top + menu_height;
  return ClampToWorkArea(work_area, frame);
}

std::wstring Widen(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int size = ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                         static_cast<int>(utf8.size()), nullptr, 0);
  if (size <= 0) {
    return std::wstring();
  }
  std::wstring result(static_cast<size_t>(size), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                        result.data(), size);
  return result;
}

std::string Narrow(const std::wstring& wide) {
  if (wide.empty()) {
    return std::string();
  }
  const int size = ::WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                         static_cast<int>(wide.size()), nullptr, 0,
                                         nullptr, nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string result(static_cast<size_t>(size), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                        result.data(), size, nullptr, nullptr);
  return result;
}

std::string HResultToString(HRESULT hr) {
  std::ostringstream stream;
  stream << "0x" << std::hex << static_cast<unsigned long>(hr);
  return stream.str();
}

std::wstring JoinPath(const std::wstring& directory, const std::wstring& leaf) {
  if (directory.empty()) {
    return leaf;
  }
  const wchar_t last = directory.back();
  if (last == L'\\' || last == L'/') {
    return directory + leaf;
  }
  return directory + L"\\" + leaf;
}

int64_t QpcNow() {
  LARGE_INTEGER counter{};
  ::QueryPerformanceCounter(&counter);
  return counter.QuadPart;
}

int64_t QpcFrequency() {
  static const int64_t frequency = [] {
    LARGE_INTEGER value{};
    ::QueryPerformanceFrequency(&value);
    return value.QuadPart != 0 ? value.QuadPart : 1;
  }();
  return frequency;
}

int64_t QpcTo100ns(int64_t qpc_ticks) {
  const int64_t frequency = QpcFrequency();
  const int64_t whole = qpc_ticks / frequency;
  const int64_t remainder = qpc_ticks % frequency;
  return whole * 10000000LL + (remainder * 10000000LL) / frequency;
}

int64_t Now100ns() {
  return QpcTo100ns(QpcNow());
}

void SessionClock::Start(int64_t now_100ns) {
  std::lock_guard<std::mutex> lock(mutex_);
  running_ = true;
  paused_ = false;
  start_100ns_ = now_100ns;
  paused_total_100ns_ = 0;
  pause_started_100ns_ = 0;
  stopped_media_100ns_ = -1;
}

void SessionClock::Pause(int64_t now_100ns) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!running_ || paused_) {
    return;
  }
  paused_ = true;
  pause_started_100ns_ = now_100ns;
}

void SessionClock::Resume(int64_t now_100ns) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!running_ || !paused_) {
    return;
  }
  paused_total_100ns_ += now_100ns - pause_started_100ns_;
  paused_ = false;
  pause_started_100ns_ = 0;
}

void SessionClock::Stop(int64_t now_100ns) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!running_) {
    return;
  }
  if (paused_) {
    paused_total_100ns_ += now_100ns - pause_started_100ns_;
    paused_ = false;
  }
  const int64_t media = now_100ns - start_100ns_ - paused_total_100ns_;
  stopped_media_100ns_ = media < 0 ? 0 : media;
  running_ = false;
}

bool SessionClock::running() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return running_;
}

bool SessionClock::paused() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return paused_;
}

int64_t SessionClock::MediaTime100ns(int64_t capture_100ns) const {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!running_ || paused_) {
    return -1;
  }
  const int64_t media = capture_100ns - start_100ns_ - paused_total_100ns_;
  return media < 0 ? 0 : media;
}

int64_t SessionClock::ElapsedMs() const {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!running_) {
    return stopped_media_100ns_ < 0 ? 0 : stopped_media_100ns_ / 10000LL;
  }
  const int64_t reference = paused_ ? pause_started_100ns_ : Now100ns();
  const int64_t media = reference - start_100ns_ - paused_total_100ns_;
  return media < 0 ? 0 : media / 10000LL;
}

PlatformDispatcher::PlatformDispatcher() {
  WNDCLASSEXW window_class{};
  window_class.cbSize = sizeof(window_class);
  window_class.lpfnWndProc = PlatformDispatcher::WindowProc;
  window_class.hInstance = ::GetModuleHandleW(nullptr);
  window_class.lpszClassName = kDispatcherClassName;
  ::RegisterClassExW(&window_class);

  window_ = ::CreateWindowExW(0, kDispatcherClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                              nullptr, window_class.hInstance, this);
}

PlatformDispatcher::~PlatformDispatcher() {
  Shutdown();
}

void PlatformDispatcher::Post(std::function<void()> work) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutting_down_ || window_ == nullptr) {
      return;
    }
    pending_.push_back(std::move(work));
  }
  ::PostMessageW(window_, kRunWorkMessage, 0, 0);
}

void PlatformDispatcher::Shutdown() {
  HWND window = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutting_down_) {
      return;
    }
    shutting_down_ = true;
    pending_.clear();
    window = window_;
    window_ = nullptr;
  }
  if (window != nullptr) {
    ::DestroyWindow(window);
  }
}

void PlatformDispatcher::Drain() {
  std::vector<std::function<void()>> work;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    work.swap(pending_);
  }
  for (const std::function<void()>& item : work) {
    if (item) {
      item();
    }
  }
}

LRESULT CALLBACK PlatformDispatcher::WindowProc(HWND window, UINT message,
                                                WPARAM wparam, LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    ::SetWindowLongPtrW(window, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  } else if (message == kRunWorkMessage) {
    auto* self = reinterpret_cast<PlatformDispatcher*>(
        ::GetWindowLongPtrW(window, GWLP_USERDATA));
    if (self != nullptr) {
      self->Drain();
    }
    return 0;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

}  // namespace relay
