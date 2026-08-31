#include "input_devices.h"

// Out of alphabetical order, and deliberately: without INITGUID the property-key
// header below only *declares* PKEY_Device_FriendlyName and the definition has
// to come out of whichever import library happens to carry it. Defining it here
// makes the label lookup independent of the link line, and DECLSPEC_SELECTANY
// keeps the definition from colliding with anyone else's.
#include <initguid.h>

#include <audioclient.h>
#include <functiondiscoverykeys_devpkey.h>
#include <mfapi.h>
#include <mfidl.h>
#include <objbase.h>

#include <atomic>
#include <chrono>
#include <utility>

#include "audio_capture.h"
#include "audio_mixer.h"

namespace relay {

namespace {

// ~20 Hz. Fast enough that a bar tracks speech, slow enough that the event
// channel carries twenty small maps a second rather than a stream (spec 33.2).
constexpr std::chrono::milliseconds kMeterInterval(50);

// Where the retry cadence stops backing off when there is no capture endpoint
// to open at all. Two seconds is well inside the time it takes to plug a
// microphone in and look at the bar.
constexpr std::chrono::milliseconds kMeterRetryCeiling(2000);

// 500 ms of endpoint buffer for the meter's own tap, matching the recording
// capture: enough to survive a scheduling hiccup, far too small to accumulate.
constexpr REFERENCE_TIME kTapBufferDuration = 5000000;

// How long a burst of endpoint notifications has to go quiet before it becomes
// one devicesChanged, and how long a device that never settles may delay it.
// A quarter of a second is below what the eye reads as a delay and well above
// the spread of the ten callbacks one headset raises.
constexpr int64_t kDeviceChangeWindowMs = 250;
constexpr int64_t kDeviceChangeCeilingMs = 1000;

// Monotonic milliseconds, off the same QueryPerformanceCounter the media
// timeline uses. Wall-clock time is never used for timing here (spec 8, 22).
int64_t NowMs() {
  return Now100ns() / 10000;
}

// The endpoint's opaque id, released with CoTaskMemFree on every path.
std::string EndpointId(IMMDevice* device) {
  if (device == nullptr) {
    return std::string();
  }
  LPWSTR raw = nullptr;
  if (FAILED(device->GetId(&raw)) || raw == nullptr) {
    return std::string();
  }
  const std::string id = Narrow(raw);
  ::CoTaskMemFree(raw);
  return id;
}

// The name the user reads. Empty is allowed: Dart substitutes the kind's own
// word rather than showing a blank row.
std::string EndpointLabel(IMMDevice* device) {
  if (device == nullptr) {
    return std::string();
  }
  winrt::com_ptr<IPropertyStore> properties;
  if (FAILED(device->OpenPropertyStore(STGM_READ, properties.put()))) {
    return std::string();
  }
  PROPVARIANT value;
  ::PropVariantInit(&value);
  std::string label;
  if (SUCCEEDED(properties->GetValue(PKEY_Device_FriendlyName, &value)) &&
      value.vt == VT_LPWSTR && value.pwszVal != nullptr) {
    label = Narrow(value.pwszVal);
  }
  ::PropVariantClear(&value);
  return label;
}

std::string ActivateString(IMFActivate* activate, const GUID& key) {
  if (activate == nullptr) {
    return std::string();
  }
  LPWSTR raw = nullptr;
  UINT32 length = 0;
  if (FAILED(activate->GetAllocatedString(key, &raw, &length)) || raw == nullptr) {
    return std::string();
  }
  const std::string text = Narrow(raw);
  ::CoTaskMemFree(raw);
  return text;
}

std::vector<MediaDeviceInfo> EnumerateAudioEndpoints(MediaDeviceKind kind) {
  std::vector<MediaDeviceInfo> devices;
  winrt::com_ptr<IMMDeviceEnumerator> enumerator;
  if (FAILED(::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                CLSCTX_INPROC_SERVER, __uuidof(IMMDeviceEnumerator),
                                enumerator.put_void()))) {
    return devices;
  }
  // System audio is a loopback on a *render* endpoint: "which output am I
  // recording?" is a real question here (audio_capture.cpp).
  const EDataFlow flow = kind == MediaDeviceKind::kSystemAudio ? eRender : eCapture;

