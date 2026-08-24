/// OS-backed secret storage (§17, §27).
///
/// Maps to the macOS Keychain and the Windows Credential Manager. Refresh
/// tokens never touch `.env`, source, plain preferences or logs.
abstract interface class CredentialStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// In-memory store for tests and for a session that declines persistence.
class InMemoryCredentialStore implements CredentialStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;
}
