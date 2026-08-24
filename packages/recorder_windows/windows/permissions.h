#ifndef RELAY_PERMISSIONS_H_
#define RELAY_PERMISSIONS_H_

#include <string>

namespace relay {

// Mirrors PermissionKind / PermissionStatus in recorder_platform_interface. The
// enumerator names cross the channel verbatim (spec 23).
enum class PermissionKind { kScreenRecording, kMicrophone, kCamera };

enum class PermissionStatus {
  kGranted,
  kDenied,
  kNotDetermined,
  kRestricted,
  // The platform has no such consent concept — treated as granted.
  kNotApplicable,
};

const char* PermissionKindName(PermissionKind kind);
const char* PermissionStatusName(PermissionStatus status);
bool PermissionKindFromName(const std::string& name, PermissionKind* kind);

// Windows privacy consent.
//
// There is no screen-recording consent prompt on Windows, so screen capture
// reports notApplicable. Microphone and camera map to the Settings app consent
// state where it can be determined, and to notDetermined where it cannot —
// never to an invented "granted".
class Permissions {
 public:
  static PermissionStatus Check(PermissionKind kind);

  // Windows has no programmatic consent prompt for a desktop app: the request
  // is answered by actually opening the device, which is what triggers the OS
  // consent state in the first place.
  static PermissionStatus Request(PermissionKind kind);

  static void OpenSettings(PermissionKind kind);
};

}  // namespace relay

#endif  // RELAY_PERMISSIONS_H_
