#include "video_compositor.h"

#include <algorithm>

namespace relay {

namespace {

RECT ToRect(const RectD& rect) {
  RECT out{};
  out.left = static_cast<LONG>(rect.x + 0.5);
  out.top = static_cast<LONG>(rect.y + 0.5);
  out.right = static_cast<LONG>(rect.x + rect.width + 0.5);
  out.bottom = static_cast<LONG>(rect.y + rect.height + 0.5);
  return out;
}

}  // namespace

VideoCompositor::~VideoCompositor() {
  Shutdown();
}

bool VideoCompositor::Initialize(ID3D11Device* device, ID3D11DeviceContext* context,
                                 uint32_t canvas_width, uint32_t canvas_height,
                                 const CameraOverlayConfig& camera, std::string* error) {
  if (device == nullptr || context == nullptr) {
    *error = "The compositor needs a Direct3D device.";
    return false;
  }
  device_.copy_from(device);
  context_.copy_from(context);
  canvas_width_ = canvas_width;
  canvas_height_ = canvas_height;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    camera_config_ = camera;
  }

  video_device_ = device_.try_as<ID3D11VideoDevice>();
  video_context_ = context_.try_as<ID3D11VideoContext>();
  if (!video_device_ || !video_context_) {
    *error = "This adapter does not expose the Direct3D 11 video processor.";
    return false;
  }
  video_context1_ = video_context_.try_as<ID3D11VideoContext1>();

  D3D11_VIDEO_PROCESSOR_CONTENT_DESC content{};
  content.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
  content.InputWidth = canvas_width_;
  content.InputHeight = canvas_height_;
  content.OutputWidth = canvas_width_;
  content.OutputHeight = canvas_height_;
  content.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
  HRESULT hr = video_device_->CreateVideoProcessorEnumerator(&content, enumerator_.put());
  if (FAILED(hr)) {
    *error = "CreateVideoProcessorEnumerator failed (" + HResultToString(hr) + ").";
    return false;
  }
  hr = video_device_->CreateVideoProcessor(enumerator_.get(), 0, processor_.put());
  if (FAILED(hr)) {
    *error = "CreateVideoProcessor failed (" + HResultToString(hr) + ").";
    return false;
  }

  // Whether the masked tile can be drawn at all on this adapter. Asked once
  // here rather than per frame, and a `false` is a rounded tile with square
  // corners, never a failed recording (see the header).
  //
  // Both halves are required and neither implies the other. MaxInputStreams is
  // how many streams the processor can blend at once, and the masked tile is
  // the second of two; ALPHA_STREAM is whether it honours an input stream's
  // alpha channel at all, which is the mechanism the mask travels by. An
  // adapter with two input streams and no alpha stream would compose the tile
  // opaquely — a circle drawn as a square, silently, which is exactly the
  // fallback this flag exists to take instead.
  D3D11_VIDEO_PROCESSOR_CAPS caps{};
  supports_masked_tile_ =
      SUCCEEDED(enumerator_->GetVideoProcessorCaps(&caps)) &&
      caps.MaxInputStreams >= kMaskedTileStreams &&
      (caps.FeatureCaps & D3D11_VIDEO_PROCESSOR_FEATURE_CAPS_ALPHA_STREAM) != 0;

  D3D11_VIDEO_COLOR background{};
  background.RGBA.R = 0.0f;
  background.RGBA.G = 0.0f;
  background.RGBA.B = 0.0f;
  background.RGBA.A = 1.0f;
  video_context_->VideoProcessorSetOutputBackgroundColor(processor_.get(), FALSE,
                                                         &background);

