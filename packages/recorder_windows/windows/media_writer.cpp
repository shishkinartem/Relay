#include "media_writer.h"

#include <codecapi.h>
#include <mfapi.h>
#include <mferror.h>

#include <algorithm>
#include <cmath>
#include <cstring>

namespace relay {

namespace {

constexpr uint32_t kAudioBytesPerSecond = 24000;  // 192 kbps AAC (spec 12)
constexpr uint32_t kAudioBitsPerSample = 16;

RecorderErrorCode MapWriteFailure(HRESULT hr) {
  if (hr == HRESULT_FROM_WIN32(ERROR_DISK_FULL) ||
      hr == HRESULT_FROM_WIN32(ERROR_HANDLE_DISK_FULL)) {
    return RecorderErrorCode::kDiskFull;
  }
  return RecorderErrorCode::kEncodingFailed;
}

void Fail(RecorderError* error, RecorderErrorCode code, std::string message, HRESULT hr) {
  if (error == nullptr) {
    return;
  }
  error->code = code;
  error->message = std::move(message);
  error->details = HResultToString(hr);
  error->fatal = true;
}

int16_t ToPcm16(float sample) {
  const float clamped = (std::max)(-1.0f, (std::min)(1.0f, sample));
  return static_cast<int16_t>(clamped * 32767.0f);
}

}  // namespace

MediaWriter::~MediaWriter() {
  Abort();
}

uint32_t MediaWriter::RecommendedBitrate(uint32_t width, uint32_t height,
                                         uint32_t frame_rate) {
  // Quality-oriented VBR, not a user-facing setting (spec 11). Screen content
  // at roughly 0.1 bits per pixel at 30 fps, scaled sub-linearly with frame
  // rate because consecutive screen frames are highly correlated. 1080p30 lands
  // near 6 Mbps, matching the capacity-planning example in spec 12.
  const double pixels = static_cast<double>(width) * static_cast<double>(height);
  const double fps_scale = std::sqrt((std::max)(1.0, static_cast<double>(frame_rate)) / 30.0);
  const double bitrate = pixels * 30.0 * 0.10 * fps_scale;
  const double clamped = (std::max)(2000000.0, (std::min)(20000000.0, bitrate));
  return static_cast<uint32_t>(clamped);
}

bool MediaWriter::Open(const Config& config, ID3D11Device* device, RecorderError* error) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (writing_) {
    return true;
  }
  config_ = config;

  const HRESULT startup = ::MFStartup(MF_VERSION, MFSTARTUP_LITE);
  if (FAILED(startup)) {
    Fail(error, RecorderErrorCode::kEncodingFailed,
         "Media Foundation could not be started.", startup);
    return false;
  }
  media_foundation_started_ = true;

  // Hardware first; a software fallback keeps recording possible on adapters
  // without an H.264 encoder (spec 11, 22).
  if (OpenInternal(true, device, nullptr)) {
    return true;
  }
  ResetForRetry();
  if (OpenInternal(false, nullptr, error)) {
    return true;
  }
  Close();
  return false;
}

