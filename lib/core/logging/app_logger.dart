import 'dart:collection';

import 'package:flutter/foundation.dart';

/// Severity of a [LogRecord].
enum LogLevel {
  debug,
  info,
  warn,
  error;

  String get label => switch (this) {
    LogLevel.debug => 'DEBUG',
    LogLevel.info => 'INFO',
    LogLevel.warn => 'WARN',
    LogLevel.error => 'ERROR',
  };
}

/// One structured log entry (§26).
///
/// Records reaching a sink are already redacted; [fields] and [error] hold no
/// credential material.
@immutable
class LogRecord {
  const LogRecord({
    required this.level,
    required this.event,
    required this.timestamp,
    this.fields = const <String, Object?>{},
    this.error,
  });

  final LogLevel level;

  /// Dotted machine-readable name, e.g. `recording.state_changed`.
  final String event;

  final Map<String, Object?> fields;
  final DateTime timestamp;

  /// Redacted description of the associated failure, when any.
  final Object? error;

  String format() {
    final StringBuffer buffer = StringBuffer()
      ..write(timestamp.toUtc().toIso8601String())
      ..write(' [')
      ..write(level.label)
      ..write('] ')
      ..write(event);
    for (final MapEntry<String, Object?> field in fields.entries) {
      buffer.write(' ${field.key}=${field.value}');
    }
    if (error != null) {
      buffer.write(' error=$error');
    }
    return buffer.toString();
  }

  @override
  String toString() => format();
}

/// Destination for log records.
abstract interface class LogSink {
  void write(LogRecord record);
}

/// Prints to the developer console in debug builds only.
class ConsoleLogSink implements LogSink {
  const ConsoleLogSink();

  @override
  void write(LogRecord record) {
    if (kDebugMode) {
      debugPrint(record.format());
    }
  }
}

/// Collects the most recent records in memory. Intended for tests.
///
/// Retention for the shipped app belongs to [AppLogger]'s own ring buffer,
/// which is what [AppLogger.exportRedactedDiagnostics] reads; this sink is
/// bounded too so that wiring it up anywhere cannot grow without limit.
class MemoryLogSink implements LogSink {
  MemoryLogSink({this.capacity = defaultCapacity})
    : assert(capacity > 0, 'capacity must be positive');

  static const int defaultCapacity = 500;

  /// Maximum records retained; the oldest are evicted first.
  final int capacity;

  final Queue<LogRecord> _records = ListQueue<LogRecord>();

  /// Retained records, oldest first.
  List<LogRecord> get records => List<LogRecord>.unmodifiable(_records);

  @override
  void write(LogRecord record) {
    _records.addLast(record);
    while (_records.length > capacity) {
      _records.removeFirst();
    }
  }

  void clear() => _records.clear();
}

/// Strips credential material out of log fields (§26, §27).
///
/// Two independent rules, because either alone leaks: a field named after a
/// secret is dropped whatever it holds, and any string *shaped* like a bearer
/// or Telegram bot token is masked wherever it occurs, including inside nested
/// maps and lists.
class LogRedactor {
  const LogRedactor();

  static const String placeholder = '<redacted>';

  static const List<String> sensitiveKeyFragments = <String>[
    'token',
    'secret',
    'password',
    'authorization',
    'auth',
    'credential',
    'refresh',
    'code_verifier',
    'client_secret',
    'apikey',
    'api_key',
    'bearer',
  ];

  /// `123456789:AA...` — Telegram bot token shape.
  static final RegExp _botTokenPattern = RegExp(r'\d{6,}:[A-Za-z0-9_\-]{30,}');

  static final RegExp _bearerPattern = RegExp(
    r'bearer\s+[A-Za-z0-9\-._~+/]{20,}={0,2}',
    caseSensitive: false,
  );

  bool isSensitiveKey(String key) {
    final String lower = key.toLowerCase();
    return sensitiveKeyFragments.any(lower.contains);
  }

