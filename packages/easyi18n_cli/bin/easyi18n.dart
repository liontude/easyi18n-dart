import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/easyi18n_cli.dart';

Future<void> main(List<String> args) async {
  final logger = CliLogger();
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
