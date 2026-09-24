#include "camera_capture.h"

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <objbase.h>

#include <algorithm>
#include <cstring>
#include <utility>

namespace relay {

namespace {

bool ReadFrameSize(IMFSourceReader* reader, uint32_t* width, uint32_t* height) {
  winrt::com_ptr<IMFMediaType> current;
  if (FAILED(reader->GetCurrentMediaType(
          static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), current.put()))) {
    return false;
  }
  UINT32 frame_width = 0;
  UINT32 frame_height = 0;
  if (FAILED(::MFGetAttributeSize(current.get(), MF_MT_FRAME_SIZE, &frame_width,
                                  &frame_height)) ||
      frame_width == 0 || frame_height == 0) {
    return false;
  }
  *width = frame_width;
  *height = frame_height;
  return true;
}

LONG DefaultStrideFor(uint32_t width) {
  LONG stride = 0;
  if (FAILED(::MFGetStrideForBitmapInfoHeader(MFVideoFormat_RGB32.Data1, width,
                                              &stride))) {
    stride = static_cast<LONG>(width) * 4;
  }
  return stride;
}

// What the stream itself says its row order is, falling back to the format's
// convention only when it declines to say.
//
// MF_MT_DEFAULT_STRIDE is the attribute Media Foundation uses to state
// orientation, and it is the first thing Microsoft's own GetDefaultStride
// helper reads. Deriving the sign from the subtype and width alone — which is
// all DefaultStrideFor can do — asserts bottom-up for every BI_RGB format
// whatever the reader actually negotiated, and that assertion is how a frame
// gets flipped twice or not at all.
LONG NegotiatedStrideFor(IMFSourceReader* reader, uint32_t width) {
  winrt::com_ptr<IMFMediaType> current;
  UINT32 declared = 0;
  if (reader != nullptr &&
      SUCCEEDED(reader->GetCurrentMediaType(
          static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), current.put())) &&
      SUCCEEDED(current->GetUINT32(MF_MT_DEFAULT_STRIDE, &declared)) &&
      declared != 0) {
    // Stored as a UINT32 but defined as a signed stride: a bottom-up stream
    // carries the two's-complement negative, which is what the cast recovers.
    return static_cast<LONG>(static_cast<INT32>(declared));
  }
  return DefaultStrideFor(width);
}

}  // namespace

CameraCapture::~CameraCapture() {
  Stop();
}

void CameraCapture::SetDeviceId(std::string id) {
  device_id_ = std::move(id);
}

double CameraCapture::aspect_ratio() const {
  const uint32_t width = width_.load();
  const uint32_t height = height_.load();
  // 16:9 rather than square when nothing has been captured yet: the preview is
  // placed before the first frame arrives, and a square placeholder would put
  // it where the composited picture-in-picture is not.
  return height == 0 ? 16.0 / 9.0
                     : static_cast<double>(width) / static_cast<double>(height);
}

bool CameraCapture::Start(ID3D11Device* device, VideoCompositor* compositor,
                          PreviewHandler on_preview, ErrorHandler on_error,
                          LostHandler on_lost, std::string* error) {
  if (running_.load()) {
    return true;
  }
  if (device == nullptr) {
    *error = "The camera needs the capture Direct3D device.";
    return false;
  }
  // The capture thread self-exits on every failure path — no camera, stream
  // ended, read failure — leaving running_ false but the thread still
  // joinable. Assigning over a joinable std::thread calls std::terminate, so a
  // camera toggled back on after a failure would take the process down.
  if (thread_.joinable()) {
    thread_.join();
  }
  // A self-exit also leaves the device, its immediate context and the texture
  // pool held. Only Stop() releases them, and a camera toggled off after a
  // failure never reaches it: SetCameraEnabled(false) skips Stop() because
  // running() is already false. So release before re-acquiring — com_ptr::put()
  // asserts that it is writing into a null pointer, and a release build, where
  // that assert compiles out, would instead overwrite the raw pointer and leak
  // one reference on the immediate context — and through it the device and its
  // textures — on every retry.
  ReleaseResources();
  device_.copy_from(device);
  device_->GetImmediateContext(context_.put());
  compositor_ = compositor;
  on_preview_ = std::move(on_preview);
  on_error_ = std::move(on_error);
  on_lost_ = std::move(on_lost);
  stopping_.store(false);
  running_.store(true);
  {
    // Re-armed before the thread exists, so a wait cannot be answered by the
    // previous run's result.
    std::lock_guard<std::mutex> lock(open_mutex_);
    open_settled_ = false;
    opened_ = false;
  }
  thread_ = std::thread(&CameraCapture::CaptureThread, this);
  return true;
}

