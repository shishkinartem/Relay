#ifndef RELAY_VIDEO_COMPOSITOR_H_
#define RELAY_VIDEO_COMPOSITOR_H_

#include <d3d11.h>
#include <d3d11_1.h>
#include <winrt/base.h>

#include <cstdint>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "recorder_types.h"

namespace relay {

// GPU composition onto the fixed encoder canvas.
//
// Two Direct3D 11 video-processor passes per frame:
//   1. the capture source, letterboxed/pillarboxed into the canvas so the
//      source aspect ratio is never distorted or cropped (spec 4.4, 10);
//   2. the camera picture-in-picture, drawn into the rectangle
//      CameraOverlayConfiguration resolves — geometry always comes from the
//      configuration, never from constants here (spec 7, 28).
//
// The canvas is NV12 so the Media Foundation encoder can take the texture
// directly; nothing round-trips through system memory on the fast path.
class VideoCompositor {
 public:
  VideoCompositor() = default;
  ~VideoCompositor();

  VideoCompositor(const VideoCompositor&) = delete;
  VideoCompositor& operator=(const VideoCompositor&) = delete;

  bool Initialize(ID3D11Device* device, ID3D11DeviceContext* context,
                  uint32_t canvas_width, uint32_t canvas_height,
                  const CameraOverlayConfig& camera, std::string* error);
  void Shutdown();

  // Runtime toggle: the camera stream keeps running, only its contribution to
  // the composed frame stops (spec 6, 7).
  void SetCameraEnabled(bool enabled);
  bool camera_enabled() const;

  // Latest-wins single slot: capacity 1, the previous frame is released when a
  // newer one arrives. The compositor consumes at the screen frame rate, which
  // is independent of the camera rate.
  void SetCameraFrame(winrt::com_ptr<ID3D11Texture2D> frame, uint32_t width,
                      uint32_t height);

  // Composes into a canvas texture from the internal rotating pool. The
  // returned texture stays valid until the pool wraps around to it again.
  bool Compose(ID3D11Texture2D* source, uint32_t source_width, uint32_t source_height,
               winrt::com_ptr<ID3D11Texture2D>* out_canvas, std::string* error);

  uint32_t canvas_width() const { return canvas_width_; }
  uint32_t canvas_height() const { return canvas_height_; }
  RectD pip_rect() const;

 private:
  winrt::com_ptr<ID3D11VideoProcessorInputView> InputViewFor(ID3D11Texture2D* texture);
  bool BlitStream(ID3D11Texture2D* texture, const RECT& source_rect,
                  const RECT& dest_rect, bool restrict_output, bool mirror_horizontal,
                  std::string* error);

  winrt::com_ptr<ID3D11Device> device_;
  winrt::com_ptr<ID3D11DeviceContext> context_;
  winrt::com_ptr<ID3D11VideoDevice> video_device_;
  winrt::com_ptr<ID3D11VideoContext> video_context_;
  winrt::com_ptr<ID3D11VideoContext1> video_context1_;
  winrt::com_ptr<ID3D11VideoProcessorEnumerator> enumerator_;
  winrt::com_ptr<ID3D11VideoProcessor> processor_;

  // Three canvases: one being encoded, one being composed, one spare. Bounded
  // by construction — the compositor never allocates per frame.
  static constexpr size_t kCanvasPoolSize = 3;
  std::vector<winrt::com_ptr<ID3D11Texture2D>> canvases_;
  std::vector<winrt::com_ptr<ID3D11VideoProcessorOutputView>> canvas_views_;
  size_t next_canvas_ = 0;

  // Input views are cached per source texture: the capture frame pool recycles
  // a small fixed set of textures, so this stays tiny. Cleared whenever the
  // source geometry changes and the pool is recreated.
  static constexpr size_t kInputViewCacheSize = 8;
  std::vector<std::pair<ID3D11Texture2D*, winrt::com_ptr<ID3D11VideoProcessorInputView>>>
      input_views_;

  mutable std::mutex mutex_;
  CameraOverlayConfig camera_config_;
  bool camera_enabled_ = false;
  winrt::com_ptr<ID3D11Texture2D> camera_frame_;
  uint32_t camera_width_ = 0;
  uint32_t camera_height_ = 0;
  uint32_t canvas_width_ = 0;
  uint32_t canvas_height_ = 0;
  uint32_t last_source_width_ = 0;
  uint32_t last_source_height_ = 0;
};

}  // namespace relay

#endif  // RELAY_VIDEO_COMPOSITOR_H_
