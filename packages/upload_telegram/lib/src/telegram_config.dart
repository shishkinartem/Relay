import 'package:meta/meta.dart';

/// Endpoint and credentials for the Telegram Bot API (§16).
///
/// The base URL is configurable so the same destination can talk to a
/// self-hosted Local Bot API Server, which lifts the hosted upload cap.
@immutable
class TelegramConfig {
  TelegramConfig({required this.botToken, required this.chatId, Uri? baseUrl})
    : baseUrl = baseUrl ?? hostedBaseUrl;

  /// The official hosted Bot API, capped at [hostedMaxUploadBytes].
  TelegramConfig.hosted({required String botToken, required String chatId})
    : this(botToken: botToken, chatId: chatId);

  /// No credentials yet: [isConfigured] is false, so uploads fail pre-flight
  /// instead of reaching the network.
  TelegramConfig.unconfigured() : this(botToken: '', chatId: '');

  static const String hostedHost = 'api.telegram.org';

  /// Documented hosted Bot API ceiling for a sent video (§16).
  static const int hostedMaxUploadBytes = 50 * 1024 * 1024;

  static final Uri hostedBaseUrl = Uri.parse('https://$hostedHost');

  final String botToken;
  final String chatId;
  final Uri baseUrl;

  bool get isConfigured => botToken.isNotEmpty && chatId.isNotEmpty;

  bool get isHostedApi => baseUrl.host.toLowerCase() == hostedHost;

  /// Null on a Local Bot API Server: it has no fixed cap, which is what makes
  /// the "50 MB max" tag disappear from the UI with no UI change (§16, §28).
  int? get maxUploadBytes => isHostedApi ? hostedMaxUploadBytes : null;

  String get endpointLabel =>
      isHostedApi ? 'Hosted Bot API' : 'Local Bot API Server';

  /// Never includes the bot token: this string reaches logs and diagnostics
  /// (§26, §27).
  @override
  String toString() =>
      'TelegramConfig($endpointLabel, chatId: ${chatId.isEmpty ? '<unset>' : chatId}, '
      'configured: $isConfigured)';
}