  // Read before the list, so each entry can be marked as it is built.
  std::string default_id;
  winrt::com_ptr<IMMDevice> fallback;
  if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(flow, eConsole, fallback.put()))) {
    default_id = EndpointId(fallback.get());
  }

  winrt::com_ptr<IMMDeviceCollection> collection;
  if (FAILED(enumerator->EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE,
                                            collection.put()))) {
    return devices;
  }
  UINT count = 0;
  if (FAILED(collection->GetCount(&count))) {
    return devices;
  }
  for (UINT i = 0; i < count; ++i) {
    winrt::com_ptr<IMMDevice> device;
    if (FAILED(collection->Item(i, device.put()))) {
      continue;
    }
    MediaDeviceInfo info;
    info.kind = kind;
    info.id = EndpointId(device.get());
    if (info.id.empty()) {
      // Without an id a device can be neither selected nor persisted, so it is
      // not one the caller can be offered.
      continue;
    }
    info.label = EndpointLabel(device.get());
    info.is_system_default = !default_id.empty() && info.id == default_id;
    // Every listed endpoint is reported available, and that is a limitation
    // rather than a claim: whether an endpoint is free is not enumerable on
    // Windows. Only DEVICE_STATE_ACTIVE ones are listed at all, and an endpoint
    // another application holds in exclusive mode looks exactly like a free one
    // until IAudioClient::Initialize answers AUDCLNT_E_DEVICE_IN_USE. Asking
    // would mean opening every device on every enumeration — the privacy prompt
    // and the cost this list exists to avoid — so a device that turns out to be
    // busy is reported when it is opened, where a recording degrades to the
    // default rather than failing (spec 33.2). macOS can answer this and
    // Windows cannot; the divergence belongs in the compatibility matrix.
    info.is_available = true;
    devices.push_back(std::move(info));
  }
  OrderDevicesDefaultFirst(&devices);
  return devices;
}

std::vector<MediaDeviceInfo> EnumerateCameras() {
  std::vector<MediaDeviceInfo> devices;
  if (FAILED(::MFStartup(MF_VERSION, MFSTARTUP_LITE))) {
    return devices;
  }
  winrt::com_ptr<IMFAttributes> attributes;
  if (SUCCEEDED(::MFCreateAttributes(attributes.put(), 1))) {
    attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                        MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
    IMFActivate** activates = nullptr;
    UINT32 count = 0;
    if (SUCCEEDED(::MFEnumDeviceSources(attributes.get(), &activates, &count)) &&
        activates != nullptr) {
      for (UINT32 i = 0; i < count; ++i) {
        MediaDeviceInfo info;
        info.kind = MediaDeviceKind::kCamera;
        info.id = ActivateString(
            activates[i], MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK);
        info.label = ActivateString(activates[i], MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME);
        // Reported available for the same reason every audio endpoint is: Media
        // Foundation carries no in-use flag, and a camera another application
        // holds refuses only at ActivateObject, where the recording reports it.
        info.is_available = true;
        devices.push_back(std::move(info));
        activates[i]->Release();
      }
      ::CoTaskMemFree(activates);
    }
  }
  ::MFShutdown();
  // The nameless sources go, and the first survivor is the default — the same
  // rule camera_capture.cpp opens by, so the entry this list calls the default
  // is the entry an unconfigured prepare records.
  RetainSelectableCameras(&devices);
  // Already default-first, since the first source that can be named is the
  // default. Ordered anyway, so the contract's ordering has one owner.
  OrderDevicesDefaultFirst(&devices);
  return devices;
}

// A real capture stream on one endpoint, which is what a level costs outside a
// recording.
//
// IAudioMeterInformation on an IMMDevice is the cheaper-looking thing and does
// not work: the endpoint peak meter reflects the audio engine's stream for that
// endpoint, so with nothing capturing it answers S_OK and 0.0 — a flat bar and
// a "nothing has reached this input" warning about a microphone that is working
// perfectly. Shared mode and polled, because the meter already ticks at
// kMeterInterval and has nothing to do between two ticks; the endpoint buffer
// is far larger than one of them, so no packet is missed.
class EndpointTap {
 public:
  EndpointTap() = default;
  ~EndpointTap() { Close(); }

  EndpointTap(const EndpointTap&) = delete;
  EndpointTap& operator=(const EndpointTap&) = delete;

  bool open() const { return capture_ != nullptr; }

