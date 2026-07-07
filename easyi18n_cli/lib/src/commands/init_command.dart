import 'dart:io';

import 'package:args/command_runner.dart';

import '../config.dart';
import '../exceptions.dart';
import '../logger.dart';

/// Asks the user for one value, returning null when there's no way to ask
/// (e.g. non-interactive). Injectable so tests never touch the real terminal.
typedef Prompt = String? Function(String label);

/// `easyi18n init` — writes an `easyi18n.yaml` for the current project. Values
/// come from flags; missing ones are prompted interactively when attached to a
/// terminal, otherwise they fall back to defaults (or fail for required ones).
class InitCommand extends Command<int> {
  InitCommand({required Logger logger, Prompt? prompt})
    : _logger = logger,
      _prompt = prompt ?? _terminalPrompt {
    argParser
      ..addOption('project-id', help: 'The easyi18n project id to pull.')
      ..addOption(
        'base-url',
        help: 'Backend origin.',
        defaultsTo: Easyi18nConfig.defaultBaseUrl,
      )
      ..addOption(
        'format',
        help: 'Output format (arb, json, po, ...).',
        defaultsTo: Easyi18nConfig.defaultFormat,
      )
      ..addOption(
        'output',
        help: 'Directory to write files into.',
        defaultsTo: Easyi18nConfig.defaultOutput,
      )
      ..addFlag(
        'force',
        abbr: 'f',
        negatable: false,
        help: 'Overwrite an existing config file.',
      );
  }

  final Logger _logger;
  final Prompt _prompt;

  @override
  String get name => 'init';

  @override
  String get description => 'Create an easyi18n.yaml config file.';

  @override
  Future<int> run() async {
    final results = argResults!;
    final configPath =
        globalResults?['config'] as String? ?? Easyi18nConfig.fileName;
    final file = File(configPath);

    if (file.existsSync() && !(results['force'] as bool)) {
      throw CliException(
        '$configPath already exists. Re-run with --force to overwrite.',
      );
    }

    final projectId =
        (results['project-id'] as String?)?.trim() ??
        _prompt('Project id')?.trim();
    if (projectId == null || projectId.isEmpty) {
      throw CliException(
        "Missing project id. Pass --project-id or run 'easyi18n init' "
        'in a terminal.',
      );
    }

    final config = Easyi18nConfig(
      projectId: projectId,
      baseUrl: results['base-url'] as String?,
      format: results['format'] as String?,
      output: results['output'] as String?,
    );

    file.writeAsStringSync(config.toYaml());
    _logger.info('Wrote $configPath');
    _logger.detail("Set EASYI18N_TOKEN, then run 'easyi18n pull'.");
    return 0;
  }

  /// Asks for a value on the terminal. Returns null when stdin is not a TTY so
  /// the caller can fail (required) instead of blocking on `readLineSync`.
  static String? _terminalPrompt(String label) {
    if (!stdin.hasTerminal) return null;
    stdout.write('$label: ');
    return stdin.readLineSync();
  }
}
