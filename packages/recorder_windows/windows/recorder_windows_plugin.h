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
  void EmitInputLevel(MediaDeviceKind kind, const InputLevelSample& level);
  // Named no kind: what Windows reports is an audio endpoint change, and
  // "re-read everything" is the only instruction that is also true of the
  // camera list (input_devices.h).
  void EmitDevicesChanged();
  void WireSessionEvents();

  // Re-resolves an absolute preview frame against the camera's real shape, so
  // the preview window lands exactly where the compositor draws the
  // picture-in-picture. Dart can only resolve it from the configured fallback
  // aspect ratio; the camera's own shape is known here (spec 7, design 1p).
  void AlignPreviewToCamera(OverlayPlacement* placement) const;

  HWND MainWindow() const;
  flutter::EncodableMap Capabilities() const;
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
  // Written on the platform thread and read on the serial worker: a task
  // queued before dispose and drained after it must not re-arm anything.
  std::atomic<bool> disposed_{false};
};

}  // namespace relay

#endif  // RELAY_RECORDER_WINDOWS_PLUGIN_H_