  // Opens `device_id`, or the platform default when it is empty or no longer
  // resolves — a meter that went silent because the chosen microphone was
  // unplugged would say the wrong thing about the one that is still there.
  // False leaves nothing open.
  bool Open(const std::string& device_id) {
    Close();
    winrt::com_ptr<IMMDeviceEnumerator> enumerator;
    if (FAILED(::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                  CLSCTX_INPROC_SERVER, __uuidof(IMMDeviceEnumerator),
                                  enumerator.put_void()))) {
      return false;
    }
    if (!device_id.empty()) {
      DWORD state = 0;
      if (FAILED(enumerator->GetDevice(Widen(device_id).c_str(), device_.put())) ||
          FAILED(device_->GetState(&state)) || state != DEVICE_STATE_ACTIVE) {
        device_ = nullptr;
      }
    }
    if (!device_ &&
        FAILED(enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, device_.put()))) {
      Close();
      return false;
    }
    if (FAILED(device_->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                 client_.put_void()))) {
      Close();
      return false;
    }
    if (FAILED(client_->GetMixFormat(&format_)) || format_ == nullptr) {
      Close();
      return false;
    }
    if (FAILED(client_->Initialize(AUDCLNT_SHAREMODE_SHARED, 0, kTapBufferDuration, 0,
                                   format_, nullptr))) {
      // Includes E_ACCESSDENIED, which is Windows privacy settings refusing the
      // microphone. The bar stays flat and the permission report is what says
      // why: a meter is not the place to raise it a second time.
      Close();
      return false;
    }
    if (FAILED(client_->GetService(__uuidof(IAudioCaptureClient), capture_.put_void()))) {
      Close();
      return false;
    }
    if (FAILED(client_->Start())) {
      Close();
      return false;
    }
    resampler_.Configure(format_->nSamplesPerSec, format_->nChannels,
                         WaveFormatIsFloat(format_), format_->wBitsPerSample);
    level_.SetEnabled(true);
    return true;
  }

  // Measures every packet the endpoint has ready. False when the endpoint
  // stopped delivering, which leaves nothing open.
  bool Read(InputLevelSample* out) {
    if (!capture_ || out == nullptr) {
      return false;
    }
    for (;;) {
      UINT32 packet_frames = 0;
      if (FAILED(capture_->GetNextPacketSize(&packet_frames))) {
        return false;
      }
      if (packet_frames == 0) {
        break;
      }
      BYTE* data = nullptr;
      UINT32 frames = 0;
      DWORD flags = 0;
      if (FAILED(capture_->GetBuffer(&data, &frames, &flags, nullptr, nullptr))) {
        return false;
      }
      if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) == 0 && data != nullptr) {
        // Converted through the resampler the recording's own capture uses, so
        // the bar measures the same samples before a recording that it measures
        // during one and does not jump when the session starts.
        converted_.clear();
        resampler_.Process(data, frames, &converted_);
        level_.Add(converted_.data(), converted_.size());
      } else {
        // A silent packet is a level of zero, not the absence of one: a bar
        // that stops updating reads as frozen rather than as quiet.
        level_.Add(nullptr, static_cast<size_t>(frames) * kMixChannels);
      }
      capture_->ReleaseBuffer(frames);
    }
    *out = level_.Take();
    return true;
  }

  // Idempotent, and the only teardown path: every failed Open ends here too.
  void Close() {
    if (client_) {
      client_->Stop();
    }
    capture_ = nullptr;
    client_ = nullptr;
    device_ = nullptr;
    if (format_ != nullptr) {
      ::CoTaskMemFree(format_);
      format_ = nullptr;
    }
    resampler_.Reset();
    // Discards the interval in progress: the next tap opens on what it hears,
    // never on what the last one did.
    level_.SetEnabled(false);
    converted_.clear();
  }

 private:
  winrt::com_ptr<IMMDevice> device_;
  winrt::com_ptr<IAudioClient> client_;
  winrt::com_ptr<IAudioCaptureClient> capture_;
  WAVEFORMATEX* format_ = nullptr;  // CoTaskMemFree owned by this object
  AudioResampler resampler_;
  LevelAccumulator level_;
  std::vector<float> converted_;
};

}  // namespace

std::vector<MediaDeviceInfo> EnumerateInputDevices(MediaDeviceKind kind) {
  switch (kind) {
    case MediaDeviceKind::kCamera:
      return EnumerateCameras();
    case MediaDeviceKind::kMicrophone:
    case MediaDeviceKind::kSystemAudio:
      break;
  }
  return EnumerateAudioEndpoints(kind);
}

