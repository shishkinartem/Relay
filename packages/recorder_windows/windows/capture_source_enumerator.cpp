#include "capture_source_enumerator.h"

#include <dwmapi.h>
#include <objbase.h>
#include <ocidl.h>
#include <shellscalingapi.h>
#include <wincodec.h>
#include <winrt/base.h>

#include <algorithm>
#include <cstdlib>
#include <sstream>

namespace relay {

namespace {

constexpr uint32_t kThumbnailMaxWidth = 320;

// RAII for the GDI handles below: one owner each, released on every path.
class ScopedDc {
 public:
  ScopedDc(HDC dc, HWND owner) : dc_(dc), owner_(owner), release_(true) {}
  explicit ScopedDc(HDC dc) : dc_(dc), owner_(nullptr), release_(false) {}
  ~ScopedDc() {
    if (dc_ == nullptr) {
      return;
    }
    if (release_) {
      ::ReleaseDC(owner_, dc_);
    } else {
      ::DeleteDC(dc_);
    }
  }
  ScopedDc(const ScopedDc&) = delete;
  ScopedDc& operator=(const ScopedDc&) = delete;
  HDC get() const { return dc_; }
  explicit operator bool() const { return dc_ != nullptr; }

 private:
  HDC dc_;
  HWND owner_;
  bool release_;
};

class ScopedBitmap {
 public:
  explicit ScopedBitmap(HBITMAP bitmap) : bitmap_(bitmap) {}
  ~ScopedBitmap() {
    if (bitmap_ != nullptr) {
      ::DeleteObject(bitmap_);
    }
  }
  ScopedBitmap(const ScopedBitmap&) = delete;
  ScopedBitmap& operator=(const ScopedBitmap&) = delete;
  HBITMAP get() const { return bitmap_; }
  explicit operator bool() const { return bitmap_ != nullptr; }

