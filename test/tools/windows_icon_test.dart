import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// The shipped Windows application icon, guarded as a committed asset.
///
/// Nothing generates `windows/runner/resources/app_icon.ico` at build time:
/// `windows/runner/Runner.rc` binds the committed file to `IDI_APP_ICON`,
/// `windows/runner/resource.h` gives that the lowest resource id so the shell
/// keys the .exe icon to it, and `win32_window.cpp` loads it for the window
/// class. So the artwork in the tree is the artwork users see, and the Flutter
/// template's stock logo shipped that way until a real Windows run caught it.
///
/// `tool/make-windows-icon.py` rebuilds the file from the macOS master. This
/// test is what notices when it has not been re-run — which is why it carries
/// no tag: unlike `render_screens_test.dart` next to it, it is an assertion
/// suite and belongs in the ordinary `flutter test` run.
void main() {
  final File icon = File(
    '${_repositoryRoot().path}/windows/runner/resources/app_icon.ico',
  );

  /// The stock Flutter runner icon, as committed by `flutter create`.
  const String templateDigest = '6ea04d80ca2a3fa92c7717c3c44ccc19';

  /// 16/20/24 are the title bar and Explorer at 100/125/150% DPI, 32/40/48 the
  /// taskbar and alt-tab at those same scales, and 64/128/256 Explorer's larger
  /// views and the high-DPI shell. Windows scales the nearest larger entry when
  /// one of these is missing, which is what makes an icon look soft at exactly
  /// one zoom level.
  const List<int> expectedSizes = <int>[16, 20, 24, 32, 40, 48, 64, 128, 256];

  const List<int> pngMagic = <int>[
    0x89,
    0x50,
    0x4e,
    0x47,
    0x0d,
    0x0a,
    0x1a,
    0x0a,
  ];

  test('the digest helper agrees with MD5 on the published vectors', () {
    // A guard on the guard: this file computes its own MD5 rather than take a
    // dependency for one digest, and a broken implementation would make the
    // template check below pass by never matching anything.
    expect(_md5(<int>[]), 'd41d8cd98f00b204e9800998ecf8427e');
    expect(_md5(utf8.encode('abc')), '900150983cd24fb0d6963f7d28e17f72');
    expect(
      _md5(utf8.encode('The quick brown fox jumps over the lazy dog')),
      '9e107d9d372bb6826bd81d3542a419d6',
    );
  });

  test('the committed icon is not the Flutter template', () {
    expect(
      _md5(icon.readAsBytesSync()),
      isNot(templateDigest),
      reason:
          'this is the stock Flutter logo. Rebuild the icon from the macOS '
          'master: python3 tool/make-windows-icon.py',
    );
  });

  group('the icon file', () {
    late Uint8List bytes;
    late List<_IconEntry> entries;

    setUp(() {
      bytes = icon.readAsBytesSync();
      entries = _entries(bytes);
    });

    test('declares an icon directory', () {
      final ByteData view = ByteData.sublistView(bytes);
      expect(view.getUint16(0, Endian.little), 0, reason: 'idReserved');
      expect(view.getUint16(2, Endian.little), 1, reason: 'idType: 1 = icon');
      expect(entries, hasLength(expectedSizes.length));
    });

    test('carries every size Windows asks for', () {
      expect(<int>[for (final _IconEntry e in entries) e.width], expectedSizes);
      expect(<int>[
        for (final _IconEntry e in entries) e.height,
      ], expectedSizes);
    });

    test('stores every image as a single plane of 32-bpp pixels', () {
      // Anything less than 32 bpp loses the alpha the rounded mark needs, and
      // wPlanes is 1 for every format Windows has read since Win32.
      for (final _IconEntry entry in entries) {
        expect(entry.planes, 1, reason: '${entry.width}px wPlanes');
        expect(entry.bitCount, 32, reason: '${entry.width}px wBitCount');
      }
    });

    test('compresses the 256px image as PNG', () {
      // Vista and later read a PNG entry, and as a raw DIB this one image alone
      // would be 256*256*4 bytes — more than the rest of the file together.
      final _IconEntry largest = entries.last;
      expect(largest.width, 256);
      expect(
        bytes.sublist(largest.offset, largest.offset + pngMagic.length),
        pngMagic,
      );
    });

    test('stores every other image as a DIB', () {
      // A 40-byte BITMAPINFOHEADER, so a PNG entry that lost its magic or a
      // truncated write does not read as a valid bitmap.
      for (final _IconEntry entry in entries.where(
        (_IconEntry e) => e.width < 256,
      )) {
        final ByteData view = ByteData.sublistView(bytes, entry.offset);
        expect(
          view.getUint32(0, Endian.little),
          40,
          reason: '${entry.width}px biSize',
        );
      }
    });

    test('points every entry at bytes that are actually there', () {
      // An offset past the end is the shape a hand-assembled ICO fails in, and
      // the shell simply draws nothing rather than reporting it.
      for (final _IconEntry entry in entries) {
        expect(entry.offset, greaterThanOrEqualTo(6 + 16 * entries.length));
        expect(
          entry.offset + entry.size,
          lessThanOrEqualTo(bytes.length),
          reason: '${entry.width}px runs past the end of the file',
        );
      }
    });
  });
}