// ── InputMeter ───────────────────────────────────────────────────────────────

// Everything the meter thread touches. Owned by a shared pointer so the thread
// can be detached: it never reaches back into the InputMeter, and the handler
// it would call is cleared under `mutex` before the stop that dropped it
// returns.
struct InputMeter::Tap {
  std::mutex mutex;
  std::condition_variable cv;
  bool running = true;
  // Set when the thread must re-check its device now rather than at the end of
  // the tick it is waiting out.
  bool wake = false;
  MeterTarget target;
  LevelAccumulator* live = nullptr;
  LevelHandler on_level;
};

InputMeter::~InputMeter() {
  StopAll();
}

void InputMeter::Configure(LevelAccumulator* live, LevelHandler on_level) {
  live_ = live;
  on_level_ = std::move(on_level);
}

void InputMeter::Start(MediaDeviceKind kind, const std::string& device_id) {
  if (!IsMeterableDeviceKind(kind)) {
    return;
  }
  // Reference counted: two callers make one tap, and the tap closes with the
  // last of them. Every start counts, not only the first — but a second
  // subscriber naming a different device still re-points the open tap rather
  // than opening a second one (spec 33.2).
  subscriptions_.Retain(kind);
  std::shared_ptr<Tap> tap;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!tap_) {
      tap_ = std::make_shared<Tap>();
      tap_->live = live_;
      tap_->on_level = on_level_;
      tap_->target.Point(device_id);
      if (live_ != nullptr) {
        live_->SetEnabled(true);
      }
      // Detached, and holding through the shared state above everything it
      // still touches: `stopInputMetering` answers on the Flutter platform
      // thread, which must never wait for a WASAPI call to return.
      std::thread(&InputMeter::Run, tap_).detach();
      return;
    }
    tap = tap_;
  }
  {
    std::lock_guard<std::mutex> lock(tap->mutex);
    if (!tap->target.Point(device_id)) {
      // Already metering exactly this device.
      return;
    }
    tap->wake = true;
  }
  tap->cv.notify_all();
}

void InputMeter::Stop(MediaDeviceKind kind) {
  if (!IsMeterableDeviceKind(kind)) {
    return;
  }
  if (!subscriptions_.Release(kind)) {
    // Still watched by someone else, or never started at all.
    return;
  }
  CloseTap();
}

void InputMeter::StopAll() {
  if (!subscriptions_.Clear()) {
    return;
  }
  CloseTap();
}

void InputMeter::NotifyDeviceListChanged() {
  std::shared_ptr<Tap> tap;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    tap = tap_;
  }
  if (!tap) {
    // Nothing is metering: the next start resolves the list as it finds it.
    return;
  }
  {
    std::lock_guard<std::mutex> lock(tap->mutex);
    // Re-opened rather than kept: the endpoint the tap holds may be the one
    // that was just unplugged, and a tap on the platform default has to follow
    // the default that moved — otherwise the bar reads the microphone that used
    // to be the default while the next recording opens the new one (spec 33.2).
    tap->target.Reopen();
    tap->wake = true;
  }
  tap->cv.notify_all();
}

bool InputMeter::IsMetering(MediaDeviceKind kind) const {
  return subscriptions_.IsActive(kind);
}

ResourceCensus InputMeter::DebugCensus() const {
  ResourceCensus census;
  census.meter_subscriptions = subscriptions_.Total();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    census.metering_taps = tap_ ? 1 : 0;
  }
  return census;
}

void InputMeter::CloseTap() {
  std::shared_ptr<Tap> tap;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    tap = std::move(tap_);
  }
  if (live_ != nullptr) {
    live_->SetEnabled(false);
  }
  if (!tap) {
    return;
  }
  {
    std::lock_guard<std::mutex> lock(tap->mutex);
    tap->running = false;
    // The handler goes with the subscription, under the same lock the thread
    // emits under: once this returns, a level already being raised has finished
    // and no further one can begin (spec 33.2).
    tap->on_level = nullptr;
    tap->live = nullptr;
  }
  tap->cv.notify_all();
  // Not joined. This runs on the Flutter platform thread, and the thread it
  // would wait for is inside a COM call for as long as WASAPI takes to close an
  // endpoint — which is the menu closing with the UI frozen behind it. The
  // thread owns its own endpoint and the shared state above, so it is left to
  // unwind on its own.
}