bool CameraCapture::WaitUntilOpen(std::chrono::milliseconds timeout) {
  std::unique_lock<std::mutex> lock(open_mutex_);
  // A timeout is not "still opening, ask again": the caller is holding a
  // recording open while it waits, and a camera that has not answered by then
  // is one to leave the previous device running for (spec 33.2).
  if (!open_cv_.wait_for(lock, timeout, [this] { return open_settled_; })) {
    return false;
  }
  return opened_;
}

void CameraCapture::SettleOpen(bool opened) {
  {
    std::lock_guard<std::mutex> lock(open_mutex_);
    if (open_settled_) {
      return;
    }
    open_settled_ = true;
    opened_ = opened;
  }
  open_cv_.notify_all();
}

void CameraCapture::Stop() {
  // ReadSample blocks until the next frame, so shutdown can lag by up to one
  // camera frame interval. Bounded and acceptable; a stalled camera device is
  // reported as a non-fatal error long before this.
  stopping_.store(true);
  running_.store(false);
  // Before the join, not after it: a stop that arrives while another thread is
  // still waiting on the handshake must not leave it there for the whole
  // timeout. Settling twice is a no-op, so the capture thread's own answer
  // still wins when it got there first.
  SettleOpen(false);
  if (thread_.joinable()) {
    thread_.join();
  }
  ReleaseResources();
}

// Drops everything one run acquired, so the next Start() begins from the same
// state a fresh object would. The capture thread must already be joined.
void CameraCapture::ReleaseResources() {
  textures_.clear();
  next_texture_ = 0;
  // Already null whenever the capture thread ran to its end: it releases the
  // reader on its own thread, before MFShutdown. Cleared here too so no path
  // out of the thread can leave the camera device open.
  reader_ = nullptr;
  context_ = nullptr;
  device_ = nullptr;
  compositor_ = nullptr;
}

void CameraCapture::ReportFailure(const std::string& message, HRESULT hr) {
  if (on_error_) {
    RecorderError error;
    error.code = RecorderErrorCode::kCameraUnavailable;
    error.message = message;
    error.details = HResultToString(hr);
    // The camera is optional: losing it degrades the session, it does not end it.
    error.fatal = false;
    on_error_(error);
  }
  // After the error, not before it: the owner's answer to this is to take the
  // camera off the control strip, and the reason for it should already be in
  // the log by then (spec 23, 26). macOS orders the two the same way —
  // `emitError` and then the reverted `emitInputs` (RecordingSession.swift).
  if (on_lost_) {
    on_lost_();
  }
}

