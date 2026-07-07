import 'dart:io';

/// Minimal output sink so commands stay testable: `out` is captured in tests,
/// `err` goes to stderr in production. No color/ANSI to keep CI logs clean.
class Logger {
  Logger({StringSink? out, StringSink? err})
    : _out = out ?? stdout,
      _err = err ?? stderr;

  final StringSink _out;
  final StringSink _err;

  void info(String message) => _out.writeln(message);
  void detail(String message) => _out.writeln('  $message');
  void warn(String message) => _err.writeln('warning: $message');
  void error(String message) => _err.writeln('error: $message');
}
