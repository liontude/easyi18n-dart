import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../api_client.dart';
import '../config.dart';
import '../exceptions.dart';
import '../extract/extraction_report.dart';
import '../extract/source_unit.dart';
import '../extract/tr_extractor.dart';
import '../lockfile.dart';
import '../logger.dart';

/// Builds the API client `push` talks to. Injected so tests can swap in a
/// `MockClient`-backed instance.
typedef ApiClientFactory =
    TranslationsApiClient Function({
      required String baseUrl,
      required String token,
    });

/// Asks the user to confirm an action; returns true to proceed. Injected so
/// tests don't block on stdin.
typedef Confirm = bool Function(String prompt);

/// The most units one translate request accepts (matches the backend cap).
const int _maxUnitsPerBatch = 500;

/// `easyi18n push` — statically extract `tr()` sources from the source tree,
/// diff them against the lockfile, then register and translate them via the
/// authenticated backend. Interactive by default with a cost preview; `--yes`
/// for CI, `--dry-run` to only estimate, `--max-credits` to cap the spend.
class PushCommand extends Command<int> {
  PushCommand({
    required Logger logger,
    ApiClientFactory? apiClientFactory,
    TrExtractor? extractor,
    Map<String, String>? environment,
    Confirm? confirm,
  }) : _logger = logger,
       _apiClientFactory = apiClientFactory ?? _defaultFactory,
       _extractor = extractor ?? TrExtractor(),
       _environment = environment ?? Platform.environment,
       _confirm = confirm ?? _stdinConfirm {
    argParser
      ..addOption(
        'token',
        help:
            'API key (eik_) with the translate scope. '
            'Defaults to \$EASYI18N_TOKEN.',
      )
      ..addOption(
        'source-dir',
        help: 'Directory to scan, relative to the config file.',
        defaultsTo: 'lib',
      )
      ..addMultiOption(
        'lang',
        help:
            'Restrict to these target languages (repeatable). '
            'Defaults to all of the project\'s languages.',
      )
      ..addOption(
        'max-credits',
        help: 'Abort if the estimate exceeds this many credits (CI guard).',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Estimate the cost without registering or translating anything.',
      )
      ..addFlag(
        'yes',
        abbr: 'y',
        negatable: false,
        help: 'Skip the confirmation prompt (for CI).',
      )
      ..addFlag(
        'prune',
        negatable: false,
        help:
            'Drop orphaned strings from the lockfile (never deletes '
            'translations).',
      );
  }

  final Logger _logger;
  final ApiClientFactory _apiClientFactory;
  final TrExtractor _extractor;
  final Map<String, String> _environment;
  final Confirm _confirm;

  static const String tokenEnvVar = 'EASYI18N_TOKEN';

  @override
  String get name => 'push';

  @override
  String get description =>
      'Extract tr() strings, register them, and trigger translation.';

  @override
  Future<int> run() async {
    final results = argResults!;
    final configPath =
        globalResults?['config'] as String? ?? Easyi18nConfig.fileName;
    final config = Easyi18nConfig.load(File(configPath));
    final root = p.dirname(configPath);

    final dryRun = results['dry-run'] as bool;
    final prune = results['prune'] as bool;
    final assumeYes = results['yes'] as bool;
    final langs = results['lang'] as List<String>;
    final maxCredits = _parseMaxCredits(results['max-credits'] as String?);

    // ---- 1. scan + diff (offline) ----
    final sourceDir = Directory(p.join(root, results['source-dir'] as String));
    final extraction = _extractor.extractFromDirectory(
      sourceDir,
      relativeTo: root,
    );
    final lockFile = File(p.join(root, Lockfile.fileName));
    final lock = Lockfile.loadOrEmpty(lockFile, project: config.projectId);
    final diff = lock.diff(extraction.units);
    reportExtraction(_logger, extraction, diff);

    if (extraction.units.isEmpty) {
      _logger.info('No extractable tr() strings found. Nothing to push.');
      return 0;
    }

    // ---- 2. resolve the credential ----
    final token =
        (results['token'] as String?)?.trim() ??
        _environment[tokenEnvVar]?.trim();
    if (token == null || token.isEmpty) {
      throw CliException(
        'No credential. Set $tokenEnvVar or pass --token.\n'
        'Create an API key in your project settings (needs the translate '
        'scope).',
      );
    }

    final client = _apiClientFactory(baseUrl: config.baseUrl, token: token);
    // Carry over unambiguous 1:1 copy-edits so the backend keeps the existing
    // key (cheap outdated cascade) instead of orphaning it and minting a new one.
    final renames = diff.renamePairs();
    final units = [
      for (final u in extraction.units)
        TranslateUnit(
          source: u.source,
          ctx: u.ctx,
          previousSource: renames[u.identity]?.source,
          previousCtx: renames[u.identity]?.ctx,
        ),
    ];

    try {
      // ---- 3. cost preview (dry run, batched) ----
      final preview = await _run(
        client,
        config.projectId,
        units,
        langs,
        dryRun: true,
      );
      _logger.info(
        '${preview.unitsNeedingTranslation} string(s) need translation · '
        '~${preview.estimatedCredits} credit(s) (balance ${preview.balance}).',
      );

      if (maxCredits != null && preview.estimatedCredits > maxCredits) {
        throw CliException(
          'Estimate ${preview.estimatedCredits} exceeds --max-credits '
          '$maxCredits. Aborted.',
        );
      }

      // The real push enforces the plan key cap (402 `plan_limit`); surface it
      // here so an affordable-looking estimate doesn't preview as a green push.
      if (preview.wouldExceedKeyCap) {
        if (dryRun) {
          _logger.warn(
            "This push would exceed your plan's key limit for this project.",
          );
          return 1;
        }
        throw CliException(
          "This push would exceed your plan's key limit for this project. "
          'Upgrade your plan or remove unused keys, then retry.',
        );
      }

      if (dryRun) {
        _logger.info('Dry run — nothing registered or translated.');
        return preview.affordable ? 0 : 1;
      }

      if (preview.estimatedCredits == 0) {
        _logger.info('Everything is already translated.');
        _writeLock(lockFile, config.projectId, lock, extraction, prune);
        return 0;
      }

      if (!preview.affordable) {
        _logger.warn(
          'The estimate exceeds your balance; the push may stop partway when '
          'credits run out.',
        );
      }

      // ---- 4. confirm ----
      if (!assumeYes &&
          !_confirm(
            'Translate ${preview.unitsNeedingTranslation} string(s) '
            'for ~${preview.estimatedCredits} credit(s)? [y/N] ',
          )) {
        _logger.info('Aborted.');
        return 0;
      }

      // ---- 5. real push, batched ----
      final pushed = await _run(
        client,
        config.projectId,
        units,
        langs,
        dryRun: false,
        maxCredits: maxCredits,
      );
      _writeLock(lockFile, config.projectId, lock, extraction, prune);

      if (pushed.trackingTokens.isEmpty) {
        _logger.info('Registered. Nothing new to translate.');
      } else {
        _logger.info(
          'Pushed. Translating in the background '
          '(${pushed.trackingTokens.length} job(s)). '
          "Run 'easyi18n pull' once it completes.",
        );
      }
      return 0;
    } finally {
      client.close();
    }
  }

