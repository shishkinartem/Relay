import 'dart:convert';

import 'package:meta/meta.dart';

/// Endpoint and credentials for a WebDAV collection (§17).
///
/// There is no account registration and no OAuth here: a WebDAV server
/// authenticates a request with a user name and a password, and every provider
/// worth using issues *app passwords* so the account password never leaves the
/// account settings page.
@immutable
class WebDavConfig {
  WebDavConfig({
    required Uri? baseUrl,
    required this.username,
    required this.password,
    String? folder,
  }) : baseUrl = baseUrl ?? Uri(),
       folder = _normalizeFolder(folder);

  /// No credentials yet: [isConfigured] is false, so uploads fail pre-flight
  /// instead of reaching the network.
  WebDavConfig.unconfigured() : this(baseUrl: null, username: '', password: '');

  /// Koofr's WebDAV entry point. Named because it is the provider Relay
  /// documents, not because anything here is Koofr-specific.
  static final Uri koofrBaseUrl = Uri.parse('https://app.koofr.net/dav/Koofr');

  /// Where recordings land when the user does not choose a folder.
  static const String defaultFolder = 'Relay';

  final Uri baseUrl;
  final String username;

  /// An app password, not the account password. Never logged, never included
  /// in [toString] (§26, §27).
  final String password;

  /// A single collection name under [baseUrl]. Empty means the base itself.
  final String folder;

  bool get isConfigured =>
      baseUrl.host.isNotEmpty && username.isNotEmpty && password.isNotEmpty;

  /// True when the address is one this destination can actually talk to.
  bool get hasUsableBaseUrl {
    final String scheme = baseUrl.scheme.toLowerCase();
    return (scheme == 'http' || scheme == 'https') && baseUrl.host.isNotEmpty;
  }

  /// The server, as shown in Settings.
  String get endpointLabel => baseUrl.host;

  /// The collection recordings are written into.
  Uri get collectionUrl =>
      folder.isEmpty ? _withTrailingSlash(baseUrl) : _appended(baseUrl, folder);

  /// The address of one recording inside [collectionUrl].
  Uri fileUrl(String name) => _appended(collectionUrl, name);

  /// HTTP Basic. The credentials never travel in a URL, where they would reach
  /// logs, redirects and error messages.
  String get authorizationHeader =>
      'Basic ${base64Encode(utf8.encode('$username:$password'))}';

  /// Never includes the password: this string reaches diagnostics (§26, §27).
  @override
  String toString() =>
      'WebDavConfig($endpointLabel, user: ${username.isEmpty ? '<unset>' : username}, '
      'folder: ${folder.isEmpty ? '<root>' : folder}, configured: $isConfigured)';

  static String _normalizeFolder(String? folder) {
    final String trimmed = (folder ?? defaultFolder).trim();
    final String stripped = trimmed
        .split('/')
        .where((String segment) => segment.isNotEmpty)
        .join('/');
    return stripped;
  }

  static Uri _withTrailingSlash(Uri uri) {
    final List<String> segments = uri.pathSegments
        .where((String segment) => segment.isNotEmpty)
        .toList(growable: false);
    return uri.replace(pathSegments: <String>[...segments, '']);
  }

  static Uri _appended(Uri uri, String path) {
    final List<String> segments = <String>[
      ...uri.pathSegments.where((String segment) => segment.isNotEmpty),
      ...path.split('/').where((String segment) => segment.isNotEmpty),
    ];
    return uri.replace(pathSegments: segments);
  }
}
