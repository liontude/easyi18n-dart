/// A user-facing CLI failure: printed without a stack trace and mapped to a
/// non-zero exit code. Anything else bubbles up as an unexpected error.
class CliException implements Exception {
  CliException(this.message, {this.exitCode = 1});

  final String message;
  final int exitCode;

  @override
  String toString() => message;
}
