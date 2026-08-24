#include "include/recorder_windows/recorder_windows_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "recorder_windows_plugin.h"

void RecorderWindowsPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  relay::RecorderWindowsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
