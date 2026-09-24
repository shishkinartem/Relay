import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_logger.dart';

/// Writes log records to a file that survives the process (§26).
///
/// [ConsoleLogSink] is gated behind `kDebugMode`, which means a shipped build
/// emitted nothing at all: a user reporting "my recording disappeared" had no
/// artefact to send and no one had anything to read. This is the sink that
/// makes a release build diagnosable.
///
/// Bounded on purpose, twice over. Records go through an [IOSink] so a log
/// write never blocks the frame that produced it, and the file is rotated at
/// [maxBytes] with exactly one previous generation kept — a recorder can run
/// for hours, and an unbounded log on the user's disk is the same bug as an
/// unbounded frame queue.
///
/// Durability is deliberately uneven. Warn and error records are flushed as
/// they are written, because the log's whole purpose is to survive the process
/// that stopped; debug and info are left in the sink's buffer, because they
/// arrive several times a second during a recording and a flush each would be
/// real file I/O on the thread that produced the record (§26).
///
/// Redaction happens before a record reaches any sink ([AppLogger.log]), so
/// nothing written here carries credential material.
class FileLogSink implements LogSink {
  FileLogSink._(
    this._file,
    this._previous,
    this._sink,
    this._bytesWritten, {
    required this.maxBytes,
  });

  /// Default cap per generation. Two generations, so at most twice this on
  /// disk.
  static const int defaultMaxBytes = 2 * 1024 * 1024;

  /// Opens [file] for appending, rotating first if it is already at the cap.
  ///
  /// Never throws: a logger that brings the application down when the disk is
  /// full is worse than no logger. A failure here returns null and the caller
  /// carries on with whatever other sinks it has.
  static Future<FileLogSink?> open(
    File file, {
    int maxBytes = defaultMaxBytes,
  }) async {
    try {
      final File previous = File('${file.path}.1');
      // Synchronous existence and length checks throughout: this runs once at
      // startup and once per rotation, and `avoid_slow_async_io` is right that
      // the async forms buy nothing at this scale.
      file.parent.createSync(recursive: true);
      int existing = file.existsSync() ? file.lengthSync() : 0;
      if (existing >= maxBytes) {
        _rotate(file, previous);
        existing = 0;
      }
      // Owned by the returned FileLogSink: closed in `close()`, reopened on
      // rotation.
      // ignore: close_sinks -- ownership transfers to the returned sink.
      final IOSink sink = file.openWrite(mode: FileMode.append, encoding: utf8);
      return FileLogSink._(file, previous, sink, existing, maxBytes: maxBytes);
    } on Object {
      return null;
    }
  }

  /// Maximum bytes per generation before the file rotates.
  final int maxBytes;

  final File _file;
  final File _previous;

  IOSink _sink;
  int _bytesWritten;

  /// Whether `write` still takes new records. Cleared by `close`.
  bool _accepting = true;

  /// Whether `_sink` may still be written to. Cleared only after the queue
  /// below has drained, so a record accepted before `close` is not dropped by
  /// it.
  bool _sinkOpen = true;

  /// Records logged while the sink is busy — mid-rotation or mid-flush.
  ///
  /// A rotation renames the file out from under the handle, so a record
  /// written during one has to wait rather than race it. A flush is the same
  /// hazard for a different reason: an [IOSink] is *bound* while it flushes and
  /// refuses both a write and a close, and this class swallows write failures —
  /// so a record logged during a flush was silently dropped, which cost exactly
  /// the record the flush was protecting. They are drained one at a time
  /// afterwards, re-checking the cap as they go — appending the whole backlog
  /// at once is what let a synchronous burst carry a generation far past
  /// [maxBytes] before the next rotation could be scheduled.
  final Queue<_PendingLine> _pending = Queue<_PendingLine>();

  /// Cap on that backlog. Bounded for the same reason the media queues are:
  /// the alternative is a burst the process cannot outrun holding the whole
  /// log in memory. Overflow is dropped and counted, never silently lost.
  static const int maxPendingLines = 4096;
  int _droppedLines = 0;

  /// How many times a record has been flushed to the file.
  ///
  /// A flush is otherwise invisible from a test: an [IOSink] pumps its buffer
  /// out on its own eventually, so "the line is in the file" cannot tell a
  /// flushed record from one that merely had time. This counter is what lets
  /// the durability rule above be asserted rather than assumed.
  @visibleForTesting
  int get flushes => _flushes;
  int _flushes = 0;

  /// The rotation currently in flight, so `close` can wait for it.
  Future<void> _rotation = Future<void>.value();
  bool _rotating = false;