bool MediaWriter::OpenInternal(bool allow_hardware, ID3D11Device* device,
                               RecorderError* error) {
  winrt::com_ptr<IMFAttributes> attributes;
  HRESULT hr = ::MFCreateAttributes(attributes.put(), 6);
  if (FAILED(hr)) {
    Fail(error, RecorderErrorCode::kEncodingFailed,
         "The encoder could not be configured.", hr);
    return false;
  }
  // Fragmented MP4, not plain MP4. Plain MPEG4 writes the `moov` atom only in
  // `Finalize()`, and `RecordingSession::Abort()` deliberately never calls it —
  // so an aborted `.part` had no index and `Probe` could not read a single
  // frame of it. That made the spec 18 recovery guarantee true on macOS, which
  // sets `movieFragmentInterval`, and false here, with nothing on the Dart side
  // able to tell the two apart.
  // See docs/adr/2026-08-23-fragmented-mp4-on-both-platforms.md.
  attributes->SetGUID(MF_TRANSCODE_CONTAINERTYPE, MFTranscodeContainerType_FMPEG4);
  attributes->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, allow_hardware ? 1 : 0);
  attributes->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, 1);

  use_dxgi_buffers_ = false;
  if (allow_hardware && device != nullptr) {
    UINT token = 0;
    if (SUCCEEDED(::MFCreateDXGIDeviceManager(&token, device_manager_.put())) &&
        SUCCEEDED(device_manager_->ResetDevice(device, token))) {
      attributes->SetUnknown(MF_SINK_WRITER_D3D_MANAGER, device_manager_.get());
      use_dxgi_buffers_ = true;
      device_.copy_from(device);
      device_->GetImmediateContext(context_.put());
    } else {
      device_manager_ = nullptr;
    }
  }

  hr = ::MFCreateSinkWriterFromURL(config_.part_path.c_str(), nullptr, attributes.get(),
                                   writer_.put());
  if (FAILED(hr)) {
    Fail(error,
         hr == HRESULT_FROM_WIN32(ERROR_DISK_FULL) ? RecorderErrorCode::kDiskFull
                                                   : RecorderErrorCode::kEncodingFailed,
         "The recording file could not be opened for writing.", hr);
    return false;
  }

  winrt::com_ptr<IMFMediaType> video_out;
  hr = ::MFCreateMediaType(video_out.put());
  if (FAILED(hr)) {
    Fail(error, RecorderErrorCode::kEncodingFailed, "The video stream type failed.", hr);
    return false;
  }
  video_out->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  video_out->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  video_out->SetUINT32(MF_MT_AVG_BITRATE, RecommendedBitrate(config_.width, config_.height,
                                                             config_.frame_rate));
  video_out->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  video_out->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_High);
  ::MFSetAttributeSize(video_out.get(), MF_MT_FRAME_SIZE, config_.width, config_.height);
  ::MFSetAttributeRatio(video_out.get(), MF_MT_FRAME_RATE, config_.frame_rate, 1);
  ::MFSetAttributeRatio(video_out.get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  hr = writer_->AddStream(video_out.get(), &video_stream_);
  if (FAILED(hr)) {
    Fail(error, RecorderErrorCode::kEncodingFailed,
         "No H.264 encoder accepted the requested output.", hr);
    return false;
  }

  winrt::com_ptr<IMFMediaType> video_in;
  hr = ::MFCreateMediaType(video_in.put());
  if (FAILED(hr)) {
    Fail(error, RecorderErrorCode::kEncodingFailed, "The video input type failed.", hr);
    return false;
  }
  video_in->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  video_in->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
  video_in->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  ::MFSetAttributeSize(video_in.get(), MF_MT_FRAME_SIZE, config_.width, config_.height);
  ::MFSetAttributeRatio(video_in.get(), MF_MT_FRAME_RATE, config_.frame_rate, 1);
  ::MFSetAttributeRatio(video_in.get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  hr = writer_->SetInputMediaType(video_stream_, video_in.get(), nullptr);
  if (FAILED(hr)) {
    Fail(error, RecorderErrorCode::kEncodingFailed,
         "The encoder rejected the composed video format.", hr);
    return false;
  }

  has_audio_stream_ = false;
  if (config_.has_audio) {
    winrt::com_ptr<IMFMediaType> audio_out;
    winrt::com_ptr<IMFMediaType> audio_in;
    if (SUCCEEDED(::MFCreateMediaType(audio_out.put())) &&
        SUCCEEDED(::MFCreateMediaType(audio_in.put()))) {
      audio_out->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
      audio_out->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
      audio_out->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, kAudioBitsPerSample);
      audio_out->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, kMixSampleRate);
      audio_out->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, kMixChannels);
      audio_out->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, kAudioBytesPerSecond);
      audio_out->SetUINT32(MF_MT_AAC_PAYLOAD_TYPE, 0);

      audio_in->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
      audio_in->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
      audio_in->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, kAudioBitsPerSample);
      audio_in->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, kMixSampleRate);
      audio_in->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, kMixChannels);
      audio_in->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT,
                          kMixChannels * kAudioBitsPerSample / 8);
      audio_in->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                          kMixSampleRate * kMixChannels * kAudioBitsPerSample / 8);

      if (SUCCEEDED(writer_->AddStream(audio_out.get(), &audio_stream_)) &&
          SUCCEEDED(writer_->SetInputMediaType(audio_stream_, audio_in.get(), nullptr))) {
        has_audio_stream_ = true;
      }
    }
  }

  hr = writer_->BeginWriting();
  if (FAILED(hr)) {
    Fail(error, MapWriteFailure(hr), "The recording could not be started.", hr);
    return false;
  }

  hardware_encoding_ = allow_hardware;
  encoder_name_ = allow_hardware ? "Media Foundation H.264 (hardware preferred)"
                                 : "Media Foundation H.264 (software)";
  writing_ = true;
  finalized_ = false;
  return true;
}

