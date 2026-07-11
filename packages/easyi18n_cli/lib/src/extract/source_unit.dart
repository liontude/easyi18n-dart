/// One statically-extracted `tr()` source string and its optional
/// disambiguation context, with the first location it was seen (for reporting).
class ExtractedUnit {
  ExtractedUnit({
    required this.source,
    this.ctx,
    required this.file,
    required this.line,
  });

  final String source;
  final String? ctx;
  final String file;
  final int line;

  /// Identity for diffing/dedup - a (source, ctx) pair. The length prefix makes
  /// it injective (no separator can collide with content), so two units with
  /// equal identity map to one backend token / managed key.
  String get identity => '${source.length}:$source:${ctx ?? ''}';
}

/// A `tr(...)` call whose source could not be read statically (a variable or an
/// interpolated string). It can't be registered ahead of time; it falls through
/// to the runtime auto-capture instead. Reported so the dev knows the gap.
class DynamicUnit {
  DynamicUnit({required this.file, required this.line, required this.snippet});

  final String file;
  final int line;
  final String snippet;
}

/// The outcome of scanning a directory tree for `tr()` calls.
class ExtractionResult {
  ExtractionResult({
    required this.units,
    required this.dynamics,
    required this.filesScanned,
    this.scopeFile,
  });

  /// Extractable units, deduped by (source, ctx) and sorted for stable output.
  final List<ExtractedUnit> units;

  /// Calls whose source is not a static literal.
  final List<DynamicUnit> dynamics;

  final int filesScanned;

  /// First file (relative path) where an `Easyi18nScope(...)` is constructed —
  /// AST-level, so a mention in a comment or string doesn't count. Null when
  /// the scope is not mounted in the scanned tree.
  final String? scopeFile;
}