  /// The flush currently in flight, for the same reason. Mutually exclusive
  /// with a rotation: each waits for the other rather than sharing the handle.
  Future<void> _flush = Future<void>.value();
  bool _flushing = false;

  /// Whether the handle can take a write at all right now.
  bool get _busy => _rotating || _flushing;

  @override
  void write(LogRecord record) {
    if (!_accepting) {
      return;
    }
    final String line = '${record.format()}\n';
    final int bytes = utf8.encode(line).length;
    if (_busy) {
      if (_pending.length >= maxPendingLines) {
        _droppedLines++;
        return;
      }
      _pending.addLast(_PendingLine(line, bytes, record.level));
      return;
    }
    _append(line, bytes, record.level);
    _scheduleRotation();
  }

  void _append(String line, int bytes, LogLevel level) {
    if (!_sinkOpen) {
      return;
    }
    try {
      _sink.write(line);
      _bytesWritten += bytes;
      // An IOSink buffers, so a process that dies mid-recording takes its tail
      // with it — and that tail is precisely the evidence the crash was worth
      // reading. A Windows session whose encoder stalled left none of it.
      // Flushed for warn and error only: debug and info arrive roughly four
      // times a second while a session runs (`recorder_stats`,
      // `platform_state`), and a flush on each would put real file I/O on the
      // thread that produced the record (§26).
      if (level == LogLevel.warn || level == LogLevel.error) {
        _scheduleFlush();
      }
    } on Object {
      // A log line is never worth an exception on the path that produced it.
    }
  }

  void _scheduleFlush() {
    if (_busy || !_sinkOpen) {
      return;
    }
    _flushing = true;
    _flush = _flushNow();
  }

  /// Flushes without letting the failure escape as an unhandled async error.
  ///
  /// The record is already in the sink's buffer either way, so a failed flush
  /// costs durability for one line, not the line itself.
  Future<void> _flushNow() async {
    _flushes++;
    try {
      await _sink.flush();
    } on Object {
      // Closed, rotating, or a full disk. The next rotation or `close` retries.
    } finally {
      _flushing = false;
    }
    _scheduleRotation();
    _drainPending();
  }

  void _scheduleRotation() {
    if (_busy || !_sinkOpen || _bytesWritten < maxBytes) {
      return;
    }
    _rotating = true;
    _rotation = _rotateNow();
  }

  Future<void> _rotateNow() async {
    try {
      await _sink.flush();
      await _sink.close();
      _rotate(_file, _previous);
      _sink = _file.openWrite(mode: FileMode.append, encoding: utf8);
      _bytesWritten = 0;
    } on Object {
      // Rotation failed. Keep the handle that is still open rather than losing
      // the log entirely.
    } finally {
      _rotating = false;
    }
    _drainPending();
  }

  /// Writes the backlog out, rotating again the moment the cap is reached.
  void _drainPending() {
    while (_pending.isNotEmpty && !_busy) {
      final _PendingLine next = _pending.removeFirst();
      _append(next.line, next.bytes, next.level);
      _scheduleRotation();
    }
    if (_droppedLines > 0 && !_busy && _sinkOpen) {
      final int dropped = _droppedLines;
      _droppedLines = 0;
      final String note =
          '${DateTime.now().toUtc().toIso8601String()} [WARN] '
          'log_backlog_dropped lines=$dropped\n';
      _append(note, utf8.encode(note).length, LogLevel.warn);
    }
  }

  /// Flushes every accepted record and closes the file. Idempotent.
  ///
  /// Waiting for the rotation, the flush and the backlog is the point: closing
  /// without draining them would throw away the last lines written before a
  /// quit — exactly the ones worth reading. An [IOSink] also refuses a close
  /// while it is flushing, so the wait is what keeps the handle closable.
  Future<void> close() async {
    if (!_accepting) {
      await _rotation;
      await _flush;
      return;
    }
    _accepting = false;
    try {
      while (_busy || _pending.isNotEmpty) {
        await _rotation;
        await _flush;
        _drainPending();
      }
      await _sink.flush();
      await _sink.close();
    } on Object {
      // Nothing to report to: this runs while the application is going away.
    } finally {
      _sinkOpen = false;
    }
  }

  static void _rotate(File file, File previous) {
    if (previous.existsSync()) {
      previous.deleteSync();
    }
    if (file.existsSync()) {
      file.renameSync(previous.path);
    }
  }
}

/// One buffered record: the formatted line, its encoded size and its level.
///
/// The level travels with the line so a record that waited out a rotation is
/// flushed on the same rule as one written directly.
class _PendingLine {
  const _PendingLine(this.line, this.bytes, this.level);

  final String line;
  final int bytes;
  final LogLevel level;
}