bool MediaWriter::EnsureStagingTexture(ID3D11Texture2D* source, RecorderError* error) {
  if (staging_) {
    return true;
  }
  if (!device_) {
    winrt::com_ptr<ID3D11Device> device;
    source->GetDevice(device.put());
    device_ = device;
    if (device_) {
      device_->GetImmediateContext(context_.put());
    }
  }
  if (!device_ || !context_) {
    Fail(error, RecorderErrorCode::kEncodingFailed,
         "The composed frame could not be read back.", E_FAIL);
    return false;
  }
  D3D11_TEXTURE2D_DESC desc{};
  source->GetDesc(&desc);
  desc.Usage = D3D11_USAGE_STAGING;
  desc.BindFlags = 0;
  desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  desc.MiscFlags = 0;
  const HRESULT hr = device_->CreateTexture2D(&desc, nullptr, staging_.put());
  if (FAILED(hr)) {
    Fail(error, RecorderErrorCode::kEncodingFailed,
         "The frame read-back surface could not be allocated.", hr);
    return false;
  }
  return true;
}

bool MediaWriter::CopyTextureToBuffer(ID3D11Texture2D* nv12,
                                      winrt::com_ptr<IMFMediaBuffer>* buffer,
                                      RecorderError* error) {
  if (!EnsureStagingTexture(nv12, error)) {
    return false;
  }
  context_->CopyResource(staging_.get(), nv12);
  D3D11_MAPPED_SUBRESOURCE mapped{};
  HRESULT hr = context_->Map(staging_.get(), 0, D3D11_MAP_READ, 0, &mapped);
  if (FAILED(hr)) {
    Fail(error, RecorderErrorCode::kEncodingFailed, "A composed frame could not be read.",
         hr);
    return false;
  }

  const uint32_t width = config_.width;
  const uint32_t height = config_.height;
  const DWORD length = width * height * 3 / 2;  // NV12
  winrt::com_ptr<IMFMediaBuffer> memory;
  hr = ::MFCreateMemoryBuffer(length, memory.put());
  BYTE* destination = nullptr;
  if (SUCCEEDED(hr)) {
    hr = memory->Lock(&destination, nullptr, nullptr);
  }
  if (FAILED(hr) || destination == nullptr) {
    context_->Unmap(staging_.get(), 0);
    Fail(error, RecorderErrorCode::kEncodingFailed, "An encoder buffer was refused.", hr);
    return false;
  }
  const auto* source = static_cast<const uint8_t*>(mapped.pData);
  for (uint32_t row = 0; row < height; ++row) {
    std::memcpy(destination + row * width, source + row * mapped.RowPitch, width);
  }
  const uint8_t* chroma = source + static_cast<size_t>(mapped.RowPitch) * height;
  BYTE* chroma_destination = destination + static_cast<size_t>(width) * height;
  for (uint32_t row = 0; row < height / 2; ++row) {
    std::memcpy(chroma_destination + row * width, chroma + row * mapped.RowPitch, width);
  }
  memory->Unlock();
  memory->SetCurrentLength(length);
  context_->Unmap(staging_.get(), 0);
  *buffer = memory;
  return true;
}

