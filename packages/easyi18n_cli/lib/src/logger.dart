import 'dart:io';

/// Minimal output sink so commands stay testable: `out` is captured in tests,
/// `err` goes to stderr in production. No color/ANSI to keep CI logs clean.
class CliLogger {
  CliLogger({StringSink? out, StringSink? err})
    : _out = out ?? stdout,
      _err = err ?? stderr;

  final StringSink _out;
  final StringSink _err;

  void info(String message) => _out.writeln(_sanitize(message));
  void detail(String message) => _out.writeln('  ${_sanitize(message)}');
  void warn(String message) => _err.writeln('warning: ${_sanitize(message)}');
  void error(String message) => _err.writeln('error: ${_sanitize(message)}');

  // Strip C0/C1 control characters (keeping tab `\x09` and newline `\x0A`, but
  // NOT carriage return `\x0D`) from everything printed, so server-provided
  // text routed through the logger cannot inject terminal escape sequences
  // (cursor/title/clipboard control) or rewrite the line with a bare CR to
  // spoof output. Our own messages contain none of these, so this only ever
  // defangs untrusted input.
  static final RegExp _control = RegExp(r'[\x00-\x08\x0B-\x1F\x7F-\x9F]');
  static String _sanitize(String message) => message.replaceAll(_control, '');
}
