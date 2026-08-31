#ifndef RELAY_MEDIA_WRITER_H_
#define RELAY_MEDIA_WRITER_H_

#include <windows.h>

#include <d3d11.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <winrt/base.h>

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

#include "recorder_types.h"

namespace relay {

// What a probe could read back from an MP4 or an orphaned `.part` artefact.
struct MediaProbe {
  bool readable = false;
  int64_t duration_ms = 0;
  uint32_t width = 0;
  uint32_t height = 0;
  uint32_t frame_rate = 0;
  bool has_audio = false;
};

// Media Foundation sink writer: H.264 video plus AAC audio into MP4.
//
// Writes incrementally to `recording-<id>.part` and renames to
// `recording-<id>.mp4` only after Finalize() succeeds, so a crash leaves a
// recoverable artefact rather than a half-written `.mp4` (spec 18).
//
// Every method is called from the encoder thread only, except Abort(), which is
// guarded.
class MediaWriter {
 public:
  struct Config {
    std::wstring part_path;
    std::wstring final_path;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t frame_rate = 30;
    bool has_audio = true;
  };

  MediaWriter() = default;
  ~MediaWriter();

  MediaWriter(const MediaWriter&) = delete;
  MediaWriter& operator=(const MediaWriter&) = delete;

  // `device` enables the zero-copy path: NV12 textures go straight to the
  // hardware encoder. Passing nullptr forces the system-memory path.
  bool Open(const Config& config, ID3D11Device* device, RecorderError* error);

  bool WriteVideoFrame(ID3D11Texture2D* nv12, int64_t timestamp_100ns,
                       int64_t duration_100ns, RecorderError* error);
  bool WriteAudioFrames(const float* interleaved_stereo, size_t frames,
                        int64_t timestamp_100ns, RecorderError* error);

  // Finalizes and renames. Idempotent: a second call reports the same success.
  bool Finalize(RecorderError* error);

  // Releases the writer without finalizing. The `.part` file is left on disk
  // for startup recovery; nothing is deleted here (spec 18).
  void Abort();

  // Whether a sink writer, its inputs and its buffers still exist, for the
  // census (spec 19.1). Both Finalize and Abort drop it.
  bool is_open() const;

  bool hardware_encoding() const { return hardware_encoding_; }
  const std::string& encoder_name() const { return encoder_name_; }
  uint64_t encoded_video_frames() const { return encoded_video_frames_.load(); }
  uint64_t encoded_audio_frames() const { return encoded_audio_frames_.load(); }
  int64_t last_video_timestamp_100ns() const { return last_video_100ns_.load(); }
  int64_t last_audio_timestamp_100ns() const { return last_audio_100ns_.load(); }

  static bool Probe(const std::wstring& path, MediaProbe* probe);
  static uint32_t RecommendedBitrate(uint32_t width, uint32_t height,
                                     uint32_t frame_rate);

 private:
  bool OpenInternal(bool allow_hardware, ID3D11Device* device, RecorderError* error);
  bool EnsureStagingTexture(ID3D11Texture2D* source, RecorderError* error);
  bool CopyTextureToBuffer(ID3D11Texture2D* nv12, winrt::com_ptr<IMFMediaBuffer>* buffer,
                           RecorderError* error);
  void ResetForRetry();
  void Close();

  Config config_;
  mutable std::mutex mutex_;
  bool media_foundation_started_ = false;
  bool writing_ = false;
  bool finalized_ = false;
  bool hardware_encoding_ = false;
  bool use_dxgi_buffers_ = false;
  std::string encoder_name_;

  winrt::com_ptr<IMFSinkWriter> writer_;
  winrt::com_ptr<IMFDXGIDeviceManager> device_manager_;
  winrt::com_ptr<ID3D11Device> device_;
  winrt::com_ptr<ID3D11DeviceContext> context_;
  winrt::com_ptr<ID3D11Texture2D> staging_;

  DWORD video_stream_ = 0;
  DWORD audio_stream_ = 0;
  bool has_audio_stream_ = false;

  std::vector<int16_t> pcm_scratch_;
  std::atomic<uint64_t> encoded_video_frames_{0};
  std::atomic<uint64_t> encoded_audio_frames_{0};
  std::atomic<int64_t> last_video_100ns_{0};
  std::atomic<int64_t> last_audio_100ns_{0};
};

}  // namespace relay

#endif  // RELAY_MEDIA_WRITER_H_