void InputMeter::Run(std::shared_ptr<Tap> tap) {
  // COM is per-thread, and the capture client is a COM object. Multi-threaded,
  // like the capture and audio threads.
  const HRESULT com = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  EndpointTap endpoint;
  RetryBackoff backoff(kMeterInterval, kMeterRetryCeiling);
  for (;;) {
    bool wants_open = false;
    std::string device_id;
    LevelAccumulator* live = nullptr;
    {
      std::lock_guard<std::mutex> lock(tap->mutex);
      if (!tap->running) {
        break;
      }
      wants_open = tap->target.wants_open();
      device_id = tap->target.device_id();
      live = tap->live;
    }

    // Off the lock, and that is the point of the lock being this narrow:
    // opening and reading an endpoint are COM calls, and the stop that closes
    // this tap answers on the Flutter platform thread.
    InputLevelSample level;
    std::chrono::milliseconds wait = kMeterInterval;
    bool opened = false;
    bool closed = false;
    if (live != nullptr && live->live()) {
      // A recording holds the microphone: its own capture is the level source,
      // and no second handle is opened on a device the session already has
      // open (spec 33.2).
      if (endpoint.open()) {
        endpoint.Close();
        closed = true;
      }
      backoff.Reset();
      level = live->Take();
    } else {
      if (wants_open) {
        endpoint.Close();
        opened = endpoint.Open(device_id);
        closed = !opened;
      }
      if (endpoint.open()) {
        if (endpoint.Read(&level)) {
          backoff.Reset();
        } else {
          // The endpoint went away mid-tap. Silence is the honest reading, and
          // it keeps the bar alive: one that simply stops updating reads as
          // frozen rather than as quiet.
          endpoint.Close();
          closed = true;
          level = InputLevelSample();
        }
      } else {
        // Nothing to open. The bar stays flat either way, so the attempts back
        // off rather than re-resolving the default endpoint twenty times a
        // second for as long as a meter is on screen.
        wait = backoff.Next();
      }
    }

    {
      std::unique_lock<std::mutex> lock(tap->mutex);
      if (opened && tap->target.device_id() == device_id) {
        tap->target.NoteOpened();
      } else if (opened || closed) {
        // Either nothing opened, or a re-point landed while this one was
        // opening — in which case the endpoint just opened is already the wrong
        // one and the next tick replaces it.
        tap->target.NoteClosed();
      }
      // Re-checked after the reading and under the lock the stop takes, so
      // nothing is emitted once nothing is metering (spec 33.2).
      if (!tap->running) {
        break;
      }
      if (tap->on_level) {
        tap->on_level(MediaDeviceKind::kMicrophone, level);
      }
      tap->cv.wait_for(lock, wait, [&tap] { return !tap->running || tap->wake; });
      if (tap->wake) {
        tap->wake = false;
        // A device was chosen or the endpoints changed: whatever the last one
        // cost, this one starts trying at the full rate again.
        backoff.Reset();
      }
      if (!tap->running) {
        break;
      }
    }
  }
  // The tap closes with the last subscriber: no device stays open for a meter
  // nobody is watching.
  endpoint.Close();
  if (SUCCEEDED(com)) {
    ::CoUninitialize();
  }
}

// ── AudioEndpointWatcher ─────────────────────────────────────────────────────

// Hand-rolled COM object rather than a WinRT one: IMMNotificationClient has no
// projection, and the reference count is the only thing keeping it alive
// between RegisterEndpointNotificationCallback and the unregister.
class AudioEndpointWatcher::Client final : public IMMNotificationClient {
 public:
  explicit Client(AudioEndpointWatcher* watcher) : watcher_(watcher) {}

  Client(const Client&) = delete;
  Client& operator=(const Client&) = delete;

