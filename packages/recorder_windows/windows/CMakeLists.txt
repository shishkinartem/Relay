# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "recorder_windows")
project(${PROJECT_NAME} LANGUAGES CXX)

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "recorder_windows_plugin")

# Any new source files that you add to the plugin should be added here.
list(APPEND PLUGIN_SOURCES
  "audio_capture.cpp"
  "audio_capture.h"
  "audio_mixer.cpp"
  "audio_mixer.h"
  "camera_capture.cpp"
  "camera_capture.h"
  "capture_engine.cpp"
  "capture_engine.h"
  "capture_source_enumerator.cpp"
  "capture_source_enumerator.h"
  "input_devices.cpp"
  "input_devices.h"
  "media_writer.cpp"
  "media_writer.h"
  "overlay_windows.cpp"
  "overlay_windows.h"
  "permissions.cpp"
  "permissions.h"
  "recorder_types.cpp"
  "recorder_types.h"
  "recorder_windows_plugin.cpp"
  "recorder_windows_plugin.h"
  "recording_session.cpp"
  "recording_session.h"
  "video_compositor.cpp"
  "video_compositor.h"
)

# Define the plugin library target. Its name must not be changed (see comment
# on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  "include/recorder_windows/recorder_windows_plugin_c_api.h"
  "recorder_windows_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

# Apply a standard set of build settings that are configured in the
# application-level CMakeLists.txt. This can be removed for plugins that want
# full control over build settings.
apply_standard_settings(${PLUGIN_NAME})

# --- two deliberate departures from apply_standard_settings ------------------
#
# 1. `_HAS_EXCEPTIONS=0`.
#
# The Flutter Windows template defines it for every target. It configures the
# MSVC standard library for a build without exceptions: an operation that would
# throw calls `std::terminate` instead. This plugin is built with `/EHsc` and
# genuinely uses exceptions -- C++/WinRT reports failures by throwing
# `winrt::hresult_error`, `winrt::check_hresult` is used throughout the capture
# path, and `winrt::init_apartment` throws when the runner has already put the
# platform thread in another apartment. Compiling that against an STL that has
# been told exceptions do not exist is at best inconsistent and at worst a
# miscompile, so the definition is stripped from this target only. The
# application and the runner keep it.
get_target_property(_relay_defs ${PLUGIN_NAME} COMPILE_DEFINITIONS)
if(_relay_defs)
  list(REMOVE_ITEM _relay_defs "_HAS_EXCEPTIONS=0")
  set_target_properties(${PLUGIN_NAME} PROPERTIES COMPILE_DEFINITIONS "${_relay_defs}")
endif()

# 2. `/WX`.
#
# Warnings stay at /W4 and are still reported; they just do not fail the build
# for this target. This code has never been through a C++ compiler -- there is
# no MSVC on the development host (docs/development/compatibility-matrix.md) --
# and with /WX the first build stops at the first W4 diagnostic and reports
# nothing else. Without it the same build produces the whole list at once,
# which is the difference between one round trip and dozens.
#
# Put it back the moment this plugin has compiled once and the list is empty:
#   target_compile_options(${PLUGIN_NAME} PRIVATE /WX)
get_target_property(_relay_opts ${PLUGIN_NAME} COMPILE_OPTIONS)
if(_relay_opts)
  list(REMOVE_ITEM _relay_opts "/WX")
  set_target_properties(${PLUGIN_NAME} PROPERTIES COMPILE_OPTIONS "${_relay_opts}")
endif()

# C++/WinRT projection headers (winrt/*.h) and designated initializers require
# C++20. apply_standard_settings only guarantees C++17, and compile features
# take the highest requested standard.
target_compile_features(${PLUGIN_NAME} PRIVATE cxx_std_20)

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. This should not be removed; any symbols that should be
# exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE
  FLUTTER_PLUGIN_IMPL
  UNICODE
  _UNICODE
  NOMINMAX
  WIN32_LEAN_AND_MEAN
  # Windows 10 API surface: WDA_EXCLUDEFROMCAPTURE, DWMWA_CLOAKED,
  # PW_RENDERFULLCONTENT and GetDpiForMonitor are all guarded on this.
  WINVER=0x0A00
  _WIN32_WINNT=0x0A00
)

# Source include directories and library dependencies. Add any plugin-specific
# dependencies here.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}")

target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  # Method/event channels and the plugin registrar.
  flutter_wrapper_plugin
  # FlutterViewController / DartProject: the overlay windows host secondary
  # Flutter engines at the controlStripMain and cameraPreviewMain entrypoints.
  flutter_wrapper_app
)

target_link_libraries(${PLUGIN_NAME} PRIVATE
  windowsapp     # C++/WinRT: Windows.Graphics.Capture, Windows.System.Launcher
  mfplat         # Media Foundation platform
  mfreadwrite    # IMFSinkWriter / IMFSourceReader
  mfuuid         # Media Foundation GUIDs
  mf             # Media Foundation core
  ole32          # COM
  oleaut32       # PROPVARIANT
  dxgi           # IDXGIDevice
  d3d11          # Direct3D 11 device, video processor
  dwmapi         # DWMWA_CLOAKED window filtering
  propsys        # Property system used by the device enumerators
  avrt           # Pro Audio thread characteristics for the WASAPI threads
  ksuser         # KSDATAFORMAT_SUBTYPE_* audio format GUIDs
  uuid           # Interface/class GUIDs
  shcore         # GetDpiForMonitor
  windowscodecs  # WIC PNG encoding of source thumbnails
)

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(recorder_windows_bundled_libraries
  ""
  PARENT_SCOPE
)
