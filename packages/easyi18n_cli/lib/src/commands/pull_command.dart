import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../api_client.dart';
import '../config.dart';
import '../exceptions.dart';
import '../logger.dart';
import '../state.dart';

/// Builds the API client `pull` talks to. Injected so tests can swap in a
/// `MockClient`-backed instance.
typedef ApiClientFactory =
    TranslationsApiClient Function({
      required String baseUrl,
      required String token,
    });

/// `easyi18n pull` — downloads the translated files for the configured project
/// from the authenticated backend and writes them to the output directory, so
/// the dev can run `flutter gen-l10n` (Mode A — native .arb).
class PullCommand extends Command<int> {
  PullCommand({
    required Logger logger,
    ApiClientFactory? apiClientFactory,
    Map<String, String>? environment,
  }) : _logger = logger,
       _apiClientFactory = apiClientFactory ?? _defaultFactory,
       _environment = environment ?? Platform.environment {
    argParser
      ..addOption(
        'token',
        help:
            'API key (eik_) with the read scope. '
            'Defaults to \$EASYI18N_TOKEN.',
      )
      ..addOption(
        'version',
        help: 'Published version to pull (YYYY.MM.DD.N). Defaults to latest.',
      )
      ..addOption('lang', help: 'Only pull one locale (e.g. es).')
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'List the files that would be written without writing them.',
      );
  }

  final Logger _logger;
  final ApiClientFactory _apiClientFactory;
  final Map<String, String> _environment;

  static const String tokenEnvVar = 'EASYI18N_TOKEN';

  @override
  String get name => 'pull';

  @override
  String get description =>
      'Download translated files from easyi18n and write them to disk.';

  @override
  Future<int> run() async {
    final results = argResults!;
    final configPath =
        globalResults?['config'] as String? ?? Easyi18nConfig.fileName;
    final config = Easyi18nConfig.load(File(configPath));

    final token =
        (results['token'] as String?)?.trim() ??
        _environment[tokenEnvVar]?.trim();
    if (token == null || token.isEmpty) {
      throw CliException(
        'No credential. Set $tokenEnvVar or pass --token.\n'
        'Create an API key in your project settings (needs the read scope).',
      );
    }

    final client = _apiClientFactory(baseUrl: config.baseUrl, token: token);
    final PulledTranslations pulled;
    try {
      pulled = await client.fetchTranslations(
        projectId: config.projectId,
        format: config.format,
        version: results['version'] as String?,
        lang: results['lang'] as String?,
      );
    } finally {
      client.close();
    }

    if (pulled.files.isEmpty) {
      throw CliException(
        'The backend returned no files for format "${config.format}". '
        'Is that format configured for the project?',
      );
    }

    final outputDir = p.normalize(p.join(p.dirname(configPath), config.output));
    final dryRun = results['dry-run'] as bool;

    _logger.info(
      '${dryRun ? 'Would pull' : 'Pulled'} ${pulled.files.length} file(s) '
      'for ${config.projectId} (version ${pulled.version}) into $outputDir',
    );

    for (final relPath in pulled.files.keys.toList()..sort()) {
      final stripped = _stripFormatPrefix(relPath, config.format);
      final target = p.join(outputDir, stripped);
      if (dryRun) {
        _logger.detail(stripped);
        continue;
      }
      final file = File(target);
      file.parent.createSync(recursive: true);
      // Write to a sibling temp file then atomically rename, so a mid-write
      // failure can't leave a half-written (un-`gen-l10n`-able) .arb in place.
      final tmp = File('$target.tmp');
      tmp.writeAsStringSync(pulled.files[relPath]!);
      tmp.renameSync(target);
      _logger.detail(stripped);
    }

    if (!dryRun) {
      // Record what now sits on disk, so `easyi18n status` can compare it
      // against the server. Best-effort: a cache write must never fail a
      // successful pull.
      try {
        CliState(version: pulled.version, pulledAt: DateTime.now().toUtc())
            .save(CliState.fileFor(configPath));
      } on FileSystemException {
        _logger.detail('Could not write ${CliState.dirName}/${CliState.fileName}.');
      }
      _logger.info("Run 'flutter gen-l10n' to regenerate your localizations.");
    }
    return 0;
  }

  /// The backend namespaces files under the format id (`arb/app_en.arb`); strip
  /// it so files land directly in the output dir (gen-l10n's `arb-dir`).
  String _stripFormatPrefix(String relPath, String format) {
    final prefix = '$format/';
    return relPath.startsWith(prefix)
        ? relPath.substring(prefix.length)
        : relPath;
  }

  static TranslationsApiClient _defaultFactory({
    required String baseUrl,
    required String token,
  }) => TranslationsApiClient(baseUrl: baseUrl, token: token);
}
