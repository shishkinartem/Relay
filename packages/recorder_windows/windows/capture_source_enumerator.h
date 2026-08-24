#ifndef RELAY_CAPTURE_SOURCE_ENUMERATOR_H_
#define RELAY_CAPTURE_SOURCE_ENUMERATOR_H_

#include <windows.h>

#include <cstdint>
#include <string>
#include <vector>

#include "recorder_types.h"

namespace relay {

// One row of the in-app source list (spec 4.1). Marshalled into the contract's
// source map by the plugin.
struct CaptureSourceInfo {
  std::string id;
  CaptureSourceType type = CaptureSourceType::kDisplay;
  std::string title;
  std::string subtitle;
  uint32_t pixel_width = 0;
  uint32_t pixel_height = 0;
  bool is_current_display = false;
  std::vector<uint8_t> thumbnail_png;
};

// Geometry of the display holding the main application window (spec 5).
struct DisplayInfo {
  std::string id;
  double logical_width = 0;
  double logical_height = 0;
  uint32_t pixel_width = 0;
  uint32_t pixel_height = 0;
  double scale_factor = 1.0;
};

// Source ids are opaque to Dart. Format: "display:<HMONITOR>" / "window:<HWND>",
// with the handle rendered as an unsigned decimal.
std::string MonitorSourceId(HMONITOR monitor);
std::string WindowSourceId(HWND window);
// Return nullptr when the id no longer names a live monitor/window.
HMONITOR ParseMonitorSourceId(const std::string& id);
HWND ParseWindowSourceId(const std::string& id);

// Enumerates capture targets: displays first, then windows (spec 4.1).
//
// Runs on a worker thread — thumbnail rendering is slow enough to be visible on
// the platform thread.
class CaptureSourceEnumerator {
 public:
  // `main_window` marks the current display and is excluded from the window
  // list along with every other window this process owns.
  std::vector<CaptureSourceInfo> Enumerate(bool refresh_thumbnails, HWND main_window);

  static DisplayInfo CurrentDisplay(HWND main_window);
  static DisplayInfo DescribeMonitor(HMONITOR monitor);
};

}  // namespace relay

#endif  // RELAY_CAPTURE_SOURCE_ENUMERATOR_H_
