import 'dart:io';

import 'package:args/command_runner.dart';

import '../api_client.dart';
import '../config.dart';
import '../exceptions.dart';
import '../logger.dart';
import '../state.dart';
import 'pull_command.dart' show ApiClientFactory;

/// `easyi18n status` — compares the last pulled version (`.easyi18n/state.json`)
/// against the server's current published version, so a dev can tell at a
/// glance whether the files on disk are up to date
/// (`publish-versioning.md` §4.5).
class StatusCommand extends Command<int> {
  StatusCommand({
    required Logger logger,
    ApiClientFactory? apiClientFactory,
    Map<String, String>? environment,
  }) : _logger = logger,
       _apiClientFactory = apiClientFactory ?? _defaultFactory,
       _environment = environment ?? Platform.environment {
    argParser.addOption(
      'token',
      help:
          'API key (eik_) with the read scope. '
          'Defaults to \$EASYI18N_TOKEN.',
    );
  }

  final Logger _logger;
  final ApiClientFactory _apiClientFactory;
  final Map<String, String> _environment;

  @override
  String get name => 'status';

  @override
  String get description =>
      'Show whether the local translations are up to date with the server.';

  @override
  Future<int> run() async {
    final configPath =
        globalResults?['config'] as String? ?? Easyi18nConfig.fileName;
    final config = Easyi18nConfig.load(File(configPath));
    final state = CliState.load(CliState.fileFor(configPath));

    final token =
        (argResults!['token'] as String?)?.trim() ??
        _environment['EASYI18N_TOKEN']?.trim();
    if (token == null || token.isEmpty) {
      throw CliException(
        'No credential. Set EASYI18N_TOKEN or pass --token.\n'
        'Create an API key in your project settings (needs the read scope).',
      );
    }

    final client = _apiClientFactory(baseUrl: config.baseUrl, token: token);
    final ProjectMeta meta;
    try {
      meta = await client.fetchMeta(projectId: config.projectId);
    } finally {
      client.close();
    }

    final remote = meta.currentVersionId;
    _logger.info('remote: $remote');

    final local = state.version;
    if (local == null) {
      _logger.info('local:  (never pulled)');
      _logger.info("Run 'easyi18n pull' to download the current version.");
      return 1;
    }
    final pulledAgo = state.pulledAt == null
        ? ''
        : ' (pulled ${_ago(state.pulledAt!)})';
    _logger.info('local:  $local$pulledAgo');

    final cmp = comparePublishVersions(local, remote);
    if (cmp >= 0) {
      _logger.info('Up to date.');
      return 0;
    }
    _logger.info("Out of date${_behind(local, remote)} — run 'easyi18n pull'.");
    return 1;
  }

  /// `" — N publishes behind"` when both versions parse and share the same
  /// day (the counter difference is exact there); empty otherwise.
  String _behind(String local, String remote) {
    final pl = parsePublishVersion(local);
    final pr = parsePublishVersion(remote);
    if (pl == null || pr == null || pl.date != pr.date) return '';
    final behind = pr.n - pl.n;
    return ' — $behind publish${behind == 1 ? '' : 'es'} behind';
  }

  String _ago(DateTime t) {
    final d = DateTime.now().toUtc().difference(t.toUtc());
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  static TranslationsApiClient _defaultFactory({
    required String baseUrl,
    required String token,
  }) => TranslationsApiClient(baseUrl: baseUrl, token: token);
}
