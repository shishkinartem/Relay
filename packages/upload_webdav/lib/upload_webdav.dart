/// WebDAV upload destination.
///
/// WebDAV is a protocol rather than a service, so one implementation reaches
/// Koofr, any Nextcloud or ownCloud, Box and the rest — and none of them needs
/// a developer registration, only an app password from the user's own account
/// settings (§17, `docs/architecture/uploads.md`).
library;

export 'src/webdav_config.dart';
export 'src/webdav_upload_destination.dart';