/// One ICONDIRENTRY: where an image lives and what shape it is.
class _IconEntry {
  const _IconEntry({
    required this.width,
    required this.height,
    required this.planes,
    required this.bitCount,
    required this.size,
    required this.offset,
  });

  final int width;
  final int height;
  final int planes;
  final int bitCount;
  final int size;
  final int offset;
}

/// Parses the 6-byte ICONDIR and the 16-byte ICONDIRENTRY that follows each.
List<_IconEntry> _entries(Uint8List bytes) {
  final ByteData view = ByteData.sublistView(bytes);
  final int count = view.getUint16(4, Endian.little);
  final List<_IconEntry> entries = <_IconEntry>[];
  for (int i = 0; i < count; i++) {
    final int at = 6 + 16 * i;
    final int width = view.getUint8(at);
    final int height = view.getUint8(at + 1);
    entries.add(
      _IconEntry(
        // bWidth and bHeight are single bytes, so 256 is written as 0.
        width: width == 0 ? 256 : width,
        height: height == 0 ? 256 : height,
        planes: view.getUint16(at + 4, Endian.little),
        bitCount: view.getUint16(at + 6, Endian.little),
        size: view.getUint32(at + 8, Endian.little),
        offset: view.getUint32(at + 12, Endian.little),
      ),
    );
  }
  return entries;
}

/// MD5 of [data] as lower-case hex.
///
/// `package:crypto` is not a declared dependency of this package, and one
/// digest in one asset guard does not justify making it one, so the 64 rounds
/// are spelled out here. The first test above checks this against the vectors
/// RFC 1321 publishes.
String _md5(List<int> data) {
  const List<int> shifts = <int>[
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, //
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, //
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, //
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, //
  ];
  // RFC 1321's K table is defined as this expression, so deriving it is both
  // shorter and harder to typo than 64 literal constants.
  final List<int> sines = <int>[
    for (int i = 1; i <= 64; i++) (math.sin(i).abs() * 4294967296).floor(),
  ];

  final List<int> message = <int>[...data, 0x80];
  while (message.length % 64 != 56) {
    message.add(0);
  }
  final int bits = data.length * 8;
  for (int i = 0; i < 8; i++) {
    message.add((bits >> (8 * i)) & 0xff);
  }

  int a0 = 0x67452301;
  int b0 = 0xefcdab89;
  int c0 = 0x98badcfe;
  int d0 = 0x10325476;
  for (int chunk = 0; chunk < message.length; chunk += 64) {
    final List<int> words = <int>[
      for (int i = 0; i < 16; i++)
        message[chunk + 4 * i] |
            message[chunk + 4 * i + 1] << 8 |
            message[chunk + 4 * i + 2] << 16 |
            message[chunk + 4 * i + 3] << 24,
    ];
    int a = a0;
    int b = b0;
    int c = c0;
    int d = d0;
    for (int i = 0; i < 64; i++) {
      int mixed;
      int word;
      if (i < 16) {
        mixed = (b & c) | (~b & d);
        word = i;
      } else if (i < 32) {
        mixed = (d & b) | (~d & c);
        word = (5 * i + 1) % 16;
      } else if (i < 48) {
        mixed = b ^ c ^ d;
        word = (3 * i + 5) % 16;
      } else {
        mixed = c ^ (b | (~d & 0xffffffff));
        word = (7 * i) % 16;
      }
      mixed = (mixed + a + sines[i] + words[word]) & 0xffffffff;
      a = d;
      d = c;
      c = b;
      b = (b + _rotateLeft(mixed, shifts[i])) & 0xffffffff;
    }
    a0 = (a0 + a) & 0xffffffff;
    b0 = (b0 + b) & 0xffffffff;
    c0 = (c0 + c) & 0xffffffff;
    d0 = (d0 + d) & 0xffffffff;
  }

  final StringBuffer digest = StringBuffer();
  for (final int word in <int>[a0, b0, c0, d0]) {
    // The digest is the four words little-endian, not in register order.
    for (int i = 0; i < 4; i++) {
      digest.write(
        ((word >> (8 * i)) & 0xff).toRadixString(16).padLeft(2, '0'),
      );
    }
  }
  return digest.toString();
}

int _rotateLeft(int value, int by) =>
    ((value << by) | (value >>> (32 - by))) & 0xffffffff;

/// The repository root, however deep the runner's working directory is.
Directory _repositoryRoot() {
  Directory directory = Directory.current;
  for (int i = 0; i < 6; i++) {
    if (File('${directory.path}/pubspec.yaml').existsSync() &&
        Directory('${directory.path}/lib').existsSync()) {
      return directory;
    }
    directory = directory.parent;
  }
  throw StateError(
    'The repository root could not be found from ${Directory.current}',
  );
}