bool MediaWriter::WriteVideoFrame(ID3D11Texture2D* nv12, int64_t timestamp_100ns,
                                  int64_t duration_100ns, RecorderError* error) {
  if (!writing_ || nv12 == nullptr) {
    return false;
  }
  winrt::com_ptr<IMFMediaBuffer> buffer;
  if (use_dxgi_buffers_) {
    const HRESULT hr = ::MFCreateDXGISurfaceBuffer(__uuidof(ID3D11Texture2D), nv12, 0,
                                                   FALSE, buffer.put());
    if (SUCCEEDED(hr)) {
      const winrt::com_ptr<IMF2DBuffer> two_d = buffer.try_as<IMF2DBuffer>();
      DWORD length = 0;
      if (two_d && SUCCEEDED(two_d->GetContiguousLength(&length))) {
        buffer->SetCurrentLength(length);
      }
    } else {
      // One failure is enough: fall back to system memory for the rest of the
      // session rather than retrying per frame.
      use_dxgi_buffers_ = false;
      buffer = nullptr;
    }
  }
  if (!buffer && !CopyTextureToBuffer(nv12, &buffer, error)) {
    return false;
  }

  winrt::com_ptr<IMFSample> sample;
  HRESULT hr = ::MFCreateSample(sample.put());
  if (SUCCEEDED(hr)) {
    hr = sample->AddBuffer(buffer.get());
  }
  if (SUCCEEDED(hr)) {
    sample->SetSampleTime(timestamp_100ns);
    sample->SetSampleDuration(duration_100ns);
    hr = writer_->WriteSample(video_stream_, sample.get());
  }
  if (FAILED(hr)) {
    Fail(error, MapWriteFailure(hr), "The recording could not be written to disk.", hr);
    return false;
  }
  encoded_video_frames_.fetch_add(1);
  last_video_100ns_.store(timestamp_100ns);
  return true;
}

bool MediaWriter::WriteAudioFrames(const float* interleaved_stereo, size_t frames,
                                   int64_t timestamp_100ns, RecorderError* error) {
  if (!writing_ || !has_audio_stream_ || interleaved_stereo == nullptr || frames == 0) {
    return true;
  }
  const size_t sample_count = frames * kMixChannels;
  pcm_scratch_.resize(sample_count);
  for (size_t i = 0; i < sample_count; ++i) {
    pcm_scratch_[i] = ToPcm16(interleaved_stereo[i]);
  }
  const DWORD length = static_cast<DWORD>(sample_count * sizeof(int16_t));

  winrt::com_ptr<IMFMediaBuffer> buffer;
  HRESULT hr = ::MFCreateMemoryBuffer(length, buffer.put());
  BYTE* destination = nullptr;
  if (SUCCEEDED(hr)) {
    hr = buffer->Lock(&destination, nullptr, nullptr);
  }
  if (FAILED(hr) || destination == nullptr) {
    Fail(error, RecorderErrorCode::kEncodingFailed, "An audio buffer was refused.", hr);
    return false;
  }
  std::memcpy(destination, pcm_scratch_.data(), length);
  buffer->Unlock();
  buffer->SetCurrentLength(length);

  winrt::com_ptr<IMFSample> sample;
  hr = ::MFCreateSample(sample.put());
  if (SUCCEEDED(hr)) {
    hr = sample->AddBuffer(buffer.get());
  }
  if (SUCCEEDED(hr)) {
    sample->SetSampleTime(timestamp_100ns);
    sample->SetSampleDuration(static_cast<int64_t>(frames) * 10000000LL / kMixSampleRate);
    hr = writer_->WriteSample(audio_stream_, sample.get());
  }
  if (FAILED(hr)) {
    Fail(error, MapWriteFailure(hr), "The audio track could not be written.", hr);
    return false;
  }
  encoded_audio_frames_.fetch_add(frames);
  last_audio_100ns_.store(timestamp_100ns);
  return true;
}

