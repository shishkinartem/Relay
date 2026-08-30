# Unit tests for the plugin's Flutter-free code.
#
# A standalone project on purpose, and the Windows counterpart of
# `packages/recorder_macos/macos/recorder_macos/core`. The plugin's own
# CMakeLists.txt calls `apply_standard_settings()`, which only exists inside a
# Flutter application build, so it cannot be configured on its own — and a test
# target added there would drag GoogleTest into every app build.
#
# `recorder_types.cpp` is self-contained: it includes its own header,
# <algorithm>, <cmath> and <sstream>, and nothing else in the plugin. That is
# what makes the pure half — the wire contract, the picture-in-picture geometry,
# the canvas arithmetic, the session clock, the input-device ordering and the
# level arithmetic — testable without Media Foundation, WGC or Flutter.
#
# Run on a Windows host:
#
#   cmake -S packages/recorder_windows/windows/test -B build/win-tests
#   cmake --build build/win-tests --config Debug
#   ctest --test-dir build/win-tests -C Debug --output-on-failure
cmake_minimum_required(VERSION 3.14)
project(recorder_windows_tests LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)
FetchContent_Declare(
  googletest
  GIT_REPOSITORY https://github.com/google/googletest.git
  GIT_TAG        v1.15.2
)
# Match the plugin's runtime library so the test binary links against the same
# CRT the plugin is built with.
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(googletest)

enable_testing()

add_executable(recorder_types_test
  "${CMAKE_CURRENT_SOURCE_DIR}/recorder_types_test.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../recorder_types.cpp"
)

target_include_directories(recorder_types_test PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/.."
)

# The same Windows API level the plugin is compiled against, so the header
# under test sees the same declarations it will in production.
target_compile_definitions(recorder_types_test PRIVATE
  UNICODE
  _UNICODE
  NOMINMAX
  WIN32_LEAN_AND_MEAN
  WINVER=0x0A00
  _WIN32_WINNT=0x0A00
)

target_link_libraries(recorder_types_test PRIVATE GTest::gtest_main)

include(GoogleTest)
gtest_discover_tests(recorder_types_test)