 private:
  HBITMAP bitmap_;
};

struct MonitorList {
  std::vector<HMONITOR> monitors;
};

BOOL CALLBACK CollectMonitor(HMONITOR monitor, HDC /*dc*/, LPRECT /*rect*/,
                             LPARAM lparam) {
  reinterpret_cast<MonitorList*>(lparam)->monitors.push_back(monitor);
  return TRUE;
}

std::vector<HMONITOR> Monitors() {
  MonitorList list;
  ::EnumDisplayMonitors(nullptr, nullptr, CollectMonitor,
                        reinterpret_cast<LPARAM>(&list));
  return list.monitors;
}

std::string DecimalHandle(void* handle) {
  std::ostringstream stream;
  stream << reinterpret_cast<uintptr_t>(handle);
  return stream.str();
}

bool ParseHandleValue(const std::string& id, const char* prefix, uintptr_t* out) {
  const size_t prefix_length = std::char_traits<char>::length(prefix);
  if (id.size() <= prefix_length || id.compare(0, prefix_length, prefix) != 0) {
    return false;
  }
  const std::string digits = id.substr(prefix_length);
  if (digits.empty() ||
      digits.find_first_not_of("0123456789") != std::string::npos) {
    return false;
  }
  *out = static_cast<uintptr_t>(std::strtoull(digits.c_str(), nullptr, 10));
  return true;
}

std::wstring MonitorFriendlyName(const MONITORINFOEXW& info) {
  DISPLAY_DEVICEW device{};
  device.cb = sizeof(device);
  if (::EnumDisplayDevicesW(info.szDevice, 0, &device, 0) != FALSE &&
      device.DeviceString[0] != L'\0') {
    return device.DeviceString;
  }
  return info.szDevice;
}

std::string ProcessNameOf(HWND window) {
  DWORD process_id = 0;
  ::GetWindowThreadProcessId(window, &process_id);
  if (process_id == 0) {
    return std::string();
  }
  const HANDLE process =
      ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id);
  if (process == nullptr) {
    return std::string();
  }
  wchar_t path[MAX_PATH]{};
  DWORD length = MAX_PATH;
  const BOOL ok = ::QueryFullProcessImageNameW(process, 0, path, &length);
  ::CloseHandle(process);
  if (ok == FALSE || length == 0) {
    return std::string();
  }
  std::wstring image(path, length);
  const size_t slash = image.find_last_of(L"\\/");
  if (slash != std::wstring::npos) {
    image = image.substr(slash + 1);
  }
  const size_t dot = image.find_last_of(L'.');
  if (dot != std::wstring::npos) {
    image = image.substr(0, dot);
  }
  return Narrow(image);
}

bool IsCloaked(HWND window) {
  DWORD cloaked = 0;
  if (SUCCEEDED(::DwmGetWindowAttribute(window, DWMWA_CLOAKED, &cloaked,
                                        sizeof(cloaked)))) {
    return cloaked != 0;
  }
  return false;
}

// The alt-tab rule: a visible, titled, non-cloaked, non-tool top-level window
// that is either unowned or explicitly app-like. Minimized windows are dropped
// because Windows.Graphics.Capture cannot capture them.
bool IsCapturableWindow(HWND window, DWORD own_process_id) {
  if (::IsWindowVisible(window) == FALSE || ::IsIconic(window) != FALSE) {
    return false;
  }
  if (::GetAncestor(window, GA_ROOT) != window) {
    return false;
  }
  DWORD process_id = 0;
  ::GetWindowThreadProcessId(window, &process_id);
  if (process_id == own_process_id) {
    return false;
  }
  const LONG_PTR ex_style = ::GetWindowLongPtrW(window, GWL_EXSTYLE);
  if ((ex_style & WS_EX_TOOLWINDOW) != 0) {
    return false;
  }
  if (::GetWindow(window, GW_OWNER) != nullptr && (ex_style & WS_EX_APPWINDOW) == 0) {
    return false;
  }
  if (::GetWindowTextLengthW(window) == 0) {
    return false;
  }
  if (IsCloaked(window)) {
    return false;
  }
  RECT rect{};
  if (::GetWindowRect(window, &rect) == FALSE) {
    return false;
  }
  return (rect.right - rect.left) > 1 && (rect.bottom - rect.top) > 1;
}

std::string WindowTitleOf(HWND window) {
  const int length = ::GetWindowTextLengthW(window);
  if (length <= 0) {
    return std::string();
  }
  std::wstring title(static_cast<size_t>(length) + 1, L'\0');
  const int copied = ::GetWindowTextW(window, title.data(), length + 1);
  title.resize(copied < 0 ? 0 : static_cast<size_t>(copied));
  return Narrow(title);
}

std::string Dimensions(uint32_t width, uint32_t height) {
  std::ostringstream stream;
  // U+00D7 MULTIPLICATION SIGN, UTF-8.
  stream << width << " \xC3\x97 " << height;
  return stream.str();
}

// Encodes a top-down BGRA buffer as PNG in memory.
std::vector<uint8_t> EncodePng(const uint8_t* pixels, uint32_t width, uint32_t height,
                               uint32_t stride) {
  std::vector<uint8_t> output;
  winrt::com_ptr<IWICImagingFactory> factory;
  HRESULT hr = ::CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                                  __uuidof(IWICImagingFactory), factory.put_void());
  if (FAILED(hr)) {
    return output;
  }
  winrt::com_ptr<IStream> stream;
  hr = ::CreateStreamOnHGlobal(nullptr, TRUE, stream.put());
  if (FAILED(hr)) {
    return output;
  }
  winrt::com_ptr<IWICBitmapEncoder> encoder;
  hr = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, encoder.put());
  if (FAILED(hr) || FAILED(encoder->Initialize(stream.get(), WICBitmapEncoderNoCache))) {
    return output;
  }
  winrt::com_ptr<IWICBitmapFrameEncode> frame;
  winrt::com_ptr<IPropertyBag2> properties;
  if (FAILED(encoder->CreateNewFrame(frame.put(), properties.put())) ||
      FAILED(frame->Initialize(properties.get())) ||
      FAILED(frame->SetSize(width, height))) {
    return output;
  }
  WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
  if (FAILED(frame->SetPixelFormat(&format))) {
    return output;
  }
  const UINT buffer_size = stride * height;
  if (FAILED(frame->WritePixels(height, stride, buffer_size,
                                const_cast<BYTE*>(pixels))) ||
      FAILED(frame->Commit()) || FAILED(encoder->Commit())) {
    return output;
  }

  HGLOBAL memory = nullptr;
  if (FAILED(::GetHGlobalFromStream(stream.get(), &memory)) || memory == nullptr) {
    return output;
  }
  const SIZE_T size = ::GlobalSize(memory);
  const void* data = ::GlobalLock(memory);
  if (data != nullptr) {
    output.assign(static_cast<const uint8_t*>(data),
                  static_cast<const uint8_t*>(data) + size);
    ::GlobalUnlock(memory);
  }
  return output;
}

