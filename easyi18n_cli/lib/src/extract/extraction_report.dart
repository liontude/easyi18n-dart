import '../lockfile.dart';
import '../logger.dart';
import 'source_unit.dart';

/// Prints the shared scan summary used by `extract` and `push`: how many
/// strings were found, what's new/orphaned versus the lockfile, and which calls
/// couldn't be read statically.
void reportExtraction(Logger log, ExtractionResult ex, LockfileDiff diff) {
  log.info(
    'Scanned ${ex.filesScanned} file(s): '
    '${ex.units.length} extractable tr() string(s).',
  );

  if (diff.added.isNotEmpty) {
    log.info('${diff.added.length} new since last push:');
    for (final u in diff.added) {
      log.detail('+ ${_fmt(u.source, u.ctx)}');
    }
  }

  if (diff.removed.isNotEmpty) {
    log.info(
      '${diff.removed.length} orphan(s) — in the lockfile but no longer in '
      'code (translations are kept; pass --prune to drop from the lockfile):',
    );
    for (final u in diff.removed) {
      log.detail('- ${_fmt(u.source, u.ctx)}');
    }
  }

  if (ex.dynamics.isNotEmpty) {
    log.warn(
      '${ex.dynamics.length} tr() call(s) with a non-literal source — these '
      'rely on runtime auto-capture, not static extraction:',
    );
    for (final d in ex.dynamics) {
      log.detail('${d.file}:${d.line}  ${d.snippet}');
    }
  }
}

String _fmt(String source, String? ctx) {
  final shown = source.length > 60 ? '${source.substring(0, 57)}...' : source;
  final suffix = (ctx != null && ctx.isNotEmpty) ? '  (ctx: $ctx)' : '';
  return '"$shown"$suffix';
}
