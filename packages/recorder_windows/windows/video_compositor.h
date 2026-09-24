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
//
// **How the circle is masked.** The `circle` preset needs the desktop to show
// through the corners of a square tile, and none of the three obvious routes
// works here: the video processor has no per-pixel mask input, so a mask
// *texture* has nowhere to go; a pixel shader would have to write the NV12
// canvas's Y and UV planes itself, or introduce an RGBA intermediate and a
// third conversion blit, for one masked rectangle; and a second single-stream
// blit cannot blend, because VideoProcessorBlt composites its streams over the
// *background colour* and overwrites everything inside the target rectangle.
//
// What the video processor does composite with is the alpha channel of an input
// stream. So the mask is baked into the camera frame's alpha where that frame is
// already being copied row by row on its way to the GPU (camera_capture.cpp),
// and the masked tile is drawn as the second stream of a single two-stream blt
// with the capture source as the first — which is the composition the video
// processor exists to do. The arithmetic is ResolvePipDraw's, the same call the
// preview window is placed and cropped by, so the preview and the file cannot
// disagree about the shape (design 1p).
//
// The unmasked presets keep the two-blt path they have always used, so the
// default recording is composed exactly as before. An adapter that cannot do
// this — fewer than two input streams, or a video processor that does not
// honour an input stream's alpha at all — draws a rounded tile with square
// corners rather than not at all; nothing else degrades. Both capabilities are
// required, and neither implies the other, so Initialize asks for both.
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

  // Whether the compositor still holds its device, its processor and its
  // canvas pool, for the census (spec 19.1). Shutdown drops all three.
  bool is_initialized() const;

  // Re-points the tile mid-session (spec 33.5).
  //
  // Applied between frames, for the next frame: Compose takes its own copy of
  // the configuration once, at the top. The canvas is untouched, so the file
  // keeps one continuous video track (spec 11).
  void SetCameraOverlay(const CameraOverlayConfig& camera);
  CameraOverlayConfig camera_overlay() const;

  // What the tile looks like for a camera frame of this size, or for whatever
  // the last frame was when both are 0. The preview window's frame, crop and
  // mask are all resolved from this, which is what keeps it the same object as
  // the composited tile (design 1p).
  PipDraw CameraPipDraw(uint32_t frame_width = 0, uint32_t frame_height = 0) const;

  // The mask a camera frame of this size carries in its alpha channel. Asked by
  // the camera capture, which is the one place those pixels are already being
  // touched.
  CameraFrameMask CameraMask(uint32_t frame_width, uint32_t frame_height) const;

  // Latest-wins single slot: capacity 1, the previous frame is released when a
  // newer one arrives. The compositor consumes at the screen frame rate — and,
  // over a source that has gone quiet, at the rate the session holds its last
  // frame (Recompose) — neither of which is the camera rate.
  void SetCameraFrame(winrt::com_ptr<ID3D11Texture2D> frame, uint32_t width,
                      uint32_t height);

  // Composes into a canvas texture from the internal rotating pool. The
  // returned texture stays valid until the pool wraps around to it again.
  //
  // A camera surface this adapter refuses to bind is dropped from the frame,
  // not made into a failure: capture, camera and encode are separate failure
  // domains (spec 23, CLAUDE.md), and the alternative — which is what shipped —
  // is a recording whose video track stops the moment the camera starts.
  // `camera_dropped` says whether that happened, so the caller can report it
  // once instead of per frame.
  //
  // Also keeps a copy of `source`, which is what Recompose draws from.
  //
  // Compose and Recompose must never run at the same time: both drive the one
  // video processor and hand out canvases from the one pool. RecordingSession
  // serializes them under its composition lock, which also covers the queue
  // accounting that keeps the pool from wrapping onto a canvas in use.
  bool Compose(ID3D11Texture2D* source, uint32_t source_width, uint32_t source_height,
               winrt::com_ptr<ID3D11Texture2D>* out_canvas, std::string* error,
               bool* camera_dropped = nullptr);

  enum class RecomposeResult {
    // Nothing to draw: no source has been composed yet, or nothing the tile is
    // drawn from has changed since the last composition, so the canvas that
    // composition produced is still exactly right.
    kUnchanged,
    kComposed,
    kFailed,
  };

  // Draws the last source frame Compose saw again, under the camera as it is
  // now, into the next canvas of the pool.
  //
  // For a window, Windows.Graphics.Capture delivers a frame only when the
  // window's content changes, and while it does not the session holds the last
  // picture on the timeline (RecordingSession::RepeatLastComposedFrame). A held
  // canvas holds its camera tile too, so a window nobody was touching froze the
  // camera in the file — live in the preview, a still in the recording, and
  // jerky whenever the window changed only now and then. This is what lets the
  // tile move while the desktop stands still.
  //
  // "Changed" is a new camera frame, the camera toggled, or the tile moved or
  // reshaped (SetCameraFrame, SetCameraEnabled, SetCameraOverlay): turning the
  // camera off over a static window must take the tile out of the file too.
  RecomposeResult Recompose(winrt::com_ptr<ID3D11Texture2D>* out_canvas,
                            std::string* error, bool* camera_dropped = nullptr);

  uint32_t canvas_width() const { return canvas_width_; }
  uint32_t canvas_height() const { return canvas_height_; }
  RectD pip_rect() const;

 private:
  // One input stream of a blit: what to read, where to put it, and whether the
  // video processor should honour the alpha the texture carries.
  struct Layer {
    ID3D11Texture2D* texture = nullptr;
    RECT source{};
    RECT dest{};
    bool mirror_horizontal = false;
    bool blend_alpha = false;
    // False for a layer the frame is still worth drawing without. The desktop
    // is required; the camera tile is not.
    bool required = true;
  };

  winrt::com_ptr<ID3D11VideoProcessorInputView> InputViewFor(ID3D11Texture2D* texture);
  // The body Compose and Recompose share: the desktop letterboxed into the
  // canvas and the tile over it, from one snapshot of the camera state.
  bool Draw(ID3D11Texture2D* source, uint32_t source_width, uint32_t source_height,
            winrt::com_ptr<ID3D11Texture2D>* out_canvas, std::string* error,
            bool* camera_dropped);
  // Copies `source` into held_source_, reallocating it when the capture pool's
  // textures have changed shape. A copy rather than a reference: the capture
  // pool's texture goes back to Windows.Graphics.Capture the moment the frame
  // callback returns, and is drawn over by the next frame.
  void HoldSource(ID3D11Texture2D* source, uint32_t source_width,
                  uint32_t source_height);
  // Composites `layers` in order onto the canvas being written. `target`
  // restricts the area that is written at all, or is null for the whole canvas:
  // pixels outside it are not modified, and pixels inside it that no layer
  // covers are filled with the background colour.
  // `dropped` counts optional layers that could not be bound and were left out.
  bool Blit(const Layer* layers, size_t count, const RECT* target,
            std::string* error, size_t* dropped = nullptr);

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

  // Two input streams in one blit is what composites the masked tile over the
  // desktop, and the stream's own alpha is what shapes it. Both are read from
  // the adapter once, at initialization.
  static constexpr UINT kMaskedTileStreams = 2;
  bool supports_masked_tile_ = false;

  // The last source frame Compose drew, and the part of it that is content
  // (the capture pool's textures can be larger than the frame they carry).
  // Touched only by Compose and Recompose, which never overlap, and by
  // Shutdown once both have stopped.
  winrt::com_ptr<ID3D11Texture2D> held_source_;
  uint32_t held_width_ = 0;
  uint32_t held_height_ = 0;
  // The `generation_` the last composition drew its tile from. Same owners.
  uint64_t composed_generation_ = 0;

  mutable std::mutex mutex_;
  CameraOverlayConfig camera_config_;
  bool camera_enabled_ = false;
  winrt::com_ptr<ID3D11Texture2D> camera_frame_;
  uint32_t camera_width_ = 0;
  uint32_t camera_height_ = 0;
  // Advances with everything a composed tile is drawn from — a camera frame,
  // the toggle, the geometry — so Recompose can tell a held canvas that is
  // still right from one that is not.
  uint64_t generation_ = 1;
  uint32_t canvas_width_ = 0;
  uint32_t canvas_height_ = 0;
  uint32_t last_source_width_ = 0;
  uint32_t last_source_height_ = 0;
};

}  // namespace relay

#endif  // RELAY_VIDEO_COMPOSITOR_H_
