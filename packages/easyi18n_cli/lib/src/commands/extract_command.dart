import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../config.dart';
import '../extract/extraction_report.dart';
import '../extract/tr_extractor.dart';
import '../lockfile.dart';
import '../logger.dart';

/// `easyi18n extract` - statically scan the source tree for `tr()` calls and
/// print what would be registered, what's new, and what's orphaned versus the
/// lockfile. Read-only and offline: it never writes the lockfile or contacts the
/// backend (that's `push`). Useful as a CI drift check or before a push.
class ExtractCommand extends Command<int> {
  ExtractCommand({required CliLogger logger, TrExtractor? extractor})
    : _logger = logger,
      _extractor = extractor ?? TrExtractor() {
    argParser
      ..addOption(
        'source-dir',
        help: 'Directory to scan, relative to the config file.',
        defaultsTo: 'lib',
      )
      ..addFlag(
        'fail-on-orphans',
        negatable: false,
        help: 'Exit non-zero if the lockfile has strings no longer in code.',
      );
  }

  final CliLogger _logger;
  final TrExtractor _extractor;

  @override
  String get name => 'extract';

  @override
  String get description =>
      'Scan the source tree for tr() strings and report against the lockfile.';

  @override
  Future<int> run() async {
    final results = argResults!;
    final configPath =
        globalResults?['config'] as String? ?? Easyi18nConfig.fileName;
    final config = Easyi18nConfig.load(File(configPath));
    final root = p.dirname(configPath);

    final sourceDir = Directory(p.join(root, results['source-dir'] as String));
    final extraction = _extractor.extractFromDirectory(
      sourceDir,
      relativeTo: root,
    );

    final lock = Lockfile.loadOrEmpty(
      File(p.join(root, Lockfile.fileName)),
      project: config.projectId,
    );
    final diff = lock.diff(extraction.units);
    reportExtraction(_logger, extraction, diff);

    if ((results['fail-on-orphans'] as bool) && diff.removed.isNotEmpty) {
      _logger.error('${diff.removed.length} orphan(s) found.');
      return 1;
    }
    return 0;
  }
}