// Renders `source` (already positioned at 0,0 of a memory DC) into a
// thumbnail-sized DIB and encodes it.
//
// Windows.Graphics.Capture would need a full D3D session per source to produce
// a single still, so the enumerator uses the documented GDI fallback:
// PrintWindow for windows, BitBlt for displays. Windows that refuse
// PW_RENDERFULLCONTENT simply come back without a thumbnail, which the source
// map allows.
std::vector<uint8_t> ScaleAndEncode(HDC source_dc, uint32_t source_width,
                                    uint32_t source_height) {
  if (source_width == 0 || source_height == 0) {
    return std::vector<uint8_t>();
  }
  const double scale =
      (std::min)(1.0, static_cast<double>(kThumbnailMaxWidth) / source_width);
  const uint32_t width = (std::max)(1u, static_cast<uint32_t>(source_width * scale));
  const uint32_t height = (std::max)(1u, static_cast<uint32_t>(source_height * scale));

  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = static_cast<LONG>(width);
  info.bmiHeader.biHeight = -static_cast<LONG>(height);  // top-down
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  ScopedDc target(::CreateCompatibleDC(source_dc));
  if (!target) {
    return std::vector<uint8_t>();
  }
  ScopedBitmap bitmap(
      ::CreateDIBSection(target.get(), &info, DIB_RGB_COLORS, &bits, nullptr, 0));
  if (!bitmap || bits == nullptr) {
    return std::vector<uint8_t>();
  }
  const HGDIOBJ previous = ::SelectObject(target.get(), bitmap.get());
  ::SetStretchBltMode(target.get(), HALFTONE);
  ::SetBrushOrgEx(target.get(), 0, 0, nullptr);
  const BOOL ok = ::StretchBlt(target.get(), 0, 0, static_cast<int>(width),
                               static_cast<int>(height), source_dc, 0, 0,
                               static_cast<int>(source_width),
                               static_cast<int>(source_height), SRCCOPY);
  ::GdiFlush();
  std::vector<uint8_t> png;
  if (ok != FALSE) {
    png = EncodePng(static_cast<const uint8_t*>(bits), width, height, width * 4);
  }
  ::SelectObject(target.get(), previous);
  return png;
}

