#ifndef RELAY_RECORDER_WINDOWS_PLUGIN_H_
#define RELAY_RECORDER_WINDOWS_PLUGIN_H_

#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <atomic>
#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

#include "capture_source_enumerator.h"
#include "input_devices.h"
#include "overlay_windows.h"
#include "recorder_types.h"
#include "recording_session.h"

namespace relay {

// Serial background worker for the channel calls that must not block the
// platform thread: source enumeration renders thumbnails, prepare opens devices
// and stop finalizes a file.
//
// Capacity 16, reject-newest. A command is never silently dropped: a full queue
// answers the call with an error instead, because losing a user's Stop would be
// worse than reporting it.
class SerialWorker {
 public:
  SerialWorker();
  ~SerialWorker();

  bool Post(std::function<void()> work);
  void Shutdown();

 private:
  void Run();

  static constexpr size_t kCapacity = 16;
  std::mutex mutex_;
  std::condition_variable cv_;
  std::deque<std::function<void()>> queue_;
  bool running_ = true;
  std::thread thread_;
};

class RecorderWindowsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit RecorderWindowsPlugin(flutter::PluginRegistrarWindows* registrar);
  ~RecorderWindowsPlugin() override;

  RecorderWindowsPlugin(const RecorderWindowsPlugin&) = delete;
  RecorderWindowsPlugin& operator=(const RecorderWindowsPlugin&) = delete;

 private:
  using MethodResultPtr =
      std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>;

