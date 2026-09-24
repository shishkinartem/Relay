#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// One Relay per user session.
//
// macOS has never needed this: with no `LSMultipleInstances` in its Info.plist,
// LaunchServices activates the running application instead of forking a second
// one. Windows has no such rule — every double-click is another process, with
// its own capture, its own encoder, its own overlay windows and its own handle
// on the one log, the one settings file and the one recordings folder.
//
// It went unnoticed until the main window started hiding itself for the length
// of a recording, as §6 requires. With the window gone the application looks
// exactly as it would if it had crashed, so the reasonable thing to do is start
// it again — and a second recorder appeared, then a third. Two of the three
// finalizations in that run failed.
//
// `Local\\` rather than `Global\\`: two people signed in at once are two
// desktops, each entitled to its own recorder.
constexpr wchar_t kInstanceMutexName[] = L"Local\\RelayRecorderSingleInstance";
// The window title `Win32Window::Create` is given below.
constexpr wchar_t kMainWindowTitle[] = L"relay";
// Paired with the title to find the first instance. The title alone is not
// enough: FindWindowW matches across the whole desktop, in any process, case
// insensitively, and an Explorer window open on a folder called `relay` has
// exactly that title — a second launch would then restore and foreground
// Explorer and leave the recorder where it was. The class is the runner's own,
// from `kWindowClassName` in win32_window.cpp; other Flutter applications share
// it, which is why the title still has to match too.
constexpr wchar_t kMainWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

// Brings the running Relay forward, so a second launch reads as "here it is"
// rather than as nothing happening at all — which would look just as broken as
// the crash the user thought they were recovering from.
void ActivateRunningInstance() {
  const HWND existing = ::FindWindowW(kMainWindowClass, kMainWindowTitle);
  if (existing == nullptr) {
    return;
  }
  // Restore first: during a recording the first instance has hidden or
  // minimized itself, and ShowWindow is what undoes either.
  if (::IsIconic(existing)) {
    ::ShowWindow(existing, SW_RESTORE);
  } else {
    ::ShowWindow(existing, SW_SHOW);
  }
  ::SetForegroundWindow(existing);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Before COM, before the engine, before anything that costs: a second
  // instance should decide it is one and leave while it is still cheap.
  //
  // The handle is deliberately never closed. It is released when the process
  // ends, whichever way it ends, which is the property that matters: a
  // recorder that crashed must not lock out the launch that replaces it.
  const HANDLE instance_mutex = ::CreateMutexW(nullptr, TRUE, kInstanceMutexName);
  if (instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    ActivateRunningInstance();
    return EXIT_SUCCESS;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  // The panel's preferred size, matching macOS. The Flutter template's default
  // 1280 x 720 stretched a layout drawn for 420 across a whole window, so the
  // same build looked considered on one platform and unfinished on the other
  // (TECHNICAL_SPEC.md §33.6). `WM_GETMINMAXINFO` in win32_window.cpp holds the
  // range this opens inside.
  Win32Window::Size size(420, 560);
  if (!window.Create(kMainWindowTitle, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
