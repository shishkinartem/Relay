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
                          std::string* error) {
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
  stopping_.store(false);
  running_.store(true);
  thread_ = std::thread(&CameraCapture::CaptureThread, this);
  return true;
}

void CameraCapture::Stop() {
  // ReadSample blocks until the next frame, so shutdown can lag by up to one
  // camera frame interval. Bounded and acceptable; a stalled camera device is
  // reported as a non-fatal error long before this.
  stopping_.store(true);
  running_.store(false);
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
  if (!on_error_) {
    return;
  }
  RecorderError error;
  error.code = RecorderErrorCode::kCameraUnavailable;
  error.message = message;
  error.details = HResultToString(hr);
  // The camera is optional: losing it degrades the session, it does not end it.
  error.fatal = false;
  on_error_(error);
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

bool CameraCapture::EnsureTexturePool(uint32_t width, uint32_t height) {
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
  D3D11_TEXTURE2D_DESC desc{};
  desc.Width = width;
  desc.Height = height;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_DYNAMIC;
  desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
  desc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
  for (size_t i = 0; i < kTexturePoolSize; ++i) {
    winrt::com_ptr<ID3D11Texture2D> texture;
    if (FAILED(device_->CreateTexture2D(&desc, nullptr, texture.put()))) {
      textures_.clear();
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

  if (on_preview_) {
    on_preview_(top_down, width, height, static_cast<uint32_t>(stride));
  }

  if (compositor_ == nullptr || !EnsureTexturePool(width, height)) {
    return;
  }
  const winrt::com_ptr<ID3D11Texture2D> texture = textures_[next_texture_];
  next_texture_ = (next_texture_ + 1) % textures_.size();

  D3D11_MAPPED_SUBRESOURCE mapped{};
  if (FAILED(context_->Map(texture.get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped))) {
    return;
  }
  auto* destination = static_cast<uint8_t*>(mapped.pData);
  for (uint32_t row = 0; row < height; ++row) {
    std::memcpy(destination + static_cast<size_t>(row) * mapped.RowPitch,
                top_down + static_cast<size_t>(row) * static_cast<uint32_t>(stride),
                row_bytes);
  }
  context_->Unmap(texture.get(), 0);
  compositor_->SetCameraFrame(texture, width, height);
}

void CameraCapture::CaptureThread() {
  const HRESULT com = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const HRESULT startup = ::MFStartup(MF_VERSION, MFSTARTUP_LITE);
  if (FAILED(startup)) {
    ReportFailure("Media Foundation could not be started for the camera.", startup);
    running_.store(false);
    if (SUCCEEDED(com)) {
      ::CoUninitialize();
    }
    return;
  }

  std::string error;
  if (!OpenReader(&error)) {
    ReportFailure(error, E_FAIL);
  } else {
    LONG default_stride = DefaultStrideFor(width_.load());

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
        default_stride = DefaultStrideFor(new_width);
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
