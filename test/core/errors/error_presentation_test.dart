import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/core/errors/error_presentation.dart';
import 'package:relay/core/logging/app_logger.dart';
import 'package:upload_core/upload_core.dart';

const String _botToken = '7654321098:AAH9xQ2mZk3LpR7vTfWnJq4bYcXe1dGh8Ks';

void main() {
  group('every recorder error is presentable', () {
    for (final RecorderErrorCode code in RecorderErrorCode.values) {
      test(code.name, () {
        final ErrorPresentation presentation = ErrorPresentation.forRecorder(
          code,
          'native said no',
        );

        expect(presentation.title, isNotEmpty);
        expect(presentation.body, isNotEmpty);
        expect(presentation.title.length, lessThan(48));
        expect(presentation.technical, contains('RecorderError.${code.name}'));
        expect(presentation.technical, contains('native said no'));
      });
    }

    test('every code has distinct copy', () {
      final Set<String> titles = RecorderErrorCode.values
          .map(
            (RecorderErrorCode code) =>
                ErrorPresentation.forRecorder(code, '').body,
          )
          .toSet();

      expect(titles, hasLength(RecorderErrorCode.values.length));
    });
  });

  group('every upload error is presentable', () {
    for (final UploadErrorKind kind in UploadErrorKind.values) {
      test(kind.name, () {
        final ErrorPresentation presentation = ErrorPresentation.forUpload(
          UploadError(kind, 'destination said no'),
        );

        expect(presentation.title, isNotEmpty);
        expect(presentation.body, isNotEmpty);
        expect(presentation.title.length, lessThan(48));
        expect(presentation.technical, contains('UploadError.${kind.name}'));
        expect(presentation.technical, contains('destination said no'));
      });
    }

    test('every kind has distinct copy', () {
      final Set<String> bodies = UploadErrorKind.values
          .map(
            (UploadErrorKind kind) =>
                ErrorPresentation.forUpload(UploadError(kind, '')).body,
          )
          .toSet();

      expect(bodies, hasLength(UploadErrorKind.values.length));
    });
  });

  group('copy consistent with design 1k', () {
    test('a network failure says the recording is retained and resumable', () {
      final ErrorPresentation presentation = ErrorPresentation.forUpload(
        const UploadError.network('session still valid · 12h left'),
      );

      expect(presentation.title, 'Upload interrupted');
      expect(presentation.body, contains('network'));
      expect(presentation.body, contains('still on this computer'));
      expect(presentation.body, contains('resumed'));
      expect(
        presentation.technical,
        'UploadError.network · session still valid · 12h left',
      );
    });

    test(
      'a too-large failure says nothing was started and points elsewhere',
      () {
        final ErrorPresentation presentation = ErrorPresentation.forUpload(
          const UploadError.fileTooLarge(
            'Telegram accepts at most 50 MB via the hosted Bot API',
          ),
        );

        expect(presentation.body, contains('size limit'));
        expect(presentation.body, contains('was not started'));
        expect(presentation.body, contains('kept'));
        expect(presentation.technical, contains('UploadError.fileTooLarge'));
        expect(presentation.technical, contains('50 MB'));
      },
    );

    test('a cancelled upload never claims data loss', () {
      expect(
        ErrorPresentation.forUpload(const UploadError.cancelled()).body,
        contains('kept'),
      );
    });
  });

  group('technical line', () {
    test('appends details and a retry hint', () {
      final ErrorPresentation presentation = ErrorPresentation.forUpload(
        const UploadError(
          UploadErrorKind.rateLimited,
          'too many requests',
          details: 'HTTP 429',
          retryAfter: Duration(seconds: 30),
        ),
      );

      expect(
        presentation.technical,
        'UploadError.rateLimited · too many requests · HTTP 429 · retry in 30s',
      );
    });

    test('omits an empty message', () {
      expect(
        ErrorPresentation.forRecorder(RecorderErrorCode.diskFull, '').technical,
        'RecorderError.diskFull',
      );
    });

    test('never carries a credential out of an upload failure', () {
      final ErrorPresentation presentation = ErrorPresentation.forUpload(
        UploadError(
          UploadErrorKind.authentication,
          'POST https://api.telegram.org/bot$_botToken/sendVideo rejected',
          details: 'Bearer ya29.a0AfB_byC3xKQm7Lp2Rt9Vw4Zn6Hs1Dg8Jf0Uy',
        ),
      );

      expect(
        presentation.technical,
        isNot(contains('AAH9xQ2mZk3LpR7vTfWnJq4bYcXe1dGh8Ks')),
      );
      expect(
        presentation.technical,
        isNot(contains('ya29.a0AfB_byC3xKQm7Lp2Rt9Vw4Zn6Hs1Dg8Jf0Uy')),
      );
      expect(presentation.technical, contains(LogRedactor.placeholder));
      expect(presentation.technical, contains('sendVideo rejected'));
    });

    test('never carries a credential out of a recorder failure', () {
      expect(
        ErrorPresentation.forRecorder(
          RecorderErrorCode.unknown,
          'device auth $_botToken',
        ).technical,
        isNot(contains('AAH9xQ2mZk3LpR7vTfWnJq4bYcXe1dGh8Ks')),
      );
    });
  });

  test('recoverable input failures say recording continues', () {
    for (final RecorderErrorCode code in RecorderErrorCode.values.where(
      (RecorderErrorCode code) => code.isRecoverableDuringSession,
    )) {
      expect(
        ErrorPresentation.forRecorder(code, '').body,
        contains('Recording continues'),
        reason: code.name,
      );
    }
  });
}