  D3D11_VIDEO_PROCESSOR_COLOR_SPACE output_space{};
  output_space.Usage = 0;                 // playback
  output_space.RGB_Range = 0;             // full range RGB in
  output_space.YCbCr_Matrix = 1;          // BT.709
  output_space.Nominal_Range = D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_16_235;
  video_context_->VideoProcessorSetOutputColorSpace(processor_.get(), &output_space);
  // Every stream this compositor ever enables, not only the first: the masked
  // tile is drawn as stream 1 and a stream whose frame format was never set is
  // one the driver is free to interpret as interlaced.
  for (UINT stream = 0; stream < kMaskedTileStreams; ++stream) {
    video_context_->VideoProcessorSetStreamFrameFormat(
        processor_.get(), stream, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
  }

  D3D11_TEXTURE2D_DESC desc{};
  desc.Width = canvas_width_;
  desc.Height = canvas_height_;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_NV12;  // encoder-native; no CPU colour conversion
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  for (size_t i = 0; i < kCanvasPoolSize; ++i) {
    winrt::com_ptr<ID3D11Texture2D> texture;
    hr = device_->CreateTexture2D(&desc, nullptr, texture.put());
    if (FAILED(hr)) {
      *error = "The NV12 canvas could not be allocated (" + HResultToString(hr) + ").";
      return false;
    }
    D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC view_desc{};
    view_desc.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
    view_desc.Texture2D.MipSlice = 0;
    winrt::com_ptr<ID3D11VideoProcessorOutputView> view;
    hr = video_device_->CreateVideoProcessorOutputView(texture.get(), enumerator_.get(),
                                                       &view_desc, view.put());
    if (FAILED(hr)) {
      *error = "The canvas output view could not be created (" + HResultToString(hr) + ").";
      return false;
    }
    canvases_.push_back(std::move(texture));
    canvas_views_.push_back(std::move(view));
  }
  return true;
}

void VideoCompositor::Shutdown() {
  std::lock_guard<std::mutex> lock(mutex_);
  camera_frame_ = nullptr;
  input_views_.clear();
  canvas_views_.clear();
  canvases_.clear();
  processor_ = nullptr;
  enumerator_ = nullptr;
  video_context1_ = nullptr;
  video_context_ = nullptr;
  video_device_ = nullptr;
  context_ = nullptr;
  device_ = nullptr;
}

void VideoCompositor::SetCameraEnabled(bool enabled) {
  std::lock_guard<std::mutex> lock(mutex_);
  camera_enabled_ = enabled;
  if (!enabled) {
    camera_frame_ = nullptr;
  }
}

bool VideoCompositor::camera_enabled() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return camera_enabled_;
}

void VideoCompositor::SetCameraOverlay(const CameraOverlayConfig& camera) {
  std::lock_guard<std::mutex> lock(mutex_);
  camera_config_ = camera;
}

CameraOverlayConfig VideoCompositor::camera_overlay() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return camera_config_;
}

void VideoCompositor::SetCameraFrame(winrt::com_ptr<ID3D11Texture2D> frame,
                                     uint32_t width, uint32_t height) {
  std::lock_guard<std::mutex> lock(mutex_);
  camera_frame_ = std::move(frame);
  camera_width_ = width;
  camera_height_ = height;
}

PipDraw VideoCompositor::CameraPipDraw(uint32_t frame_width,
                                       uint32_t frame_height) const {
  std::lock_guard<std::mutex> lock(mutex_);
  return ResolvePipDraw(camera_config_, canvas_width_, canvas_height_,
                        frame_width == 0 ? camera_width_ : frame_width,
                        frame_height == 0 ? camera_height_ : frame_height);
}

CameraFrameMask VideoCompositor::CameraMask(uint32_t frame_width,
                                            uint32_t frame_height) const {
  std::lock_guard<std::mutex> lock(mutex_);
  return ResolveCameraFrameMask(camera_config_, canvas_width_, canvas_height_,
                                frame_width, frame_height);
}

RectD VideoCompositor::pip_rect() const {
  return CameraPipDraw().dest;
}

winrt::com_ptr<ID3D11VideoProcessorInputView> VideoCompositor::InputViewFor(
    ID3D11Texture2D* texture) {
  for (const auto& entry : input_views_) {
    if (entry.first == texture) {
      return entry.second;
    }
  }
  D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC desc{};
  desc.FourCC = 0;
  desc.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
  desc.Texture2D.MipSlice = 0;
  desc.Texture2D.ArraySlice = 0;
  winrt::com_ptr<ID3D11VideoProcessorInputView> view;
  if (FAILED(video_device_->CreateVideoProcessorInputView(texture, enumerator_.get(),
                                                          &desc, view.put()))) {
    return nullptr;
  }
  if (input_views_.size() >= kInputViewCacheSize) {
    input_views_.erase(input_views_.begin());
  }
  input_views_.emplace_back(texture, view);
  return view;
}

