import 'package:args/command_runner.dart';

import 'commands/doctor_command.dart';
import 'commands/extract_command.dart';
import 'commands/init_command.dart';
import 'commands/pull_command.dart';
import 'commands/push_command.dart';
import 'commands/rollback_command.dart';
import 'commands/status_command.dart';
import 'logger.dart';

/// The `easyi18n` CLI. Wires up the commands and a global `--config` option so
/// they share one config-path resolution.
class Easyi18nCommandRunner extends CommandRunner<int> {
  Easyi18nCommandRunner({CliLogger? logger})
    : super(
        'easyi18n',
        'Manage easyi18n translations from your project: pull translated '
            'files (Mode A) and push tr() sources for translation.',
      ) {
    final log = logger ?? CliLogger();
    argParser.addOption(
      'config',
      help: 'Path to the config file.',
      defaultsTo: 'easyi18n.yaml',
    );
    addCommand(InitCommand(logger: log));
    addCommand(DoctorCommand(logger: log));
    addCommand(PullCommand(logger: log));
    addCommand(ExtractCommand(logger: log));
    addCommand(PushCommand(logger: log));
    addCommand(RollbackCommand(logger: log));
    addCommand(StatusCommand(logger: log));
  }
}
