import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/src/command_runner.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/logger.dart';

Future<void> main(List<String> args) async {
  final logger = Logger();
  try {
    final code = await Easyi18nCommandRunner(logger: logger).run(args) ?? 0;
    exit(code);
  } on CliException catch (e) {
    logger.error(e.message);
    exit(e.exitCode);
  } on UsageException catch (e) {
    stderr.writeln(e);
    exit(64);
  }
}
