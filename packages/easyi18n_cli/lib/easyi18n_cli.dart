/// Programmatic entry point for the easyi18n CLI.
///
/// Most users run the bundled `easyi18n` executable; this library exposes the
/// same command set so you can embed it in your own Dart tooling:
///
/// ```dart
/// import 'package:easyi18n_cli/easyi18n_cli.dart';
///
/// Future<void> main(List<String> args) =>
///     Easyi18nCommandRunner().run(args);
/// ```
library;

export 'src/command_runner.dart' show Easyi18nCommandRunner;
export 'src/exceptions.dart' show CliException;
export 'src/logger.dart' show CliLogger;
