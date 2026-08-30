#ifndef RELAY_CAMERA_CAPTURE_H_
#define RELAY_CAMERA_CAPTURE_H_

#include <windows.h>
// Order matters: mfreadwrite.h needs the Media Foundation object model from
// mfidl.h, and both need the Win32 base types.

#include <d3d11.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <winrt/base.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "recorder_types.h"
#include "video_compositor.h"

namespace relay {

// Media Foundation capture of the default camera.
//
// The same frames feed the compositor (which draws the picture-in-picture into
// the file) and the preview overlay. The preview is never the path into the
// encoder: screen capture must not be how the camera reaches the video (spec 7,
// media-pipeline "Camera").
class CameraCapture {
 public:
  // Receives top-down BGRA. Called on the camera thread; implementations must
  // copy and return, never block.
  using PreviewHandler = std::function<void(const uint8_t* bgra, uint32_t width,
                                            uint32_t height, uint32_t stride)>;
  using ErrorHandler = std::function<void(const RecorderError&)>;

  CameraCapture() = default;
  ~CameraCapture();

  CameraCapture(const CameraCapture&) = delete;
  CameraCapture& operator=(const CameraCapture&) = delete;

  bool Start(ID3D11Device* device, VideoCompositor* compositor,
             PreviewHandler on_preview, ErrorHandler on_error, std::string* error);

  // Waits for the capture thread to settle on whether it has a stream, and
  // reports what it settled on. False on a timeout as well as on a failure.
  //
  // Start() returns as soon as the thread exists — opening a Media Foundation
  // source takes long enough that doing it on the caller's thread would stall
  // whoever asked — so a swap that has to leave the previous camera running
  // until the new one is really open has no other way to know (spec 33.2). Safe
  // to call more than once; each call answers from the same settled result.
  bool WaitUntilOpen(std::chrono::milliseconds timeout);

  // Idempotent.
  void Stop();

  // The camera to open, or empty for the first source Media Foundation
  // enumerates — which is exactly what this capture opened before device
  // selection existed. Set before Start; an id that no longer resolves falls
  // back to that first source and reports a non-fatal error rather than
  // failing the recording (spec 33.2).
  void SetDeviceId(std::string id);

  bool running() const { return running_.load(); }
  uint32_t width() const { return width_.load(); }
  uint32_t height() const { return height_.load(); }
  double aspect_ratio() const;

 private:
  void CaptureThread();
  bool OpenReader(std::string* error);
  bool EnsureTexturePool(uint32_t width, uint32_t height);
  void PublishFrame(const uint8_t* pixels, uint32_t width, uint32_t height,
                    int32_t stride);
  void ReportFailure(const std::string& message, HRESULT hr);
  void ReleaseResources();
  // Releases whoever is waiting in WaitUntilOpen with the answer.
  void SettleOpen(bool opened);

  winrt::com_ptr<ID3D11Device> device_;
  winrt::com_ptr<ID3D11DeviceContext> context_;
  winrt::com_ptr<IMFSourceReader> reader_;
  VideoCompositor* compositor_ = nullptr;
  std::string device_id_;
  PreviewHandler on_preview_;
  ErrorHandler on_error_;

  // Three staging textures rotate so the compositor can hold the newest frame
  // while the next one is uploaded. Bounded and allocated once.
  static constexpr size_t kTexturePoolSize = 3;
  std::vector<winrt::com_ptr<ID3D11Texture2D>> textures_;
  size_t next_texture_ = 0;
  std::vector<uint8_t> flip_scratch_;

  std::thread thread_;
  std::atomic<bool> running_{false};
  std::atomic<bool> stopping_{false};
  std::atomic<uint32_t> width_{0};
  std::atomic<uint32_t> height_{0};

  // Whether the capture thread has decided it has a stream, and what it
  // decided. Written once per run by that thread, read by whoever is waiting on
  // the handshake above.
  std::mutex open_mutex_;
  std::condition_variable open_cv_;
  bool open_settled_ = false;
  bool opened_ = false;
};

}  // namespace relay

#endif  // RELAY_CAMERA_CAPTURE_H_
