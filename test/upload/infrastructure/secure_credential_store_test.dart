import 'package:flutter/services.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/upload/infrastructure/secure_credential_store.dart';

/// A keychain that behaves the way macOS actually behaves for a build without
/// the `keychain-access-groups` entitlement.
///
/// The distinction this fake exists to model, and which the previous one got
/// wrong: a **write** to the data-protection keychain fails with -34018, and a
/// **read** does not fail at all — it finds nothing, because the process has no
/// access group, and `errSecItemNotFound` is reported as "no value". Verified
/// against `SecItemCopyMatching` on macOS 26.
///
/// The old fake threw on reads too. That is what let a store which could never
/// find its credentials at startup pass its own test suite.
class _FakeKeychain extends FlutterSecureStoragePlatform {
  /// Keyed by keychain, because the two are separate stores and the whole
  /// question is which one a value ends up in.
  final Map<bool, Map<String, String>> stores = <bool, Map<String, String>>{
    true: <String, String>{},
    false: <String, String>{},
  };

  final List<String> operations = <String>[];

  /// What an Apple Development signed build gets.
  bool refuseDataProtectionWrites = true;

  bool _isDataProtection(Map<String, String> options) =>
      options['useDataProtectionKeyChain'] != 'false';

  Map<String, String> _store(Map<String, String> options) =>
      stores[_isDataProtection(options)]!;

  void _refuseWriteIfNeeded(Map<String, String> options) {
    if (refuseDataProtectionWrites && _isDataProtection(options)) {
      throw PlatformException(
        code: 'Unexpected security result code',
        message:
            'Code: ${SecureCredentialStore.missingEntitlement}, Message: A '
            "required entitlement isn't present.",
        details: SecureCredentialStore.missingEntitlement,
      );
    }
  }

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    operations.add('write($key, dataProtection=${_isDataProtection(options)})');
    _refuseWriteIfNeeded(options);
    _store(options)[key] = value;
  }

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    operations.add('read($key, dataProtection=${_isDataProtection(options)})');
    // Never throws: an unreachable keychain simply has nothing in it.
    return _store(options)[key];
  }

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    operations.add(
      'delete($key, dataProtection=${_isDataProtection(options)})',
    );
    _store(options).remove(key);
  }

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async => _store(options).containsKey(key);

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async => _store(options);

  @override
  Future<void> deleteAll({required Map<String, String> options}) async =>
      _store(options).clear();

  Map<String, String> get login => stores[false]!;
  Map<String, String> get dataProtection => stores[true]!;
}

/// Storing a credential must not depend on how the build was signed (§27), and
/// finding it again must not depend on what the process happened to do first.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeKeychain keychain;
  late FlutterSecureStoragePlatform previous;

  setUp(() {
    previous = FlutterSecureStoragePlatform.instance;
    keychain = _FakeKeychain();
    FlutterSecureStoragePlatform.instance = keychain;
  });

  tearDown(() => FlutterSecureStoragePlatform.instance = previous);

  test('a refused entitlement falls back to the login keychain', () async {
    final SecureCredentialStore store = SecureCredentialStore();

    await store.write('relay.test.key', 'secret-value');

    expect(keychain.login['relay.test.key'], 'secret-value');
    expect(keychain.dataProtection, isEmpty);
  });

  test('the probe leaves nothing behind', () async {
    final SecureCredentialStore store = SecureCredentialStore();

    await store.write('a', '1');

    expect(
      keychain.login.containsKey(SecureCredentialStore.probeKey),
      isFalse,
      reason: 'the sentinel is removed as soon as it has answered',
    );
    expect(
      keychain.dataProtection.containsKey(SecureCredentialStore.probeKey),
      isFalse,
    );
  });

  test('a credential written by one launch is found by the next', () async {
    // The regression, stated exactly: the process that stores the credential
    // and the process that reads it back are different runs of the
    // application, and the second one starts by reading.
    final SecureCredentialStore first = SecureCredentialStore();
    await first.write('relay.webdav.password', 'app-password');

    final SecureCredentialStore second = SecureCredentialStore();
    expect(
      await second.read('relay.webdav.password'),
      'app-password',
      reason:
          'a relaunch must not present a connected destination as unconfigured',
    );
  });

  test(
    'reading first does not strand the process on the wrong keychain',
    () async {
      // Every launch does this: `restore()` reads before anything is written.
      // A read cannot reveal which keychain is usable, so the decision must
      // already have been made before the read happens.
      keychain.login['relay.webdav.password'] = 'app-password';
      final SecureCredentialStore store = SecureCredentialStore();

      expect(await store.read('relay.webdav.password'), 'app-password');

      // And the process is now writing where it read from.
      await store.write('relay.webdav.username', 'someone@example.com');
      expect(keychain.login['relay.webdav.username'], 'someone@example.com');
    },
  );

  test('the answer is decided once, not per call', () async {
    final SecureCredentialStore store = SecureCredentialStore();

    await store.write('a', '1');
    keychain.operations.clear();
    await store.write('b', '2');
    await store.read('a');
    await store.delete('b');

    expect(
      keychain.operations.where(
        (String op) => op.startsWith('write') && op.contains('true'),
      ),
      isEmpty,
      reason: 'the probe must not be repeated on every call',
    );
  });

  test('a build that may use the modern keychain keeps it', () async {
    keychain.refuseDataProtectionWrites = false;
    final SecureCredentialStore store = SecureCredentialStore();

    await store.write('a', '1');

    expect(keychain.dataProtection['a'], '1');
    expect(
      keychain.login,
      isEmpty,
      reason: 'a signed build must not be downgraded to the login keychain',
    );
    expect(await store.read('a'), '1');
  });

  test('a credential is carried over when the keychain changes', () async {
    // A build that gains the entitlement resolves the other way. The
    // credential was not lost, and must not look lost.
    keychain.login['relay.webdav.password'] = 'app-password';
    keychain.refuseDataProtectionWrites = false;

    final SecureCredentialStore store = SecureCredentialStore();
    expect(await store.read('relay.webdav.password'), 'app-password');
  });

  test('disconnecting forgets the credential in both keychains', () async {
    // Otherwise the cross-read above would resurrect a destination the user
    // has explicitly disconnected.
    keychain.login['relay.webdav.password'] = 'old';
    keychain.dataProtection['relay.webdav.password'] = 'older';

    final SecureCredentialStore store = SecureCredentialStore();
    await store.delete('relay.webdav.password');

    expect(await store.read('relay.webdav.password'), isNull);
    expect(keychain.login, isEmpty);
    expect(keychain.dataProtection, isEmpty);
  });

  test('an unrelated keychain failure is not swallowed', () async {
    FlutterSecureStoragePlatform.instance = _AlwaysFailingKeychain();
    final SecureCredentialStore store = SecureCredentialStore();

    await expectLater(
      store.write('a', '1'),
      throwsA(
        isA<PlatformException>().having(
          (PlatformException e) => e.code,
          'code',
          'Unexpected security result code',
        ),
      ),
    );
  });
}

/// Fails for a reason that has nothing to do with entitlements.
class _AlwaysFailingKeychain extends _FakeKeychain {
  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async => throw PlatformException(
    code: 'Unexpected security result code',
    message: 'Code: -25308, Message: Interaction is not allowed.',
    details: -25308,
  );
}
