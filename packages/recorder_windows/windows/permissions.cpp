#include "permissions.h"

#include <windows.h>
// Windows SDK headers below depend on windows.h having been included first.

#include <audioclient.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mmdeviceapi.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.System.h>
#include <winrt/base.h>

#include "recorder_types.h"

namespace relay {

namespace {

constexpr wchar_t kConsentRoot[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore";

const wchar_t* CapabilityFor(PermissionKind kind) {
  return kind == PermissionKind::kCamera ? L"webcam" : L"microphone";
}

const wchar_t* SettingsUriFor(PermissionKind kind) {
  return kind == PermissionKind::kCamera ? L"ms-settings:privacy-webcam"
                                         : L"ms-settings:privacy-microphone";
}

bool ReadConsentValue(HKEY root, const std::wstring& subkey, std::wstring* value) {
  HKEY key = nullptr;
  if (::RegOpenKeyExW(root, subkey.c_str(), 0, KEY_QUERY_VALUE, &key) != ERROR_SUCCESS) {
    return false;
  }
  wchar_t buffer[64]{};
  DWORD size = sizeof(buffer);
  DWORD type = 0;
  const LSTATUS status =
      ::RegQueryValueExW(key, L"Value", nullptr, &type, reinterpret_cast<LPBYTE>(buffer),
                         &size);
  ::RegCloseKey(key);
  if (status != ERROR_SUCCESS || type != REG_SZ) {
    return false;
  }
  *value = buffer;
  return true;
}

// Unpackaged desktop apps get a per-executable consent entry whose name is the
// image path with backslashes replaced by '#'.
std::wstring NonPackagedKeyName() {
  wchar_t path[MAX_PATH]{};
  const DWORD length = ::GetModuleFileNameW(nullptr, path, MAX_PATH);
  if (length == 0) {
    return std::wstring();
  }
  std::wstring name(path, length);
  for (wchar_t& character : name) {
    if (character == L'\\') {
      character = L'#';
    }
  }
  return name;
}

PermissionStatus StatusFromConsent(const std::wstring& value) {
  if (value == L"Allow") {
    return PermissionStatus::kGranted;
  }
  if (value == L"Deny") {
    return PermissionStatus::kDenied;
  }
  return PermissionStatus::kNotDetermined;
}

PermissionStatus ProbeMicrophone() {
  const HRESULT com = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  PermissionStatus status = PermissionStatus::kNotDetermined;
  {
    winrt::com_ptr<IMMDeviceEnumerator> enumerator;
    winrt::com_ptr<IMMDevice> device;
    winrt::com_ptr<IAudioClient> client;
    if (SUCCEEDED(::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                     CLSCTX_INPROC_SERVER, __uuidof(IMMDeviceEnumerator),
                                     enumerator.put_void())) &&
        SUCCEEDED(enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, device.put()))) {
      const HRESULT hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                          client.put_void());
      if (hr == E_ACCESSDENIED) {
        status = PermissionStatus::kDenied;
      } else if (SUCCEEDED(hr)) {
        status = PermissionStatus::kGranted;
      }
    }
  }
  if (SUCCEEDED(com)) {
    ::CoUninitialize();
  }
  return status;
}

PermissionStatus ProbeCamera() {
  const HRESULT com = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  PermissionStatus status = PermissionStatus::kNotDetermined;
  if (SUCCEEDED(::MFStartup(MF_VERSION, MFSTARTUP_LITE))) {
    winrt::com_ptr<IMFAttributes> attributes;
    if (SUCCEEDED(::MFCreateAttributes(attributes.put(), 1))) {
      attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                          MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
      IMFActivate** devices = nullptr;
      UINT32 count = 0;
      if (SUCCEEDED(::MFEnumDeviceSources(attributes.get(), &devices, &count)) &&
          count > 0) {
        winrt::com_ptr<IMFMediaSource> source;
        const HRESULT hr =
            devices[0]->ActivateObject(__uuidof(IMFMediaSource), source.put_void());
        if (hr == E_ACCESSDENIED) {
          status = PermissionStatus::kDenied;
        } else if (SUCCEEDED(hr)) {
          status = PermissionStatus::kGranted;
          source->Shutdown();
        }
      }
      if (devices != nullptr) {
        for (UINT32 i = 0; i < count; ++i) {
          devices[i]->Release();
        }
        ::CoTaskMemFree(devices);
      }
    }
    ::MFShutdown();
  }
  if (SUCCEEDED(com)) {
    ::CoUninitialize();
  }
  return status;
}

}  // namespace

