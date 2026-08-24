import 'dart:convert';

import 'package:test/test.dart';
import 'package:upload_webdav/upload_webdav.dart';

/// The address arrives as text a person typed, and every provider spells it
/// differently. Joining it to a folder and a file name is where that goes wrong.
void main() {
  WebDavConfig config({String? baseUrl, String? folder}) => WebDavConfig(
    baseUrl: Uri.parse(baseUrl ?? 'https://app.koofr.net/dav/Koofr'),
    username: 'recorder@example.com',
    password: 'app-password',
    folder: folder,
  );

  test('the default folder is used when none is given', () {
    expect(config().folder, WebDavConfig.defaultFolder);
    expect(config(folder: '   ').folder, isEmpty);
  });

  test('a folder is joined without doubling or dropping separators', () {
    for (final String base in <String>[
      'https://app.koofr.net/dav/Koofr',
      'https://app.koofr.net/dav/Koofr/',
    ]) {
      expect(
        config(baseUrl: base).collectionUrl.toString(),
        'https://app.koofr.net/dav/Koofr/Relay',
      );
    }
    expect(
      config(folder: '/Screencasts/2026/').collectionUrl.toString(),
      'https://app.koofr.net/dav/Koofr/Screencasts/2026',
    );
  });

  test('an empty folder writes into the collection itself', () {
    expect(
      config(folder: '').collectionUrl.toString(),
      'https://app.koofr.net/dav/Koofr/',
    );
  });

  test('a file name is escaped rather than pasted into the path', () {
    final Uri url = config().fileUrl('relay 2026-08-23 10-15.mp4');
    expect(url.pathSegments.last, 'relay 2026-08-23 10-15.mp4');
    expect(url.toString(), contains('relay%202026-08-23%2010-15.mp4'));
  });

  test('a Nextcloud address works the same way', () {
    expect(
      config(baseUrl: 'https://cloud.example.org/remote.php/dav/files/ada')
          .fileUrl('clip.mp4')
          .toString(),
      'https://cloud.example.org/remote.php/dav/files/ada/Relay/clip.mp4',
    );
  });

  test('credentials travel in a header, never in the URL', () {
    final WebDavConfig c = config();
    expect(
      c.authorizationHeader,
      'Basic ${base64Encode(utf8.encode('recorder@example.com:app-password'))}',
    );
    expect(c.collectionUrl.userInfo, isEmpty);
    expect(c.collectionUrl.toString(), isNot(contains('app-password')));
  });

  test('an address that is not http(s) is refused, not guessed at', () {
    expect(
      config(baseUrl: 'ftp://example.invalid/dav').hasUsableBaseUrl,
      isFalse,
    );
    expect(config().hasUsableBaseUrl, isTrue);
    expect(WebDavConfig.unconfigured().isConfigured, isFalse);
  });

  test('toString never carries the password', () {
    expect(config().toString(), isNot(contains('app-password')));
    expect(config().toString(), contains('app.koofr.net'));
  });
}