  Map<String, Object?> redactFields(Map<String, Object?> fields) {
    if (fields.isEmpty) {
      return const <String, Object?>{};
    }
    final Map<String, Object?> redacted = <String, Object?>{};
    for (final MapEntry<String, Object?> entry in fields.entries) {
      redacted[entry.key] = isSensitiveKey(entry.key)
          ? placeholder
          : redactValue(entry.value);
    }
    return redacted;
  }

  Object? redactValue(Object? value) {
    if (value is String) {
      return redactText(value);
    }
    if (value is Map<Object?, Object?>) {
      final Map<Object?, Object?> redacted = <Object?, Object?>{};
      for (final MapEntry<Object?, Object?> entry in value.entries) {
        final Object? key = entry.key;
        redacted[key] = key is String && isSensitiveKey(key)
            ? placeholder
            : redactValue(entry.value);
      }
      return redacted;
    }
    if (value is Iterable<Object?>) {
      return value.map(redactValue).toList(growable: false);
    }
    return value;
  }

  /// Masks token-shaped runs inside [value], leaving the rest readable.
  String redactText(String value) => value
      .replaceAll(_botTokenPattern, placeholder)
      .replaceAll(_bearerPattern, placeholder);
}

/// What the rest of the application is allowed to know about logging (§26).
///
/// Every collaborator is reached through an interface, so a caller cannot
/// depend on where a record ends up, on the ring buffer behind it, or on
/// redaction being applied by this particular implementation. Substituting a
/// logger is changing one line in the composition root.
abstract interface class Logger {
  void debug(String event, {Map<String, Object?> fields, Object? error});

  void info(String event, {Map<String, Object?> fields, Object? error});

  void warn(String event, {Map<String, Object?> fields, Object? error});

  void error(String event, {Map<String, Object?> fields, Object? error});
}

/// Structured application logger with a bounded diagnostics buffer (§26).
class AppLogger implements Logger {
  AppLogger({
    List<LogSink> sinks = const <LogSink>[],
    this.redactor = const LogRedactor(),
    this.bufferSize = defaultBufferSize,
  }) : _sinks = List<LogSink>.of(sinks);

  static const int defaultBufferSize = 500;

  final LogRedactor redactor;

  /// Maximum records retained for [exportRedactedDiagnostics].
  final int bufferSize;

  final List<LogSink> _sinks;
  final Queue<LogRecord> _buffer = ListQueue<LogRecord>();

  /// Most recent records, oldest first. Already redacted.
  List<LogRecord> get records => List<LogRecord>.unmodifiable(_buffer);

  void log(
    LogLevel level,
    String event, {
    Map<String, Object?> fields = const <String, Object?>{},
    Object? error,
  }) {
    final LogRecord record = LogRecord(
      level: level,
      event: event,
      timestamp: DateTime.now(),
      fields: redactor.redactFields(fields),
      error: error == null ? null : redactor.redactText(error.toString()),
    );

    _buffer.addLast(record);
    while (_buffer.length > bufferSize) {
      _buffer.removeFirst();
    }
    for (final LogSink sink in _sinks) {
      sink.write(record);
    }
  }

  @override
  void debug(
    String event, {
    Map<String, Object?> fields = const <String, Object?>{},
    Object? error,
  }) => log(LogLevel.debug, event, fields: fields, error: error);

  @override
  void info(
    String event, {
    Map<String, Object?> fields = const <String, Object?>{},
    Object? error,
  }) => log(LogLevel.info, event, fields: fields, error: error);

  @override
  void warn(
    String event, {
    Map<String, Object?> fields = const <String, Object?>{},
    Object? error,
  }) => log(LogLevel.warn, event, fields: fields, error: error);

  @override
  void error(
    String event, {
    Map<String, Object?> fields = const <String, Object?>{},
    Object? error,
  }) => log(LogLevel.error, event, fields: fields, error: error);

  /// The buffered records as shareable text. Redaction is applied at capture
  /// time; re-applying it here keeps the guarantee if a record is ever
  /// constructed outside [log].
  String exportRedactedDiagnostics() =>
      redactor.redactText(_buffer.map((LogRecord r) => r.format()).join('\n'));

  void clear() => _buffer.clear();
}