bool MediaWriter::Finalize(RecorderError* error) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (finalized_) {
    return true;
  }
  if (!writer_) {
    Fail(error, RecorderErrorCode::kFinalizationFailed,
         "There is no recording to finalize.", E_FAIL);
    return false;
  }
  const HRESULT hr = writer_->Finalize();
  writer_ = nullptr;
  writing_ = false;
  if (FAILED(hr)) {
    Fail(error, MapWriteFailure(hr) == RecorderErrorCode::kDiskFull
                    ? RecorderErrorCode::kDiskFull
                    : RecorderErrorCode::kFinalizationFailed,
         "The recording could not be finalized.", hr);
    return false;
  }
  // Rename last: until this succeeds the only artefact on disk is the `.part`
  // file, which startup recovery knows how to treat (spec 18).
  if (::MoveFileExW(config_.part_path.c_str(), config_.final_path.c_str(),
                    MOVEFILE_REPLACE_EXISTING) == FALSE) {
    const DWORD last_error = ::GetLastError();
    Fail(error, RecorderErrorCode::kFinalizationFailed,
         "The finished recording could not be renamed.",
         HRESULT_FROM_WIN32(last_error));
    return false;
  }
  finalized_ = true;
  return true;
}

void MediaWriter::ResetForRetry() {
  // Drops the half-configured writer while keeping Media Foundation started,
  // so the software attempt begins from a clean sink writer.
  writer_ = nullptr;
  staging_ = nullptr;
  context_ = nullptr;
  device_ = nullptr;
  device_manager_ = nullptr;
  use_dxgi_buffers_ = false;
  has_audio_stream_ = false;
  writing_ = false;
}

bool MediaWriter::is_open() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return writer_ != nullptr;
}

void MediaWriter::Abort() {
  std::lock_guard<std::mutex> lock(mutex_);
  Close();
}

void MediaWriter::Close() {
  writer_ = nullptr;
  staging_ = nullptr;
  context_ = nullptr;
  device_ = nullptr;
  device_manager_ = nullptr;
  writing_ = false;
  if (media_foundation_started_) {
    ::MFShutdown();
    media_foundation_started_ = false;
  }
}

bool MediaWriter::Probe(const std::wstring& path, MediaProbe* probe) {
  if (probe == nullptr) {
    return false;
  }
  *probe = MediaProbe();
  const HRESULT startup = ::MFStartup(MF_VERSION, MFSTARTUP_LITE);
  if (FAILED(startup)) {
    return false;
  }
  bool readable = false;
  {
    winrt::com_ptr<IMFSourceReader> reader;
    if (SUCCEEDED(::MFCreateSourceReaderFromURL(path.c_str(), nullptr, reader.put()))) {
      PROPVARIANT duration;
      ::PropVariantInit(&duration);
      if (SUCCEEDED(reader->GetPresentationAttribute(
              static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION,
              &duration)) &&
          duration.vt == VT_UI8) {
        probe->duration_ms = static_cast<int64_t>(duration.uhVal.QuadPart) / 10000LL;
      }
      ::PropVariantClear(&duration);

      winrt::com_ptr<IMFMediaType> video_type;
      if (SUCCEEDED(reader->GetCurrentMediaType(
              static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM),
              video_type.put()))) {
        UINT32 width = 0;
        UINT32 height = 0;
        if (SUCCEEDED(::MFGetAttributeSize(video_type.get(), MF_MT_FRAME_SIZE, &width,
                                           &height))) {
          probe->width = width;
          probe->height = height;
        }
        UINT32 numerator = 0;
        UINT32 denominator = 0;
        if (SUCCEEDED(::MFGetAttributeRatio(video_type.get(), MF_MT_FRAME_RATE,
                                            &numerator, &denominator)) &&
            denominator != 0) {
          probe->frame_rate = numerator / denominator;
        }
        readable = probe->width > 0 && probe->height > 0;
      }
      winrt::com_ptr<IMFMediaType> audio_type;
      probe->has_audio = SUCCEEDED(reader->GetCurrentMediaType(
          static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), audio_type.put()));
    }
  }
  ::MFShutdown();
  probe->readable = readable && probe->duration_ms > 0;
  return probe->readable;
}

}  // namespace relay