bool CameraCapture::OpenReader(std::string* error) {
  winrt::com_ptr<IMFAttributes> device_attributes;
  HRESULT hr = ::MFCreateAttributes(device_attributes.put(), 1);
  if (FAILED(hr)) {
    *error = "The camera enumerator could not be created.";
    return false;
  }
  device_attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                             MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);

  IMFActivate** devices = nullptr;
  UINT32 count = 0;
  hr = ::MFEnumDeviceSources(device_attributes.get(), &devices, &count);
  if (FAILED(hr) || count == 0) {
    if (devices != nullptr) {
      ::CoTaskMemFree(devices);
    }
    *error = "No camera is available.";
    return false;
  }

  // The symbolic link of every enumerated source, in Media Foundation's own
  // order, so a configured id picks the same entry `getInputDevices` reported
  // and a `null` one still picks the first source — exactly what this capture
  // opened before device selection existed (input_devices.cpp).
  std::vector<MediaDeviceInfo> enumerated;
  enumerated.reserve(count);
  for (UINT32 i = 0; i < count; ++i) {
    MediaDeviceInfo info;
    info.kind = MediaDeviceKind::kCamera;
    LPWSTR link = nullptr;
    UINT32 link_length = 0;
    if (SUCCEEDED(devices[i]->GetAllocatedString(
            MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, &link,
            &link_length)) &&
        link != nullptr) {
      info.id = Narrow(link);
      ::CoTaskMemFree(link);
    }
    enumerated.push_back(std::move(info));
  }
  // The same filter the enumeration applies, and by the same rule: a source
  // with no symbolic link has no id, so it is one `getInputDevices` cannot list
  // and one this capture must not open behind the list's back. `sources` maps
  // the selection back onto Media Foundation's own array.
  std::vector<size_t> sources;
  RetainSelectableCameras(&enumerated, &sources);
  const size_t selected = SelectDeviceIndex(enumerated, device_id_);
  if (selected == kNoDeviceIndex) {
    for (UINT32 i = 0; i < count; ++i) {
      devices[i]->Release();
    }
    ::CoTaskMemFree(devices);
    *error = "No camera is available.";
    return false;
  }
  const UINT32 index = static_cast<UINT32>(sources[selected]);
  // A chosen camera that no longer resolves degrades to the default rather
  // than failing prepare (spec 33.2). Reported once the stream is actually
  // open, so a camera that then fails to open reports that instead.
  const bool fell_back = !device_id_.empty() && enumerated[selected].id != device_id_;

  winrt::com_ptr<IMFMediaSource> source;
  hr = devices[index]->ActivateObject(__uuidof(IMFMediaSource), source.put_void());
  for (UINT32 i = 0; i < count; ++i) {
    devices[i]->Release();
  }
  ::CoTaskMemFree(devices);
  if (FAILED(hr)) {
    *error = "The camera could not be opened. It may be in use by another app.";
    return false;
  }

  winrt::com_ptr<IMFAttributes> reader_attributes;
  hr = ::MFCreateAttributes(reader_attributes.put(), 2);
  if (FAILED(hr)) {
    source->Shutdown();
    *error = "The camera reader could not be configured.";
    return false;
  }
  // Lets the reader insert a converter so every camera lands on one BGRA path.
  reader_attributes->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
  reader_attributes->SetUINT32(MF_SOURCE_READER_DISABLE_DXVA, TRUE);

  hr = ::MFCreateSourceReaderFromMediaSource(source.get(), reader_attributes.get(),
                                             reader_.put());
  if (FAILED(hr)) {
    source->Shutdown();
    *error = "The camera stream could not be opened.";
    return false;
  }

  winrt::com_ptr<IMFMediaType> output;
  hr = ::MFCreateMediaType(output.put());
  if (FAILED(hr)) {
    *error = "The camera output format could not be built.";
    return false;
  }
  output->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  output->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  hr = reader_->SetCurrentMediaType(
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), nullptr, output.get());
  if (FAILED(hr)) {
    *error = "The camera does not offer a usable video format.";
    return false;
  }

  uint32_t width = 0;
  uint32_t height = 0;
  if (!ReadFrameSize(reader_.get(), &width, &height)) {
    *error = "The camera did not report a usable frame size.";
    return false;
  }

  // Now that the frame size is known, ask for top-down rows outright. Media
  // Foundation treats every BI_RGB subtype as bottom-up by default, so the row
  // order was previously decided by a convention nobody restated — and the
  // first Windows run photographed the picture upside down. A positive
  // MF_MT_DEFAULT_STRIDE on the requested type is the documented way to say
  // "top-down", and the reader's own converter (enabled above) is what honours
  // it.
  //
  // Best-effort by design: a camera that refuses is not a camera this
  // application drops, and the previously negotiated type is still in force
  // when the call fails. Whatever the outcome, NegotiatedStride reads back what
  // was actually agreed rather than assuming the request won.
  //
  // The frame size is pinned into the request and read back afterwards.
  // SetCurrentMediaType does not write the negotiated attributes into the
  // caller's type, so this partial type would otherwise send the reader back
  // through its whole native-type search — and a camera that offers several
  // resolutions could settle on a different one, leaving width_/height_
  // describing a frame that is no longer being delivered.
  ::MFSetAttributeSize(output.get(), MF_MT_FRAME_SIZE, width, height);
  output->SetUINT32(MF_MT_DEFAULT_STRIDE, static_cast<UINT32>(width * 4));
  if (SUCCEEDED(reader_->SetCurrentMediaType(
          static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), nullptr,
          output.get())) &&
      !ReadFrameSize(reader_.get(), &width, &height)) {
    *error = "The camera did not report a usable frame size.";
    return false;
  }
  width_.store(width);
  height_.store(height);
  if (fell_back && on_error_) {
    RecorderError fallback;
    fallback.code = RecorderErrorCode::kCameraUnavailable;
    fallback.message =
        "The chosen camera is no longer available. Recording the default camera "
        "instead.";
    fallback.details = device_id_;
    fallback.fatal = false;
    on_error_(fallback);
  }
  return true;
}