std::vector<uint8_t> ThumbnailForWindow(HWND window) {
  RECT rect{};
  if (::GetWindowRect(window, &rect) == FALSE) {
    return std::vector<uint8_t>();
  }
  const uint32_t width = static_cast<uint32_t>(rect.right - rect.left);
  const uint32_t height = static_cast<uint32_t>(rect.bottom - rect.top);
  if (width == 0 || height == 0) {
    return std::vector<uint8_t>();
  }
  ScopedDc window_dc(::GetWindowDC(window), window);
  if (!window_dc) {
    return std::vector<uint8_t>();
  }
  ScopedDc memory_dc(::CreateCompatibleDC(window_dc.get()));
  if (!memory_dc) {
    return std::vector<uint8_t>();
  }
  ScopedBitmap bitmap(::CreateCompatibleBitmap(window_dc.get(), static_cast<int>(width),
                                               static_cast<int>(height)));
  if (!bitmap) {
    return std::vector<uint8_t>();
  }
  const HGDIOBJ previous = ::SelectObject(memory_dc.get(), bitmap.get());
  std::vector<uint8_t> png;
  if (::PrintWindow(window, memory_dc.get(), PW_RENDERFULLCONTENT) != FALSE) {
    png = ScaleAndEncode(memory_dc.get(), width, height);
  }
  ::SelectObject(memory_dc.get(), previous);
  return png;
}

std::vector<uint8_t> ThumbnailForMonitor(const MONITORINFOEXW& info) {
  const uint32_t width = static_cast<uint32_t>(info.rcMonitor.right - info.rcMonitor.left);
  const uint32_t height =
      static_cast<uint32_t>(info.rcMonitor.bottom - info.rcMonitor.top);
  if (width == 0 || height == 0) {
    return std::vector<uint8_t>();
  }
  ScopedDc screen_dc(::CreateDCW(L"DISPLAY", info.szDevice, nullptr, nullptr));
  if (!screen_dc) {
    return std::vector<uint8_t>();
  }
  ScopedDc memory_dc(::CreateCompatibleDC(screen_dc.get()));
  if (!memory_dc) {
    return std::vector<uint8_t>();
  }
  ScopedBitmap bitmap(::CreateCompatibleBitmap(screen_dc.get(), static_cast<int>(width),
                                               static_cast<int>(height)));
  if (!bitmap) {
    return std::vector<uint8_t>();
  }
  const HGDIOBJ previous = ::SelectObject(memory_dc.get(), bitmap.get());
  std::vector<uint8_t> png;
  if (::BitBlt(memory_dc.get(), 0, 0, static_cast<int>(width), static_cast<int>(height),
               screen_dc.get(), 0, 0, SRCCOPY) != FALSE) {
    png = ScaleAndEncode(memory_dc.get(), width, height);
  }
  ::SelectObject(memory_dc.get(), previous);
  return png;
}

struct WindowScan {
  DWORD own_process_id = 0;
  std::vector<HWND> windows;
};

BOOL CALLBACK CollectWindow(HWND window, LPARAM lparam) {
  auto* scan = reinterpret_cast<WindowScan*>(lparam);
  if (IsCapturableWindow(window, scan->own_process_id)) {
    scan->windows.push_back(window);
  }
  return TRUE;
}

}  // namespace

std::string MonitorSourceId(HMONITOR monitor) {
  return "display:" + DecimalHandle(monitor);
}

std::string WindowSourceId(HWND window) {
  return "window:" + DecimalHandle(window);
}

HMONITOR ParseMonitorSourceId(const std::string& id) {
  uintptr_t value = 0;
  if (!ParseHandleValue(id, "display:", &value)) {
    return nullptr;
  }
  const HMONITOR monitor = reinterpret_cast<HMONITOR>(value);
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  // A stale handle must not reach CreateForMonitor.
  return ::GetMonitorInfoW(monitor, &info) != FALSE ? monitor : nullptr;
}

HWND ParseWindowSourceId(const std::string& id) {
  uintptr_t value = 0;
  if (!ParseHandleValue(id, "window:", &value)) {
    return nullptr;
  }
  const HWND window = reinterpret_cast<HWND>(value);
  return ::IsWindow(window) != FALSE ? window : nullptr;
}