  void HandleRecorderMethod(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleOverlayMethod(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void EmitRecorderEvent(flutter::EncodableMap event);
  void EmitOverlayCommand(const std::string& command);
  // A choice made in the input menu, beside the bare command names the same
  // channel emits. Dart decodes by shape — a String is a command, a Map is a
  // choice — so nothing here may turn a command into a map (spec 33.4).
  //
  // `choice` is the menu engine's own arguments map, forwarded as it arrived: a
  // device row, a shape preset, a corner or `Reset position`, which differ only
  // in which keys they carry. The one field the host owns is `dismissed`, which
  // a choice never is.
  void EmitMenuChoice(flutter::EncodableMap choice);
  // The host closed the menu behind the application's back — a click outside,
  // Esc, the strip moving, a display change. It applies nothing; it exists so
  // the application stops believing a window that is already gone is still open
  // (spec 33.4, platform-channel-contract "input-menu map").
  void EmitMenuDismissal(MediaDeviceKind kind);
  // The one place either of the two reaches the overlay event sink, so a choice
  // and a dismissal cannot drift apart in how they are delivered.
  void EmitOverlayChoiceMap(flutter::EncodableMap map);
  void EmitInputLevel(MediaDeviceKind kind, const InputLevelSample& level);
  // Named no kind: what Windows reports is an audio endpoint change, and
  // "re-read everything" is the only instruction that is also true of the
  // camera list (input_devices.h).
  void EmitDevicesChanged();
  void WireSessionEvents();

  // The display being recorded, or null when the configuration does not name
  // one any more — a window recording, or a monitor that has been unplugged.
  //
  // One resolution shared by both halves of the preview's placement.
  // AlignPreviewToCamera converts the tile into the logical points a placement
  // is resolved in, UpdatePreviewGeometry hands the overlay layer the physical
  // pixels a drag is measured against, and they have to be the same display:
  // measured against the one holding the *main window* instead, a
  // mixed-resolution desktop placed the preview at the wrong scale, and a drag
  // measured against any rectangle but the recorded display's would let the
  // tile leave the recording.
  HMONITOR RecordedDisplay() const;

  // Re-resolves an absolute preview frame against the tile the compositor is
  // actually going to draw, so the preview window lands exactly on it. Dart can
  // only resolve the rectangle from the configured fallback aspect ratio; the
  // camera's own shape and the encoder canvas are both known here (spec 7,
  // design 1p).
  void AlignPreviewToCamera(OverlayPlacement* placement) const;

  // Hands the overlay layer everything the preview needs to *be* the tile: the
  // configuration, the canvas, the camera's frame size and where that canvas
  // lands on screen. Called whenever any of them changes.
  void UpdatePreviewGeometry();

  // What the preview window is told to draw, from the geometry the last
  // UpdatePreviewGeometry resolved — the same answer the frames are cropped by,
  // so the shape reported and the picture pushed cannot disagree.
  CameraPreviewDraw PreviewDraw() const;

  // Re-resolves the preview against the tile as it is now and re-pushes its
  // state: the shape, the crop and the mask all move with the tile (design 1p).
  //
  // `reposition` moves the window as well, which every caller wants except the
  // drag that just moved it — the window is already where the user let go, put
  // there by this same arithmetic, and re-placing it would be a second move for
  // nothing. Only a preview that is already on screen: nothing here may open
  // one.
  void RefreshCameraPreview(bool reposition);

  // Pushes the camera configuration at the live session and re-points the
  // preview to match it. `from_preview` is a position the user just dragged the
  // preview to, which must not be pushed back at the window that reported it.
  void ApplyCameraOverlay(const CameraOverlayConfig& camera, bool from_preview);

  HWND MainWindow() const;
  flutter::EncodableMap Capabilities() const;
  // The census as the wire carries it (spec 19.1). Static: it reads nothing
  // but its argument.
  static flutter::EncodableMap CensusMap(const ResourceCensus& census);
  void RunOnPlatformThread(std::function<void()> work);
  // Replies to `result` on the platform thread, whichever thread produced it.
  void ReplySuccess(const MethodResultPtr& result, flutter::EncodableValue value);
  void ReplyError(const MethodResultPtr& result, const RecorderError& error);

  flutter::PluginRegistrarWindows* registrar_;
  PlatformDispatcher dispatcher_;
  SerialWorker worker_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> recorder_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> recorder_events_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> overlay_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> overlay_events_;

  std::mutex sink_mutex_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> recorder_sink_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> overlay_sink_;

  CaptureSourceEnumerator enumerator_;
  OverlayWindows overlays_;
  // Declared ahead of the meter and the session because both point at it: a
  // member is destroyed after everything declared below it.
  LevelAccumulator microphone_level_;
  InputMeter meter_;
  AudioEndpointWatcher device_watcher_;
  // Shared rather than unique: a worker-thread prepare/stop holds a reference
  // for the duration of the call, so disposing on the platform thread cannot
  // pull the session out from under it.
  std::shared_ptr<RecordingSession> session_;
  RecordingConfig last_config_;
  // The geometry last handed to the overlay layer, kept so the state pushed to
  // the preview is resolved from the same answer its frames are cropped by:
  // `is_tile` is false not only in window mode but whenever the recorded
  // display cannot be named, and a preview that is not the tile is fed the
  // frame whole. Platform thread only, like everything else that places a
  // window.
  CameraPreviewGeometry preview_geometry_;
  // The camera frame size the preview was last resolved against, packed as
  // width << 32 | height.
  //
  // The tile takes the camera's shape, and the camera's shape is not known
  // until it delivers: the preview is placed from the configured fallback
  // before the device has opened (design 1p). Written on the camera thread,
  // which is why it is an atomic, and compared rather than read — one
  // re-resolution per resolution, not one per frame.
  std::atomic<uint64_t> preview_frame_size_{0};
  // Which input the menu on screen belongs to, or nothing when the application
  // does not believe one is open. Taken rather than read when a dismissal is
  // reported, so a display change seen by three overlay windows is still one
  // dismissal (spec 33.4). Platform thread only: every path that opens, closes
  // or dismisses the menu runs there.
  std::optional<MediaDeviceKind> open_menu_kind_;
  // Written on the platform thread and read on the serial worker: a task
  // queued before dispose and drained after it must not re-arm anything.
  std::atomic<bool> disposed_{false};
  // One device swap at a time. Taken on the platform thread, where the request
  // arrives, and released on the worker that performed it: the worker is
  // serial, so a flag taken there would queue the second swap instead of
  // dropping it, which is the opposite of spec 6's one-command-at-a-time rule.
  std::atomic<bool> swapping_device_{false};
};

}  // namespace relay

#endif  // RELAY_RECORDER_WINDOWS_PLUGIN_H_