bool CameraCapture::EnsureTexturePool(uint32_t width, uint32_t height,
                                      std::string* error) {
  if (!textures_.empty()) {
    D3D11_TEXTURE2D_DESC existing{};
    textures_.front()->GetDesc(&existing);
    if (existing.Width == width && existing.Height == height) {
      return true;
    }
    // The camera renegotiated its frame size: the pooled textures no longer
    // describe the frames being published.
    textures_.clear();
    next_texture_ = 0;
  }
  // These textures are bound as an input stream of the D3D11 video processor
  // (VideoCompositor::InputViewFor), and that imposes the whole descriptor.
  // CreateVideoProcessorInputView requires D3D11_USAGE_DEFAULT and accepts only
  // bind flags drawn from DECODER / VIDEO_ENCODER / RENDER_TARGET /
  // UNORDERED_ACCESS (or none at all); a DYNAMIC texture bound
  // SHADER_RESOURCE — which is what this was — is rejected, and the rejection
  // is silent, a null view rather than a device-removed. That failure took the
  // entire video track down with it in every Windows recording with the camera
  // on: the compose step failed for every frame from the camera's first one
  // onwards, so the file held ~9 frames of picture and 46 seconds of audio.
  //
  // RENDER_TARGET is the flag from the allowed set that a colour-conversion
  // blit is entitled to; SHADER_RESOURCE is kept because it costs nothing and
  // keeps the surface usable if the tile is ever drawn some other way.
  D3D11_TEXTURE2D_DESC desc{};
  desc.Width = width;
  desc.Height = height;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
  desc.CPUAccessFlags = 0;
  for (size_t i = 0; i < kTexturePoolSize; ++i) {
    winrt::com_ptr<ID3D11Texture2D> texture;
    const HRESULT hr = device_->CreateTexture2D(&desc, nullptr, texture.put());
    if (FAILED(hr)) {
      textures_.clear();
      // Said out loud rather than returned as a bare false. Without a pool no
      // camera pixel can reach the compositor, and this used to fail in
      // silence: the preview went on showing a live picture for the whole
      // recording while the file held none of it, and nothing was logged
      // (CLAUDE.md "Camera is composited into the final video", spec 26).
      *error = "The camera's frame buffers could not be allocated (" +
               HResultToString(hr) + ").";
      return false;
    }
    textures_.push_back(std::move(texture));
  }
  return true;
}

