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
import '../resolve.dart';
import '../security.dart';

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

/// `--publish` poll cadence + ceiling: how often the fill is re-checked and
/// how long before giving up (the strings stay registered; publishing later
/// loses nothing).
const Duration _publishPollInterval = Duration(seconds: 5);
const Duration _publishPollTimeout = Duration(minutes: 10);

/// `easyi18n push` - statically extract `tr()` sources from the source tree,
/// diff them against the lockfile, then register and translate them via the
/// authenticated backend. Interactive by default with a cost preview; `--yes`
/// for CI, `--dry-run` to only estimate, `--max-credits` to cap the spend.
class PushCommand extends Command<int> {
  PushCommand({
    required CliLogger logger,
    ApiClientFactory? apiClientFactory,
    TrExtractor? extractor,
    Map<String, String>? environment,
    Confirm? confirm,
    Future<void> Function(Duration)? wait,
  }) : _logger = logger,
       _apiClientFactory = apiClientFactory ?? _defaultFactory,
       _extractor = extractor ?? TrExtractor(),
       _environment = environment ?? Platform.environment,
       _confirm = confirm ?? _stdinConfirm,
       _wait = wait ?? Future<void>.delayed {
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
      )
      ..addFlag(
        'publish',
        negatable: false,
        help:
            'After pushing, wait for the AI fill to complete and publish a '
            'new version (needs the publish scope).',
      )
      ..addFlag(
        'approved-only',
        negatable: false,
        help:
            'With --publish: treat unapproved translations as missing when '
            'publishing.',
      );
  }

  final CliLogger _logger;
  final ApiClientFactory _apiClientFactory;
  final TrExtractor _extractor;
  final Map<String, String> _environment;
  final Confirm _confirm;
  final Future<void> Function(Duration) _wait;

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
    final publish = results['publish'] as bool;
    final approvedOnly = results['approved-only'] as bool;
    if (approvedOnly && !publish) {
      throw CliException('--approved-only only makes sense with --publish.');
    }
    if (publish && dryRun) {
      throw CliException('--publish cannot be combined with --dry-run.');
    }

    // ---- 1. scan + diff (offline) ----
    final sourceDir = Directory(p.join(root, results['source-dir'] as String));
    final extraction = _extractor.extractFromDirectory(
      sourceDir,
      relativeTo: root,
    );
    final lockFile = File(p.join(root, Lockfile.fileName));
    // Inert seed: the diff ignores it and `_writeLock` writes the resolved id.
    // Keeping this offline (pre-resolve) lets a no-op push skip the credential.
    final lock = Lockfile.loadOrEmpty(lockFile, project: config.ref.lockSeed);
    final diff = lock.diff(extraction.units);
    reportExtraction(_logger, extraction, diff);

    if (extraction.units.isEmpty && !publish) {
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

    warnOnUntrustedTarget(config.baseUrl, _logger);

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
      final projectId = await resolveProjectId(config, client, logger: _logger);
      // Nothing to register: publish the state that's already on the server
      // (and never touch the lockfile - `--prune` would empty it).
      if (units.isEmpty) {
        _logger.info(
          'No extractable tr() strings found - publishing the current state.',
        );
        await _publish(client, projectId, approvedOnly);
        return 0;
      }

      // ---- 3. cost preview (dry run, batched) ----
      final preview = await _run(client, projectId, units, langs, dryRun: true);
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
        _logger.info('Dry run - nothing registered or translated.');
        return preview.affordable ? 0 : 1;
      }

      // A zero estimate means nothing NEW needs a fill - but langs left
      // in-flight by an earlier push are free and still untranslated, so
      // publishing here without waiting would bake base text (friction F2).
      if (preview.estimatedCredits == 0) {
        _logger.info(
          preview.unitsNeedingTranslation == 0
              ? 'Everything is already translated.'
              : '${preview.unitsNeedingTranslation} string(s) are still being '
                    'translated from an earlier push.',
        );
        _writeLock(lockFile, projectId, lock, extraction, prune);
        if (publish) {
          await _waitForFill(client, projectId, units, langs);
          await _publish(client, projectId, approvedOnly);
        } else if (preview.unitsNeedingTranslation > 0) {
          _logger.info("Run 'easyi18n pull' once it completes.");
        }
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
        projectId,
        units,
        langs,
        dryRun: false,
        maxCredits: maxCredits,
      );
      _writeLock(lockFile, projectId, lock, extraction, prune);

      if (pushed.trackingTokens.isEmpty) {
        _logger.info('Registered. Nothing new to translate.');
      } else {
        _logger.info(
          'Pushed. Translating in the background '
          '(${pushed.trackingTokens.length} job(s)).'
          '${publish ? '' : " Run 'easyi18n pull' once it completes."}',
        );
      }
      if (publish) {
        await _waitForFill(client, projectId, units, langs);
        await _publish(client, projectId, approvedOnly);
      }
      return 0;
    } finally {
      client.close();
    }
  }

  /// Polls the dry-run estimate until nothing needs translation - friction F2:
  /// publishing before the fill lands would bake base-language text into the
  /// target locales. Polls first, so a completed (or never-started) fill costs
  /// no wait at all.
  ///
  /// A poll that would COST credits is the terminal signal: an in-flight fill
  /// is free to re-estimate, so a priced lang is one that failed (or was never
  /// queued) and no amount of waiting will land it.
  Future<void> _waitForFill(
    TranslationsApiClient client,
    String projectId,
    List<TranslateUnit> units,
    List<String> langs,
  ) async {
    final deadline = DateTime.now().add(_publishPollTimeout);
    var announced = false;
    while (true) {
      final poll = await _run(client, projectId, units, langs, dryRun: true);
      if (poll.unitsNeedingTranslation == 0) {
        if (announced) _logger.info('Fill complete.');
        return;
      }
      if (poll.estimatedCredits > 0) {
        throw CliException(
          '${poll.unitsNeedingTranslation} string(s) did not translate - the '
          'fill failed, or your credits ran out. Nothing was published; '
          "re-run 'easyi18n push --publish' to retry them.",
        );
      }
      if (DateTime.now().isAfter(deadline)) {
        throw CliException(
          'The fill did not complete within '
          '${_publishPollTimeout.inMinutes} minutes '
          '(${poll.unitsNeedingTranslation} string(s) still pending). '
          "Nothing is lost - re-run 'easyi18n push --publish' later, or "
          'publish from the dashboard.',
        );
      }
      if (!announced) {
        _logger.info('Waiting for the AI fill to complete...');
        announced = true;
      }
      _logger.detail('${poll.unitsNeedingTranslation} string(s) pending...');
      await _wait(_publishPollInterval);
    }
  }

  Future<void> _publish(
    TranslationsApiClient client,
    String projectId,
    bool approvedOnly,
  ) async {
    final outcome = await client.publish(
      projectId: projectId,
      approvedOnly: approvedOnly,
    );
    _logger.info(
      'Published ${outcome.versionId} (${outcome.keyCount} key(s)). '
      'Live via delivery within one poll interval.',
    );
    // The ICU gate refused these cells — they shipped the incomplete-mode
    // fallback instead. Warn (not fail): the publish itself succeeded.
    if (outcome.icuRejected.isNotEmpty) {
      _logger.warn(
        '${outcome.icuRejected.length} translation(s) failed ICU validation '
        'and fell back to the incomplete mode:',
      );
      for (final entry in outcome.icuRejected) {
        _logger.warn('  $entry');
      }
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
