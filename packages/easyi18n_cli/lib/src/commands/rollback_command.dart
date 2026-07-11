import 'dart:io';

import 'package:args/command_runner.dart';

import '../api_client.dart';
import '../config.dart';
import '../exceptions.dart';
import '../logger.dart';
import '../resolve.dart';
import '../security.dart';
import 'pull_command.dart' show ApiClientFactory;

/// `easyi18n rollback [version]` - restore a prior published version as a NEW
/// version (history is never rewritten) and point delivery at it. With no
/// argument it restores the version just before the current one - the "undo
/// the last publish" move after a bad `push --publish`.
class RollbackCommand extends Command<int> {
  RollbackCommand({
    required CliLogger logger,
    ApiClientFactory? apiClientFactory,
    Map<String, String>? environment,
  }) : _logger = logger,
       _apiClientFactory = apiClientFactory ?? _defaultFactory,
       _environment = environment ?? Platform.environment {
    argParser.addOption(
      'token',
      help:
          'API key (eik_) with the publish scope. '
          'Defaults to \$EASYI18N_TOKEN.',
    );
  }

  final CliLogger _logger;
  final ApiClientFactory _apiClientFactory;
  final Map<String, String> _environment;

  @override
  String get name => 'rollback';

  @override
  String get description =>
      'Restore a prior published version (default: the previous one) as a '
      'new version.';

  @override
  String get invocation => 'easyi18n rollback [version]';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length > 1) {
      throw CliException(
        'At most one version id, got: ${rest.join(' ')}. '
        'Usage: easyi18n rollback [version]',
      );
    }
    final versionId = rest.isEmpty ? 'previous' : rest.single.trim();

    final configPath =
        globalResults?['config'] as String? ?? Easyi18nConfig.fileName;
    final config = Easyi18nConfig.load(File(configPath));

    final token =
        (argResults!['token'] as String?)?.trim() ??
        _environment['EASYI18N_TOKEN']?.trim();
    if (token == null || token.isEmpty) {
      throw CliException(
        'No credential. Set EASYI18N_TOKEN or pass --token.\n'
        'Create an API key in your project settings (needs the publish '
        'scope).',
      );
    }

    warnOnUntrustedTarget(config.baseUrl, _logger);

    final client = _apiClientFactory(baseUrl: config.baseUrl, token: token);
    try {
      final projectId = await resolveProjectId(config, client, logger: _logger);
      final outcome = await client.restoreVersion(
        projectId: projectId,
        versionId: versionId,
      );
      _logger.info(
        'Rolled back: ${outcome.restoredFrom ?? versionId} restored as '
        '${outcome.versionId} (${outcome.keyCount} key(s)).',
      );
      return 0;
    } finally {
      client.close();
    }
  }

  static TranslationsApiClient _defaultFactory({
    required String baseUrl,
    required String token,
  }) => TranslationsApiClient(baseUrl: baseUrl, token: token);
}