void CameraCapture::PublishFrame(const uint8_t* pixels, uint32_t width, uint32_t height,
                                 int32_t stride) {
  if (pixels == nullptr || width == 0 || height == 0) {
    return;
  }
  const uint8_t* top_down = pixels;
  const uint32_t row_bytes = width * 4;
  if (stride < 0) {
    // RGB32 buffers are bottom-up by convention; flip once, here, so nothing
    // downstream has to care.
    flip_scratch_.resize(static_cast<size_t>(row_bytes) * height);
    const uint32_t absolute = static_cast<uint32_t>(-stride);
    for (uint32_t row = 0; row < height; ++row) {
      std::memcpy(flip_scratch_.data() + static_cast<size_t>(row) * row_bytes,
                  pixels - static_cast<size_t>(row) * absolute, row_bytes);
    }
    top_down = flip_scratch_.data();
    stride = static_cast<int32_t>(row_bytes);
  }

  // The compositor is served first and the preview only afterwards. The preview
  // used to go first and the compose path return in silence, which is how a
  // recording ended up with a live camera on screen for its whole length and
  // not one camera pixel in the file — the one thing the preview is not allowed
  // to be is the livelier of the two
  // (docs/adr/2026-08-30-user-adjustable-camera-pip.md, CLAUDE.md "Camera is
  // composited into the final video").
  if (compositor_ == nullptr) {
    return;  // nothing to compose into: this frame belongs to no recording
  }
  std::string pool_error;
  if (!EnsureTexturePool(width, height, &pool_error)) {
    // Reported once and the capture ended, not retried per frame. The
    // descriptor does not change between frames, so a pool that cannot be
    // allocated for this frame cannot be allocated for the next one either, and
    // reporting per frame would post a channel event at the camera's frame rate
    // onto the thread the whole UI is drawn on (RecordingSession::
    // OnCapturedFrame makes the same argument about composition failures).
    // Ending the capture is also what takes the tile off the control strip and
    // stops the preview, so the two go on agreeing (spec 23).
    ReportFailure(pool_error, E_FAIL);
    running_.store(false);
    return;
  }
  const winrt::com_ptr<ID3D11Texture2D> texture = textures_[next_texture_];
  next_texture_ = (next_texture_ + 1) % textures_.size();

  // The shape the compositor is going to draw this frame in, asked for here
  // because here is where the pixels are already being touched: the fourth byte
  // of MFVideoFormat_RGB32 is undefined, so it has to be written on every path
  // anyway, and writing the mask's coverage into it instead of a blind 255
  // costs a compare per pixel (video_compositor.h).
  const CameraFrameMask mask = compositor_->CameraMask(width, height);

  // Staged in system memory and uploaded in one call: the pool is
  // D3D11_USAGE_DEFAULT, which cannot be mapped, because that is what the video
  // processor requires of an input surface. Three textures rotate, so the copy
  // does not land in the one the compositor is reading.
  upload_scratch_.resize(static_cast<size_t>(row_bytes) * height);
  // A rectangular mask needs no shape in the alpha channel at all: the crop is
  // the stream's source rectangle, so what lies outside it is never read, and
  // the compositor does not blend an unrounded tile. Only the fourth byte still
  // has to be written, because Media Foundation leaves it undefined.
  const bool rectangular = CameraMaskIsRectangular(mask);
  for (uint32_t row = 0; row < height; ++row) {
    uint8_t* line = upload_scratch_.data() + static_cast<size_t>(row) * row_bytes;
    std::memcpy(line,
                top_down + static_cast<size_t>(row) * static_cast<uint32_t>(stride),
                row_bytes);
    if (rectangular) {
      for (uint32_t column = 0; column < width; ++column) {
        line[static_cast<size_t>(column) * 4 + 3] = 0xFF;
      }
      continue;
    }
    ApplyCameraMaskRow(mask, static_cast<double>(row) + 0.5, width, line);
  }
  context_->UpdateSubresource(texture.get(), 0, nullptr, upload_scratch_.data(),
                              row_bytes, 0);
  compositor_->SetCameraFrame(texture, width, height);

  // Reached only by a frame the compositor already holds, which is what lets
  // the owner read this as the camera reaching the recording rather than as the
  // camera reaching a window (RecordingSession::StartCamera).
  if (on_preview_) {
    on_preview_(top_down, width, height, static_cast<uint32_t>(stride));
  }
}