  /// Sends [units] in batches and aggregates the per-batch results into one
  /// view (summed credits + units, the balance from the last batch, accepted
  /// only if every batch was). Tracks each batch's job token for a real push.
  Future<_AggregateResult> _run(
    TranslationsApiClient client,
    String projectId,
    List<TranslateUnit> units,
    List<String> langs, {
    required bool dryRun,
    int? maxCredits,
  }) async {
    var estimated = 0;
    var balance = 0;
    var needing = 0;
    var wouldExceedKeyCap = false;
    final tokens = <String>[];
    for (var i = 0; i < units.length; i += _maxUnitsPerBatch) {
      final batch = units.sublist(
        i,
        i + _maxUnitsPerBatch > units.length
            ? units.length
            : i + _maxUnitsPerBatch,
      );
      final r = await client.translate(
        projectId: projectId,
        units: batch,
        langs: langs.isEmpty ? null : langs,
        dryRun: dryRun,
      );
      estimated += r.estimatedCredits;
      balance = r.balance;
      needing += r.unitsNeedingTranslation;
      if (r.wouldExceedKeyCap) wouldExceedKeyCap = true;
      if (r.trackingToken != null) tokens.add(r.trackingToken!);
      // Re-assert the ceiling against the running total on a real push: the
      // upfront check used the aggregate dry-run estimate, but stop before
      // spending further if the real per-batch charge has already exceeded it.
      if (!dryRun && maxCredits != null && estimated > maxCredits) {
        throw CliException(
          'Charged $estimated credit(s) across the completed batches, exceeding '
          '--max-credits $maxCredits. Stopped before the remaining batches.',
        );
      }
    }
    return _AggregateResult(
      estimatedCredits: estimated,
      balance: balance,
      unitsNeedingTranslation: needing,
      trackingTokens: tokens,
      wouldExceedKeyCap: wouldExceedKeyCap,
    );
  }

  /// Rebuilds the lockfile from the scan, keeping previously-registered orphans
  /// unless [prune] is set (translations on the backend are never touched).
  void _writeLock(
    File file,
    String project,
    Lockfile previous,
    ExtractionResult extraction,
    bool prune,
  ) {
    final units = <String, LockUnit>{};
    if (!prune) {
      for (final u in previous.units) {
        units[u.identity] = u;
      }
    }
    for (final u in extraction.units) {
      units[u.identity] = LockUnit(source: u.source, ctx: u.ctx);
    }
    Lockfile(project: project, units: units.values.toList()).write(file);
  }

  int? _parseMaxCredits(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final v = int.tryParse(raw.trim());
    if (v == null || v < 0) {
      throw CliException('--max-credits must be a non-negative integer.');
    }
    return v;
  }

  static TranslationsApiClient _defaultFactory({
    required String baseUrl,
    required String token,
  }) => TranslationsApiClient(baseUrl: baseUrl, token: token);

  static bool _stdinConfirm(String prompt) {
    stdout.write(prompt);
    final line = stdin.readLineSync()?.trim().toLowerCase();
    return line == 'y' || line == 'yes';
  }
}

/// Aggregated view across batched translate calls.
class _AggregateResult {
  _AggregateResult({
    required this.estimatedCredits,
    required this.balance,
    required this.unitsNeedingTranslation,
    required this.trackingTokens,
    required this.wouldExceedKeyCap,
  });

  final int estimatedCredits;
  final int balance;
  final int unitsNeedingTranslation;
  final List<String> trackingTokens;

  /// Dry-run only: any batch would push the project past its plan key cap.
  final bool wouldExceedKeyCap;

  bool get affordable => estimatedCredits <= balance;
}
