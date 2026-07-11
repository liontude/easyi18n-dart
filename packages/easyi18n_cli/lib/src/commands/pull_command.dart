import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../api_client.dart';
import '../config.dart';
import '../exceptions.dart';
import '../logger.dart';
import '../resolve.dart';
import '../security.dart';
import '../state.dart';

/// Builds the API client `pull` talks to. Injected so tests can swap in a
/// `MockClient`-backed instance.
typedef ApiClientFactory =
    TranslationsApiClient Function({
      required String baseUrl,
      required String token,
    });

/// `easyi18n pull` - downloads the translated files for the configured project
/// from the authenticated backend and writes them to the output directory, so
/// the dev can run `flutter gen-l10n` (Mode A - native .arb).
///
/// `--watch` keeps running: it polls the project's `meta` (cheap - one small
/// GET per cycle, no file bodies) and re-pulls whenever `currentVersionId`
/// changes, so a publish from the dashboard or CI lands on disk by itself.
class PullCommand extends Command<int> {
  PullCommand({
    required CliLogger logger,
    ApiClientFactory? apiClientFactory,
    Map<String, String>? environment,
    Future<void> Function(Duration)? sleeper,
    int? watchCyclesForTest,
  }) : _logger = logger,
       _apiClientFactory = apiClientFactory ?? _defaultFactory,
       _environment = environment ?? Platform.environment,
       _sleep = sleeper ?? Future<void>.delayed,
       _watchCyclesForTest = watchCyclesForTest {
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
      )
      ..addFlag(
        'watch',
        negatable: false,
        help:
            'Keep running: re-pull whenever a new version is published. '
            'Ctrl-C to stop.',
      )
      ..addOption(
        'interval',
        defaultsTo: '30',
        help: 'Seconds between version checks in --watch mode (min 5).',
      );
  }

  final CliLogger _logger;
  final ApiClientFactory _apiClientFactory;
  final Map<String, String> _environment;
  final Future<void> Function(Duration) _sleep;

  /// Tests only: stop the watch loop after N checks instead of running
  /// forever. Null (production) never stops.
  final int? _watchCyclesForTest;

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

    warnOnUntrustedTarget(config.baseUrl, _logger);

    final watch = results['watch'] as bool;
    final dryRun = results['dry-run'] as bool;
    final version = results['version'] as String?;
    final lang = results['lang'] as String?;
    if (watch && version != null) {
      throw CliException(
        '--watch follows the latest published version; it cannot be '
        'combined with --version.',
      );
    }
    if (watch && dryRun) {
      throw CliException('--watch cannot be combined with --dry-run.');
    }

    final client = _apiClientFactory(baseUrl: config.baseUrl, token: token);
    try {
      final projectId = await resolveProjectId(config, client, logger: _logger);
      if (!watch) {
        await _pullOnce(
          client: client,
          config: config,
          projectId: projectId,
          configPath: configPath,
          version: version,
          lang: lang,
          dryRun: dryRun,
        );
        return 0;
      }
      return await _watch(
        client: client,
        config: config,
        projectId: projectId,
        configPath: configPath,
        lang: lang,
        interval: _parseInterval(results['interval'] as String),
      );
    } finally {
      client.close();
    }
  }

  Duration _parseInterval(String raw) {
    final seconds = int.tryParse(raw.trim());
    if (seconds == null || seconds < 5) {
      throw CliException('--interval must be an integer >= 5 (seconds).');
    }
    return Duration(seconds: seconds);
  }

  /// Poll `meta` and re-pull on every new `currentVersionId`. Transient
  /// errors — backend/network (CliException) AND local file I/O
  /// (FileSystemException from the atomic write) — are warnings: a watcher
  /// that dies overnight on one hiccup is worse than one that retries next
  /// cycle. Same for the bootstrap pull: a watch started before the FIRST
  /// publish must idle until a version appears, not exit with an error.
  Future<int> _watch({
    required TranslationsApiClient client,
    required Easyi18nConfig config,
    required String projectId,
    required String configPath,
    required String? lang,
    required Duration interval,
  }) async {
    Future<String> pullLatest() => _pullOnce(
      client: client,
      config: config,
      projectId: projectId,
      configPath: configPath,
      version: null,
      lang: lang,
      dryRun: false,
    );

    var lastVersion = '';
    try {
      lastVersion = await pullLatest();
    } on CliException catch (e) {
      _logger.warn('${e.message} (watching for the first publish)');
    } on FileSystemException catch (e) {
      _logger.warn('${e.message} (retrying next cycle)');
    }
    _logger.info(
      'Watching for new published versions every ${interval.inSeconds}s '
      '- Ctrl-C to stop.',
    );
    var cycles = 0;
    while (_watchCyclesForTest == null || cycles < _watchCyclesForTest) {
      cycles++;
      await _sleep(interval);
      try {
        final meta = await client.fetchMeta(projectId: projectId);
        if (meta.currentVersionId.isEmpty ||
            meta.currentVersionId == lastVersion) {
          continue;
        }
        _logger.info('New version ${meta.currentVersionId} - pulling.');
        lastVersion = await pullLatest();
      } on CliException catch (e) {
        _logger.warn('${e.message} (retrying next cycle)');
      } on FileSystemException catch (e) {
        _logger.warn('${e.message} (retrying next cycle)');
      }
    }
    return 0;
  }

  /// One pull: fetch, write atomically, record state. Returns the pulled
  /// version id.
  Future<String> _pullOnce({
    required TranslationsApiClient client,
    required Easyi18nConfig config,
    required String projectId,
    required String configPath,
    required String? version,
    required String? lang,
    required bool dryRun,
  }) async {
    final pulled = await client.fetchTranslations(
      projectId: projectId,
      format: config.format,
      version: version,
      lang: lang,
    );

    if (pulled.files.isEmpty) {
      throw CliException(
        'The backend returned no files for format "${config.format}". '
        'Is that format configured for the project?',
      );
    }

    final outputDir = p.normalize(p.join(p.dirname(configPath), config.output));
    final fullPull = lang == null;

    _logger.info(
      '${dryRun ? 'Would pull' : 'Pulled'} ${pulled.files.length} file(s) '
      'for ${config.describeRef} (version ${pulled.version}) into $outputDir',
    );

    // Resolve and guard every path up front, so a bad key aborts the pull
    // before anything is pruned or written.
    final entries = <({String relPath, String stripped, String target})>[];
    for (final relPath in pulled.files.keys.toList()..sort()) {
      final stripped = _stripFormatPrefix(relPath, config.format);
      // The file keys come from the backend; a traversing or absolute key
      // (`../`, `/etc/...`) must never write outside the output directory.
      final target = _resolveWithin(outputDir, stripped);
      if (target == null) {
        throw CliException(
          'Refusing to write "$relPath": resolves outside $outputDir.',
        );
      }
      entries.add((relPath: relPath, stripped: stripped, target: target));
    }
    final written = {for (final e in entries) e.stripped};

    final stateFile = CliState.fileFor(configPath);
    final previous = CliState.load(stateFile);
    // Recorded paths only mean something under the format + output dir they
    // were written into — after a switch they must never be pruned.
    final sameTarget =
        previous.format == config.format &&
        previous.output != null &&
        p.normalize(previous.output!) == p.normalize(config.output);
    if (fullPull && sameTarget) {
      _prune(previous.files ?? const [], written, outputDir, dryRun: dryRun);
    }

    for (final e in entries) {
      if (dryRun) {
        _logger.detail(e.stripped);
        continue;
      }
      final file = File(e.target);
      file.parent.createSync(recursive: true);
      // Write to a sibling temp file then atomically rename, so a mid-write
      // failure can't leave a half-written (un-`gen-l10n`-able) .arb in place.
      final tmp = File('${e.target}.tmp');
      tmp.writeAsStringSync(pulled.files[e.relPath]!);
      tmp.renameSync(e.target);
      _logger.detail(e.stripped);
    }

    if (!dryRun) {
      if (fullPull && previous.files == null) {
        _hintLeftovers(outputDir, written);
      } else if (fullPull && !sameTarget && previous.files != null) {
        _hintSwitchedTarget(configPath, previous);
      }
      // Record what now sits on disk for `status` and the next pull's prune.
      // Best-effort: a cache write must never fail a successful pull.
      final recorded = fullPull || !sameTarget
          ? written
          : {...?previous.files, ...written};
      try {
        CliState(
          version: pulled.version,
          pulledAt: DateTime.now().toUtc(),
          format: config.format,
          output: config.output,
          files: recorded.toList()..sort(),
        ).save(stateFile);
      } on FileSystemException {
        _logger.detail(
          'Could not write ${CliState.dirName}/${CliState.fileName}.',
        );
      }
      _logger.info("Run 'flutter gen-l10n' to regenerate your localizations.");
    }
    return pulled.version;
  }

  /// Removes what the previous pull wrote (the caller checks it targeted the
  /// same format + output dir) and this one no longer serves — typically a
  /// locale renamed to its platform-canonical filename. Runs BEFORE writing:
  /// on a case-insensitive filesystem (APFS) deleting the old `zh-hant.json`
  /// after writing `zh-Hant.json` would hit the same directory entry and
  /// destroy the fresh file.
  void _prune(
    List<String> recorded,
    Set<String> written,
    String outputDir, {
    required bool dryRun,
  }) {
    var pruned = 0;
    for (final rel in recorded) {
      if (written.contains(rel)) continue;
      // Recorded by us, but never trust a state file to escape the dir.
      final target = _resolveWithin(outputDir, rel);
      if (target == null) continue;
      final file = File(target);
      // A pull that crashed mid-write strands `<file>.tmp`; sweep it along.
      final tmp = File('$target.tmp');
      if (!file.existsSync() && !tmp.existsSync()) continue;
      pruned++;
      if (dryRun) {
        _logger.detail('Would remove stale $rel');
        continue;
      }
      if (tmp.existsSync()) tmp.deleteSync();
      if (file.existsSync()) file.deleteSync();
      _logger.detail('Removed stale $rel');
      _dropEmptiedDirs(file.parent, outputDir);
    }
    if (pruned > 0) {
      _logger.info(
        '${dryRun ? 'Would remove' : 'Removed'} $pruned stale file(s) '
        'from the previous pull.',
      );
    }
  }

  /// Deletes the dirs a pruned file leaves behind (`zh-hant.lproj/`), walking
  /// up to [outputDir]. Finder droppings (`.DS_Store`) don't keep a dir alive.
  void _dropEmptiedDirs(Directory dir, String outputDir) {
    while (p.isWithin(outputDir, dir.path)) {
      final entries = dir.listSync();
      final droppings = entries
          .where((e) => p.basename(e.path) == '.DS_Store')
          .toList();
      if (droppings.length != entries.length) return;
      for (final dropping in droppings) {
        dropping.deleteSync();
      }
      dir.deleteSync();
      dir = dir.parent;
    }
  }

  /// Resolves [rel] under [outputDir], or null when it escapes it — the
  /// single containment rule for both the write and the delete paths.
  static String? _resolveWithin(String outputDir, String rel) {
    final target = p.normalize(p.join(outputDir, rel));
    return p.isWithin(outputDir, target) ? target : null;
  }

  /// A format or output-dir switch strands the previous pull's outputs (their
  /// records no longer match this pull's target, so they can never be
  /// pruned). Surface the ones still on disk instead of leaving them behind
  /// silently — this is the last pull that still has their record.
  void _hintSwitchedTarget(String configPath, CliState previous) {
    final prevOutput = previous.output;
    if (prevOutput == null) return;
    final prevDir = p.normalize(p.join(p.dirname(configPath), prevOutput));
    final stranded = <String>[];
    for (final rel in previous.files ?? const <String>[]) {
      final target = _resolveWithin(prevDir, rel);
      if (target != null && File(target).existsSync()) stranded.add(rel);
    }
    if (stranded.isEmpty) return;
    stranded.sort();
    _logger.info(
      'The previous ${previous.format ?? 'unknown'}-format pull left '
      '${stranded.length} file(s) in $prevDir that this pull no longer '
      'manages: ${stranded.join(', ')}. Remove them if stale.',
    );
  }

  /// First pull that records its file list (older CLIs kept none): surface
  /// files in the output dir it cannot attribute — e.g. a pre-canonical
  /// `app_zh-hant.arb` — since without a recorded list nothing can be pruned
  /// safely. One-shot by construction: after this pull the list exists.
  void _hintLeftovers(String outputDir, Set<String> written) {
    final root = Directory(outputDir);
    if (!root.existsSync()) return;
    final extensions = written
        .map(p.extension)
        .where((e) => e.isNotEmpty)
        .toSet();
    // Case-insensitive: on APFS the fresh file can surface under a previous
    // pull's directory-entry casing.
    final writtenLower = written.map((w) => w.toLowerCase()).toSet();
    final leftovers =
        root
            .listSync(recursive: true)
            .whereType<File>()
            .map((f) => p.split(p.relative(f.path, from: outputDir)).join('/'))
            .where(
              (rel) =>
                  extensions.contains(p.extension(rel)) &&
                  !writtenLower.contains(rel.toLowerCase()),
            )
            .toList()
          ..sort();
    if (leftovers.isEmpty) return;
    _logger.info(
      'Not written by this pull: ${leftovers.join(', ')}. '
      'Remove them if stale; from now on pull tracks and cleans its own files.',
    );
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
