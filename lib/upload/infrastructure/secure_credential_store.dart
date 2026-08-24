import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:upload_core/upload_core.dart';

import '../../core/logging/app_logger.dart';

/// Which of the two macOS keychains an operation is aimed at.
enum _Keychain { dataProtection, login }

/// OS-backed secret storage: macOS Keychain, Windows Credential Manager (§27).
///
/// Credentials never reach `.env`, plain preferences, source or logs.
///
/// macOS has two keychains. The **data-protection** keychain is the modern one
/// and the right choice for a signed, provisioned build — but reaching it
/// requires the `keychain-access-groups` entitlement, which this project does
/// not carry, and every *write* fails with `errSecMissingEntitlement`
/// (-34018). The **file-based** login keychain has no such requirement; it is
/// still the macOS Keychain, still encrypted at rest, still access-controlled
/// per application.
///
/// So this decides which keychain the process may use, once, and uses it for
/// everything afterwards. A properly signed build keeps the better keychain; a
/// development build stores its credentials instead of refusing to.
///
/// ## Why the decision is a probe rather than a caught failure
///
/// It used to be inferred from an operation that failed. That works for a
/// write and not at all for a read: a read against the data-protection
/// keychain from a process with no access group does **not** fail, it comes
/// back empty — `errSecItemNotFound`, which the plugin reports as "no value",
/// not as an error. Verified on this host.
///
/// Every launch begins by reading. So the fallback only ever engaged after the
/// user had already connected a destination *in that same process*: the read
/// at startup quietly found nothing, the application reported the destination
/// as not configured, and the credentials sat untouched in the login keychain
/// where the previous session had put them. It read as "it forgets my WebDAV
/// every time I rebuild", because a rebuild is when you relaunch.
///
/// A write is the only operation that can tell the two keychains apart, so the
/// decision is made by writing and removing one sentinel value before anything
/// else happens.
class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore({FlutterSecureStorage? storage, this.logger})
    : _injected = storage;

  /// What macOS returns when the process may not use the data-protection
  /// keychain. The plugin surfaces it as the details of a [PlatformException],
  /// and repeats it in the message.
  static const int missingEntitlement = -34018;

  /// Written and immediately removed to find out which keychain is usable.
  /// Never holds a credential, and its absence afterwards is the point.
  static const String probeKey = 'relay.keychain.probe';

  static const AndroidOptions _android = AndroidOptions(
    encryptedSharedPreferences: true,
  );

  static const MacOsOptions _dataProtectionKeychain = MacOsOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
    synchronizable: false,
  );

  static const MacOsOptions _loginKeychain = MacOsOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
    synchronizable: false,
    useDataProtectionKeyChain: false,
  );

  final FlutterSecureStorage? _injected;
  final Logger? logger;

  /// Memoized so concurrent callers share one probe and it runs exactly once.
  Future<_Keychain>? _resolved;

  @override
  Future<String?> read(String key) async {
    final _Keychain primary = await _keychain();
    final String? value = await _storage(primary).read(key: key);
    if (value != null) {
      return value;
    }
    // A credential stored by an earlier build that resolved the other way is
    // still the user's credential. Reading the other keychain when the first
    // has nothing costs one lookup and makes a build that gains — or loses —
    // the entitlement carry its connections across instead of silently
    // presenting itself as never configured.
    final String? carried = await _readQuietly(_other(primary), key);
    if (carried != null) {
      logger?.info(
        'keychain_carried_over',
        fields: <String, Object?>{'key': key, 'from': _other(primary).name},
      );
    }
    return carried;
  }

  @override
  Future<void> write(String key, String value) async =>
      _storage(await _keychain()).write(key: key, value: value);

  /// Removes the key from **both** keychains.
  ///
  /// [read] falls back to the other one, so deleting only the resolved
  /// keychain would let a disconnected destination come back on the next
  /// launch. Forgetting a credential has to mean forgetting it.
  @override
  Future<void> delete(String key) async {
    final _Keychain primary = await _keychain();
    await _storage(primary).delete(key: key);
    await _deleteQuietly(_other(primary), key);
  }

  Future<_Keychain> _keychain() => _resolved ??= _probe();

  /// Writes and removes [probeKey]. The only operation that distinguishes the
  /// two keychains, so it is what the decision is made on.
  Future<_Keychain> _probe() async {
    try {
      final FlutterSecureStorage storage = _storage(_Keychain.dataProtection);
      await storage.write(key: probeKey, value: '1');
      await storage.delete(key: probeKey);
      return _Keychain.dataProtection;
    } on PlatformException catch (error) {
      // The expected case is the missing entitlement. Anything else is logged
      // with its code rather than swallowed silently — but it still resolves
      // to the login keychain, because a store that cannot decide must still
      // be able to keep a credential. The operation the caller actually asked
      // for is not caught here and reports its own failure.
      logger?.info(
        'keychain_fallback',
        fields: <String, Object?>{
          'reason': _isMissingEntitlement(error)
              ? 'the data-protection keychain needs an entitlement this '
                    'build does not carry'
              : 'the data-protection keychain refused the probe',
          'code': error.details?.toString() ?? error.code,
          'using': 'login keychain',
        },
      );
      return _Keychain.login;
    }
  }

  Future<String?> _readQuietly(_Keychain keychain, String key) async {
    try {
      return await _storage(keychain).read(key: key);
    } on PlatformException {
      return null;
    }
  }

  Future<void> _deleteQuietly(_Keychain keychain, String key) async {
    try {
      await _storage(keychain).delete(key: key);
    } on PlatformException {
      // The other keychain is unreachable, so it holds nothing to forget.
    }
  }

  static _Keychain _other(_Keychain keychain) =>
      keychain == _Keychain.login ? _Keychain.dataProtection : _Keychain.login;

  FlutterSecureStorage _storage(_Keychain keychain) =>
      _injected ??
      FlutterSecureStorage(
        aOptions: _android,
        mOptions: keychain == _Keychain.login
            ? _loginKeychain
            : _dataProtectionKeychain,
      );

  static bool _isMissingEntitlement(PlatformException error) =>
      error.details == missingEntitlement ||
      (error.message?.contains('$missingEntitlement') ?? false);
}