DisplayInfo CaptureSourceEnumerator::DescribeMonitor(HMONITOR monitor) {
  DisplayInfo display;
  MONITORINFOEXW info{};
  info.cbSize = sizeof(info);
  if (monitor == nullptr || ::GetMonitorInfoW(monitor, &info) == FALSE) {
    return display;
  }
  display.id = DecimalHandle(monitor);
  display.pixel_width = static_cast<uint32_t>(info.rcMonitor.right - info.rcMonitor.left);
  display.pixel_height =
      static_cast<uint32_t>(info.rcMonitor.bottom - info.rcMonitor.top);

  UINT dpi_x = USER_DEFAULT_SCREEN_DPI;
  UINT dpi_y = USER_DEFAULT_SCREEN_DPI;
  if (FAILED(::GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y)) ||
      dpi_x == 0) {
    dpi_x = USER_DEFAULT_SCREEN_DPI;
  }
  display.scale_factor = static_cast<double>(dpi_x) / USER_DEFAULT_SCREEN_DPI;
  if (display.scale_factor <= 0) {
    display.scale_factor = 1.0;
  }
  display.logical_width = display.pixel_width / display.scale_factor;
  display.logical_height = display.pixel_height / display.scale_factor;
  return display;
}

DisplayInfo CaptureSourceEnumerator::CurrentDisplay(HWND main_window) {
  const HMONITOR monitor = main_window != nullptr
                               ? ::MonitorFromWindow(main_window, MONITOR_DEFAULTTONEAREST)
                               : ::MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
  return DescribeMonitor(monitor);
}

std::vector<CaptureSourceInfo> CaptureSourceEnumerator::Enumerate(bool refresh_thumbnails,
                                                                  HWND main_window) {
  std::vector<CaptureSourceInfo> sources;
  const HMONITOR current = main_window != nullptr
                               ? ::MonitorFromWindow(main_window, MONITOR_DEFAULTTONEAREST)
                               : nullptr;

  // Displays first, then windows: the order is part of the contract (spec 4.1).
  for (const HMONITOR monitor : Monitors()) {
    MONITORINFOEXW info{};
    info.cbSize = sizeof(info);
    if (::GetMonitorInfoW(monitor, &info) == FALSE) {
      continue;
    }
    CaptureSourceInfo source;
    source.id = MonitorSourceId(monitor);
    source.type = CaptureSourceType::kDisplay;
    source.title = Narrow(MonitorFriendlyName(info));
    source.pixel_width = static_cast<uint32_t>(info.rcMonitor.right - info.rcMonitor.left);
    source.pixel_height =
        static_cast<uint32_t>(info.rcMonitor.bottom - info.rcMonitor.top);
    source.subtitle = Dimensions(source.pixel_width, source.pixel_height);
    source.is_current_display = monitor == current;
    if ((info.dwFlags & MONITORINFOF_PRIMARY) != 0) {
      source.subtitle += " \xC2\xB7 Primary";
    }
    if (refresh_thumbnails) {
      source.thumbnail_png = ThumbnailForMonitor(info);
    }
    sources.push_back(std::move(source));
  }

  WindowScan scan;
  scan.own_process_id = ::GetCurrentProcessId();
  ::EnumWindows(CollectWindow, reinterpret_cast<LPARAM>(&scan));
  for (const HWND window : scan.windows) {
    RECT rect{};
    if (::GetWindowRect(window, &rect) == FALSE) {
      continue;
    }
    CaptureSourceInfo source;
    source.id = WindowSourceId(window);
    source.type = CaptureSourceType::kWindow;
    const std::string process = ProcessNameOf(window);
    const std::string title = WindowTitleOf(window);
    source.title = process.empty() ? title : process;
    source.subtitle = process.empty() ? std::string() : title;
    source.pixel_width = static_cast<uint32_t>(rect.right - rect.left);
    source.pixel_height = static_cast<uint32_t>(rect.bottom - rect.top);
    if (refresh_thumbnails) {
      source.thumbnail_png = ThumbnailForWindow(window);
    }
    sources.push_back(std::move(source));
  }
  return sources;
}

}  // namespace relay