void CameraCapture::CaptureThread() {
  const HRESULT com = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const HRESULT startup = ::MFStartup(MF_VERSION, MFSTARTUP_LITE);
  if (FAILED(startup)) {
    ReportFailure("Media Foundation could not be started for the camera.", startup);
    SettleOpen(false);
    running_.store(false);
    if (SUCCEEDED(com)) {
      ::CoUninitialize();
    }
    return;
  }

  std::string error;
  if (!OpenReader(&error)) {
    SettleOpen(false);
    ReportFailure(error, E_FAIL);
  } else {
    SettleOpen(true);
    LONG default_stride = NegotiatedStrideFor(reader_.get(), width_.load());

    while (running_.load() && !stopping_.load()) {
      DWORD stream_flags = 0;
      LONGLONG timestamp = 0;
      winrt::com_ptr<IMFSample> sample;
      const HRESULT hr = reader_->ReadSample(
          static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0, nullptr,
          &stream_flags, &timestamp, sample.put());
      if (FAILED(hr)) {
        ReportFailure("The camera stopped delivering frames.", hr);
        break;
      }
      if ((stream_flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) {
        ReportFailure("The camera stream ended.", S_OK);
        break;
      }
      if ((stream_flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) != 0) {
        // The reader renegotiated mid-stream: the cached size no longer
        // describes the buffers, and reading a smaller frame as the old one
        // walks off the end of it.
        uint32_t new_width = 0;
        uint32_t new_height = 0;
        if (!ReadFrameSize(reader_.get(), &new_width, &new_height)) {
          ReportFailure("The camera changed to a format that cannot be read.", E_FAIL);
          break;
        }
        width_.store(new_width);
        height_.store(new_height);
        default_stride = NegotiatedStrideFor(reader_.get(), new_width);
      }
      if (!sample) {
        continue;  // a gap, not an error
      }

      winrt::com_ptr<IMFMediaBuffer> buffer;
      if (FAILED(sample->ConvertToContiguousBuffer(buffer.put()))) {
        continue;
      }
      const winrt::com_ptr<IMF2DBuffer> two_d = buffer.try_as<IMF2DBuffer>();
      const uint32_t width = width_.load();
      const uint32_t height = height_.load();
      // A buffer shorter than the frame the reader promised is skipped rather
      // than copied out of bounds.
      const uint64_t frame_bytes = static_cast<uint64_t>(width) * 4u * height;
      if (two_d) {
        DWORD contiguous = 0;
        BYTE* scanline = nullptr;
        LONG pitch = 0;
        if (SUCCEEDED(two_d->GetContiguousLength(&contiguous)) &&
            static_cast<uint64_t>(contiguous) >= frame_bytes &&
            SUCCEEDED(two_d->Lock2D(&scanline, &pitch))) {
          PublishFrame(scanline, width, height, static_cast<int32_t>(pitch));
          two_d->Unlock2D();
        }
      } else {
        BYTE* data = nullptr;
        DWORD length = 0;
        if (SUCCEEDED(buffer->Lock(&data, nullptr, &length))) {
          const uint64_t stride_bytes = static_cast<uint64_t>(
              default_stride < 0 ? -default_stride : default_stride);
          if (static_cast<uint64_t>(length) >= stride_bytes * height) {
            const uint8_t* start = data;
            if (default_stride < 0) {
              start = data + static_cast<size_t>(-default_stride) * (height - 1);
            }
            PublishFrame(start, width, height, static_cast<int32_t>(default_stride));
          }
          buffer->Unlock();
        }
      }
    }
  }

  reader_ = nullptr;
  ::MFShutdown();
  if (SUCCEEDED(com)) {
    ::CoUninitialize();
  }
  running_.store(false);
}

}  // namespace relay