const char* PermissionKindName(PermissionKind kind) {
  switch (kind) {
    case PermissionKind::kMicrophone:
      return "microphone";
    case PermissionKind::kCamera:
      return "camera";
    case PermissionKind::kScreenRecording:
      break;
  }
  return "screenRecording";
}

const char* PermissionStatusName(PermissionStatus status) {
  switch (status) {
    case PermissionStatus::kGranted:
      return "granted";
    case PermissionStatus::kDenied:
      return "denied";
    case PermissionStatus::kRestricted:
      return "restricted";
    case PermissionStatus::kNotApplicable:
      return "notApplicable";
    case PermissionStatus::kNotDetermined:
      break;
  }
  return "notDetermined";
}

bool PermissionKindFromName(const std::string& name, PermissionKind* kind) {
  if (name == "screenRecording") {
    *kind = PermissionKind::kScreenRecording;
    return true;
  }
  if (name == "microphone") {
    *kind = PermissionKind::kMicrophone;
    return true;
  }
  if (name == "camera") {
    *kind = PermissionKind::kCamera;
    return true;
  }
  return false;
}

PermissionStatus Permissions::Check(PermissionKind kind) {
  if (kind == PermissionKind::kScreenRecording) {
    // Windows.Graphics.Capture needs no user consent for a desktop app.
    return PermissionStatus::kNotApplicable;
  }

  const std::wstring capability = CapabilityFor(kind);
  const std::wstring base = std::wstring(kConsentRoot) + L"\\" + capability;
  std::wstring value;

  // A machine-wide denial cannot be undone by the user from inside the app.
  if (ReadConsentValue(HKEY_LOCAL_MACHINE, base, &value) && value == L"Deny") {
    return PermissionStatus::kRestricted;
  }

  const std::wstring executable = NonPackagedKeyName();
  if (!executable.empty() &&
      ReadConsentValue(HKEY_CURRENT_USER, base + L"\\NonPackaged\\" + executable,
                       &value)) {
    return StatusFromConsent(value);
  }
  if (ReadConsentValue(HKEY_CURRENT_USER, base, &value)) {
    return StatusFromConsent(value);
  }
  return PermissionStatus::kNotDetermined;
}

PermissionStatus Permissions::Request(PermissionKind kind) {
  if (kind == PermissionKind::kScreenRecording) {
    return PermissionStatus::kNotApplicable;
  }
  const PermissionStatus recorded = Check(kind);
  if (recorded == PermissionStatus::kRestricted) {
    return recorded;
  }
  const PermissionStatus probed =
      kind == PermissionKind::kCamera ? ProbeCamera() : ProbeMicrophone();
  return probed == PermissionStatus::kNotDetermined ? recorded : probed;
}

void Permissions::OpenSettings(PermissionKind kind) {
  if (kind == PermissionKind::kScreenRecording) {
    return;
  }
  try {
    const winrt::Windows::Foundation::Uri uri{SettingsUriFor(kind)};
    // Fire and forget: the platform thread must not block on the shell.
    auto operation = winrt::Windows::System::Launcher::LaunchUriAsync(uri);
    operation.Completed([](const auto&, const auto&) {});
  } catch (const winrt::hresult_error&) {
  }
}

}  // namespace relay
