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
  video_context_->VideoProcessorSetStreamFrameFormat(
      processor_.get(), 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);

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

void VideoCompositor::SetCameraFrame(winrt::com_ptr<ID3D11Texture2D> frame,
                                     uint32_t width, uint32_t height) {
  std::lock_guard<std::mutex> lock(mutex_);
  camera_frame_ = std::move(frame);
  camera_width_ = width;
  camera_height_ = height;
}

RectD VideoCompositor::pip_rect() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return ResolvePipRect(camera_config_, canvas_width_, canvas_height_);
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

bool VideoCompositor::BlitStream(ID3D11Texture2D* texture, const RECT& source_rect,
                                 const RECT& dest_rect, bool restrict_output,
                                 bool mirror_horizontal, std::string* error) {
  const winrt::com_ptr<ID3D11VideoProcessorInputView> input = InputViewFor(texture);
  if (!input) {
    *error = "A capture surface could not be bound to the video processor.";
    return false;
  }

  video_context_->VideoProcessorSetStreamSourceRect(processor_.get(), 0, TRUE,
                                                    &source_rect);
  video_context_->VideoProcessorSetStreamDestRect(processor_.get(), 0, TRUE, &dest_rect);
  if (restrict_output) {
    video_context_->VideoProcessorSetOutputTargetRect(processor_.get(), TRUE, &dest_rect);
  } else {
    video_context_->VideoProcessorSetOutputTargetRect(processor_.get(), FALSE, nullptr);
  }
  if (video_context1_) {
    // Preview mirroring is the overlay's business; only mirrorOutput reaches
    // the file (spec 7).
    video_context1_->VideoProcessorSetStreamMirror(processor_.get(), 0, TRUE,
                                                   mirror_horizontal ? TRUE : FALSE,
                                                   FALSE);
  }

  D3D11_VIDEO_PROCESSOR_STREAM stream{};
  stream.Enable = TRUE;
  stream.OutputIndex = 0;
  stream.InputFrameOrField = 0;
  stream.PastFrames = 0;
  stream.FutureFrames = 0;
  stream.pInputSurface = input.get();

  const HRESULT hr = video_context_->VideoProcessorBlt(
      processor_.get(), canvas_views_[next_canvas_].get(), 0, 1, &stream);
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

  RECT source_rect{};
  source_rect.right = static_cast<LONG>(source_width);
  source_rect.bottom = static_cast<LONG>(source_height);
  const RECT dest_rect = ToRect(LetterboxRect(source_width, source_height, canvas_width_,
                                              canvas_height_));
  if (!BlitStream(source, source_rect, dest_rect, false, false, error)) {
    return false;
  }

  if (draw_camera) {
    // The camera fills its picture-in-picture rectangle without distortion: it
    // is letterboxed inside the configured rectangle exactly like the source is
    // inside the canvas.
    //
    // Gap, deliberately not invented: CameraOverlayConfiguration.cornerRadius
    // has no equivalent in the Direct3D 11 video processor, so a non-zero
    // radius is not rounded in the file. The default is 0 and the ADR calls for
    // square corners; rounding would need a shader pass and a decision that
    // does not exist yet.
    const RectD pip = ResolvePipRect(
        camera_config, canvas_width_, canvas_height_,
        camera_height == 0 ? 0
                           : static_cast<double>(camera_width) /
                                 static_cast<double>(camera_height));
    const RectD fitted =
        LetterboxRect(camera_width, camera_height, pip.width, pip.height);
    RectD placed = fitted;
    placed.x += pip.x;
    placed.y += pip.y;
    RECT camera_source{};
    camera_source.right = static_cast<LONG>(camera_width);
    camera_source.bottom = static_cast<LONG>(camera_height);
    if (!BlitStream(camera.get(), camera_source, ToRect(placed), true,
                    camera_config.mirror_output, error)) {
      return false;
    }
    // Restore full-canvas output for the next frame's first pass.
    video_context_->VideoProcessorSetOutputTargetRect(processor_.get(), FALSE, nullptr);
  }

  *out_canvas = canvases_[next_canvas_];
  next_canvas_ = (next_canvas_ + 1) % canvases_.size();
  return true;
}

}  // namespace relay
