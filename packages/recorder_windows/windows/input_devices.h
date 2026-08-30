#ifndef RELAY_INPUT_DEVICES_H_
#define RELAY_INPUT_DEVICES_H_

#include <windows.h>

#include <mmdeviceapi.h>
#include <winrt/base.h>

#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "recorder_types.h"

namespace relay {

// The input devices of one kind, the system default first and then the
// platform's own order (spec 33.2).
//
// COM work: call it on the plugin's serial worker, which has an apartment. It
// only enumerates — no device is opened — so it raises no privacy prompt and
// costs the user nothing. An empty list is an answer (no camera is attached),
// never a failure.
std::vector<MediaDeviceInfo> EnumerateInputDevices(MediaDeviceKind kind);

// The ~20 Hz microphone meter behind startInputMetering/stopInputMetering
// (spec 33.2).
//
// Reference counted: two callers make one tap, and the tap closes when the last
// one stops. While a recording holds the microphone the level is taken from
// that capture; outside one the meter opens a shared-mode WASAPI capture stream
// on the metered endpoint and measures the samples it delivers, then closes it
// again with the last subscriber, so no device stays open for a bar nobody is
// watching.
//
// A capture stream and not IAudioMeterInformation on the endpoint: that meter
// reflects the audio engine's stream for the endpoint, so with nothing
// capturing it answers S_OK and 0.0 and the bar sits flat under a microphone
// that is working perfectly.
class InputMeter {
 public:
  // Raised on the meter thread; the plugin marshals the sample onto the
  // platform thread, like every other event.
  using LevelHandler =
      std::function<void(MediaDeviceKind kind, const InputLevelSample& level)>;

  InputMeter() = default;
  ~InputMeter();

  InputMeter(const InputMeter&) = delete;
  InputMeter& operator=(const InputMeter&) = delete;

  // `live` is the accumulator a recording fills for as long as it holds the
  // microphone. Set once, before the first Start.
  void Configure(LevelAccumulator* live, LevelHandler on_level);

  // A start for a kind that reports no level is a silent no-op, not an error.
  //
  // `device_id` is the endpoint to listen to, empty for the platform default —
  // the same meaning it has on RecordingConfig. A second start naming a
  // different device re-points the tap rather than opening a second one; the
  // same device again is a no-op (spec 33.2).
  void Start(MediaDeviceKind kind, const std::string& device_id);
  // A stop with nothing running is a no-op too.
  void Stop(MediaDeviceKind kind);
  // Drops every subscription and closes the tap. Idempotent.
  void StopAll();

  // The audio endpoints changed: re-resolve the metered device on the next
  // tick. Without it a default that moved leaves the bar reading the microphone
  // that used to be the default while the next recording opens the new one.
  void NotifyDeviceListChanged();

  // Whether anything is still metering `kind`. Asked on the platform thread
  // just before a level reaches the sink, so a sample raised moments before a
  // stop is not delivered after it (spec 33.2).
  bool IsMetering(MediaDeviceKind kind) const;

 private:
  // Everything the meter thread touches, and nothing else. Shared with that
  // thread so it can be left to unwind on its own: what it still reads outlives
  // this object, and the handler it would call is cleared before the stop that
  // dropped it returns.
  struct Tap;

  static void Run(std::shared_ptr<Tap> tap);
  void CloseTap();

  MeteringSubscriptions subscriptions_;
  LevelAccumulator* live_ = nullptr;
  LevelHandler on_level_;

  std::mutex mutex_;
  std::shared_ptr<Tap> tap_;
};

// Reports audio endpoint arrivals, removals, state changes and default changes
// as the contract's devicesChanged event (spec 33.2).
//
// Windows raises these for audio endpoints only. A camera plugged in while the
// application is running is not seen here — that needs a WM_DEVICECHANGE
// registration on a window this plugin does not own — which is why the event
// names no kind: "re-read everything" is the honest instruction, and it is the
// only one that is also true of the camera list.
//
// A burst is collapsed into one event: Windows raises a callback per endpoint
// and per role, so one headset arriving is about ten of them, and Dart answers
// every one of them with three enumerations (ChangeCoalescer).
class AudioEndpointWatcher {
 public:
  using ChangeHandler = std::function<void()>;

  AudioEndpointWatcher();
  ~AudioEndpointWatcher();

  AudioEndpointWatcher(const AudioEndpointWatcher&) = delete;
  AudioEndpointWatcher& operator=(const AudioEndpointWatcher&) = delete;

  // Safe from any thread: the registration is done on this object's own thread,
  // which is also the thread that releases it. Idempotent — a second Start
  // keeps the first handler.
  void Start(ChangeHandler on_change);
  // Idempotent, and safe from any thread. Returns only once no notification is
  // still running, so the handler cannot outlive what it captured.
  void Stop();

 private:
  class Client;

  void Run();
  void OnNotification();

  std::mutex mutex_;
  std::condition_variable cv_;
  std::thread thread_;
  ChangeHandler on_change_;
  ChangeCoalescer coalescer_;
  bool running_ = false;
};

}  // namespace relay

#endif  // RELAY_INPUT_DEVICES_H_