bool VideoCompositor::Blit(const Layer* layers, size_t count, const RECT* target,
                           std::string* error) {
  if (layers == nullptr || count == 0 || count > kMaskedTileStreams) {
    *error = "The compositor was asked to draw nothing.";
    return false;
  }

  // Input views first, and all of them, so a surface that cannot be bound fails
  // before any stream state has been touched.
  winrt::com_ptr<ID3D11VideoProcessorInputView> inputs[kMaskedTileStreams];
  for (size_t i = 0; i < count; ++i) {
    inputs[i] = InputViewFor(layers[i].texture);
    if (!inputs[i]) {
      *error = "A capture surface could not be bound to the video processor.";
      return false;
    }
  }

  D3D11_VIDEO_PROCESSOR_STREAM streams[kMaskedTileStreams]{};
  for (size_t i = 0; i < count; ++i) {
    const UINT index = static_cast<UINT>(i);
    video_context_->VideoProcessorSetStreamSourceRect(processor_.get(), index, TRUE,
                                                      &layers[i].source);
    video_context_->VideoProcessorSetStreamDestRect(processor_.get(), index, TRUE,
                                                    &layers[i].dest);
    // Per-pixel alpha is what shapes the tile, and the planar alpha switch is
    // what asks the driver to blend the stream at all; at 1.0 it changes no
    // pixel the frame's own alpha did not already decide. Turned off again for
    // an unmasked layer, because this state is the processor's and outlives the
    // blit that set it.
    video_context_->VideoProcessorSetStreamAlpha(
        processor_.get(), index, layers[i].blend_alpha ? TRUE : FALSE, 1.0f);
    if (video_context1_) {
      // Preview mirroring is the overlay's business; only mirrorOutput reaches
      // the file (spec 7).
      video_context1_->VideoProcessorSetStreamMirror(
          processor_.get(), index, TRUE,
          layers[i].mirror_horizontal ? TRUE : FALSE, FALSE);
    }
    streams[i].Enable = TRUE;
    streams[i].OutputIndex = 0;
    streams[i].InputFrameOrField = 0;
    streams[i].PastFrames = 0;
    streams[i].FutureFrames = 0;
    streams[i].pInputSurface = inputs[i].get();
  }
  if (target != nullptr) {
    video_context_->VideoProcessorSetOutputTargetRect(processor_.get(), TRUE, target);
  } else {
    video_context_->VideoProcessorSetOutputTargetRect(processor_.get(), FALSE, nullptr);
  }

  const HRESULT hr = video_context_->VideoProcessorBlt(
      processor_.get(), canvas_views_[next_canvas_].get(), 0,
      static_cast<UINT>(count), streams);
  if (FAILED(hr)) {
    *error = "VideoProcessorBlt failed (" + HResultToString(hr) + ").";
    return false;
  }
  return true;
}

bool VideoCompositor::Compose(ID3D11Texture2D* source, uint32_t source_width,
                              uint32_t source_height,
                              winrt::com_ptr<ID3D11Texture2D>* out_canvas,
                              std::string* error) {
  if (!processor_ || canvases_.empty()) {
    *error = "The compositor is not initialized.";
    return false;
  }
  if (source == nullptr || source_width == 0 || source_height == 0) {
    *error = "The source frame is empty.";
    return false;
  }

  winrt::com_ptr<ID3D11Texture2D> camera;
  uint32_t camera_width = 0;
  uint32_t camera_height = 0;
  CameraOverlayConfig camera_config;
  bool draw_camera = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (source_width != last_source_width_ || source_height != last_source_height_) {
      // The frame pool was recreated for a resized source: its old textures are
      // gone, so their cached views must go too.
      input_views_.clear();
      last_source_width_ = source_width;
      last_source_height_ = source_height;
    }
    camera_config = camera_config_;
    if (camera_enabled_ && camera_frame_) {
      camera = camera_frame_;
      camera_width = camera_width_;
      camera_height = camera_height_;
      draw_camera = camera_width > 0 && camera_height > 0;
    }
  }

  Layer desktop;
  desktop.texture = source;
  desktop.source.right = static_cast<LONG>(source_width);
  desktop.source.bottom = static_cast<LONG>(source_height);
  desktop.dest = ToRect(
      LetterboxRect(source_width, source_height, canvas_width_, canvas_height_));

  if (!draw_camera) {
    if (!Blit(&desktop, 1, nullptr, error)) {
      return false;
    }
    *out_canvas = canvases_[next_canvas_];
    next_canvas_ = (next_canvas_ + 1) % canvases_.size();
    return true;
  }

  // Which part of the camera frame is read and where it lands, from the one
  // function the preview window is also placed and cropped by (design 1p). The
  // frame is never distorted: `contain` letterboxes it inside the tile and
  // `cover` takes the centre of it, and nothing but an explicit shape preset
  // ever asks for the second (spec 33.5).
  const PipDraw pip = ResolvePipDraw(camera_config, canvas_width_, canvas_height_,
                                     camera_width, camera_height);
  Layer tile;
  tile.texture = camera.get();
  tile.source = ToRect(pip.source);
  tile.dest = ToRect(pip.dest);
  tile.mirror_horizontal = camera_config.mirror_output;
  // A rounded tile carries its shape in the frame's alpha channel, which only
  // the two-stream path composites (see the header). Everything else keeps the
  // two-blit path it has always used, so an ordinary recording is composed
  // exactly as it was before presets existed.
  const bool masked = pip.corner_radius > 0 && supports_masked_tile_;
  if (masked) {
    tile.blend_alpha = true;
    const Layer layers[kMaskedTileStreams] = {desktop, tile};
    if (!Blit(layers, kMaskedTileStreams, nullptr, error)) {
      return false;
    }
  } else {
    if (!Blit(&desktop, 1, nullptr, error)) {
      return false;
    }
    // The target rectangle is the tile's own, so the rest of the canvas the
    // first pass just wrote is not touched.
    if (!Blit(&tile, 1, &tile.dest, error)) {
      return false;
    }
  }

  *out_canvas = canvases_[next_canvas_];
  next_canvas_ = (next_canvas_ + 1) % canvases_.size();
  return true;
}

}  // namespace relay