  // Returns once no notification is still running, so the watcher cannot be
  // reached after it has stopped.
  void Detach() {
    std::lock_guard<std::mutex> lock(mutex_);
    watcher_ = nullptr;
  }

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** object) override {
    if (object == nullptr) {
      return E_POINTER;
    }
    if (riid == __uuidof(IUnknown) || riid == __uuidof(IMMNotificationClient)) {
      *object = static_cast<IMMNotificationClient*>(this);
      AddRef();
      return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
  }

  ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }

  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG remaining = --references_;
    if (remaining == 0) {
      delete this;
    }
    return remaining;
  }

  HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR, DWORD) override {
    Notify();
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR) override {
    Notify();
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR) override {
    Notify();
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow, ERole, LPCWSTR) override {
    Notify();
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR, const PROPERTYKEY) override {
    // A renamed device is the same device: the list did not change.
    return S_OK;
  }

 private:
  // Release() owns the lifetime; nothing else may destroy this object.
  ~Client() = default;

  void Notify() {
    // Held across the call rather than around a copy of the pointer: Detach()
    // must not return while a notification is still running. What is called is
    // only a flag and a notify — the burst is collapsed on the watcher's own
    // thread, so this returns to Windows immediately.
    std::lock_guard<std::mutex> lock(mutex_);
    if (watcher_ != nullptr) {
      watcher_->OnNotification();
    }
  }

  std::mutex mutex_;
  std::atomic<ULONG> references_{1};
  AudioEndpointWatcher* watcher_ = nullptr;
};

AudioEndpointWatcher::AudioEndpointWatcher()
    : coalescer_(kDeviceChangeWindowMs, kDeviceChangeCeilingMs) {}

AudioEndpointWatcher::~AudioEndpointWatcher() {
  Stop();
}

void AudioEndpointWatcher::Start(ChangeHandler on_change) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (running_) {
    return;
  }
  on_change_ = std::move(on_change);
  running_ = true;
  thread_ = std::thread(&AudioEndpointWatcher::Run, this);
}

void AudioEndpointWatcher::Stop() {
  std::thread thread;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    running_ = false;
    thread = std::move(thread_);
  }
  cv_.notify_all();
  // Joined, and deliberately: it is the only thing that makes "no notification
  // is still running" true. What the thread has left to do is an unregister and
  // two releases — never a call that waits on hardware.
  if (thread.joinable()) {
    thread.join();
  }
  std::lock_guard<std::mutex> lock(mutex_);
  on_change_ = nullptr;
}

void AudioEndpointWatcher::OnNotification() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    coalescer_.Note(NowMs());
  }
  cv_.notify_all();
}

void AudioEndpointWatcher::Run() {
  // COM is per-thread, and so is the enumerator this registration lives on. It
  // is created, registered, unregistered and released here, all on one
  // multi-threaded apartment: the Flutter platform thread is a single-threaded
  // one, and releasing an MTA-created enumerator from there is a cross-
  // apartment release of an object this thread can simply own instead.
  const HRESULT com = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  winrt::com_ptr<IMMDeviceEnumerator> enumerator;
  winrt::com_ptr<IMMNotificationClient> client;
  bool registered = false;
  if (SUCCEEDED(::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                   CLSCTX_INPROC_SERVER, __uuidof(IMMDeviceEnumerator),
                                   enumerator.put_void()))) {
    // attach, not copy_from: the object is born with the one reference this
    // pointer takes over.
    client.attach(static_cast<IMMNotificationClient*>(new Client(this)));
    registered =
        SUCCEEDED(enumerator->RegisterEndpointNotificationCallback(client.get()));
  }

  for (;;) {
    ChangeHandler handler;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      if (!running_) {
        break;
      }
      if (!registered || !coalescer_.pending()) {
        // Nothing to deliver: woken by the next notification, or by Stop. A
        // registration that never happened waits only for Stop — a machine
        // whose endpoint enumerator cannot be created reports no changes rather
        // than polling for them.
        cv_.wait(lock, [this] { return !running_ || coalescer_.pending(); });
      } else {
        const int64_t remaining = coalescer_.WaitMs(NowMs());
        if (remaining > 0) {
          cv_.wait_for(lock, std::chrono::milliseconds(remaining));
        }
      }
      if (!running_) {
        break;
      }
      if (!coalescer_.Take(NowMs())) {
        // The burst is still arriving, or this was a spurious wake.
        continue;
      }
      handler = on_change_;
    }
    // Off the lock: the handler re-points the meter and emits, and the next
    // notification must not queue behind it.
    if (handler) {
      handler();
    }
  }

  if (registered) {
    // Detached first, so a notification already inside the client cannot reach
    // this object while the unregister is running.
    static_cast<Client*>(client.get())->Detach();
    enumerator->UnregisterEndpointNotificationCallback(client.get());
  }
  client = nullptr;
  enumerator = nullptr;
  if (SUCCEEDED(com)) {
    ::CoUninitialize();
  }
}

}  // namespace relay
