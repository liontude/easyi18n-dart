import 'dart:convert';
import 'dart:io';

/// Derived local state: what the last `pull` actually wrote to disk. Kept in
/// `.easyi18n/state.json` next to the config - deliberately SEPARATE from
/// `easyi18n.yaml` (the config is user intent, this is derived; add the
/// `.easyi18n/` dir to your VCS ignore). Read by `easyi18n status` (version
/// comparison) and by `pull` itself ([format]/[output]/[files] drive pruning).
class CliState {
  const CliState({
    this.version,
    this.pulledAt,
    this.format,
    this.output,
    this.files,
  });

  /// Publish version id of the last pull (`YYYY.MM.DD.N`, or the legacy
  /// `YYYY.MM.DD` form for pre-counter servers).
  final String? version;

  /// When that pull happened (UTC).
  final DateTime? pulledAt;

  /// Output format of the last pull. Scopes [files]: after a format switch
  /// the recorded list belongs to the old format and is never pruned against.
  final String? format;

  /// Config-relative output dir of the last pull. Scopes [files] like
  /// [format]: recorded paths are only meaningful under the dir they were
  /// written into, so a changed `output:` must never prune in the new dir.
  final String? output;

  /// Output-relative paths the last pull wrote. This is what a later full
  /// pull may safely remove when the server stops serving a path (e.g. a
  /// locale renamed to its platform-canonical filename). Null on state
  /// written by older CLIs — those prune nothing.
  final List<String>? files;

  static const String dirName = '.easyi18n';
  static const String fileName = 'state.json';

  /// The state file that belongs to the config at [configPath].
  static File fileFor(String configPath) => File(
    '${File(configPath).parent.path}${Platform.pathSeparator}$dirName${Platform.pathSeparator}$fileName',
  );

  /// Loads the state, tolerating a missing or corrupt file (→ empty state -
  /// it's a cache, never worth failing a command over).
  static CliState load(File file) {
    if (!file.existsSync()) return const CliState();
    try {
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map) return const CliState();
      final at = raw['pulledAt'];
      final version = raw['version'];
      final format = raw['format'];
      final output = raw['output'];
      final files = raw['files'];
      return CliState(
        version: version is String ? version : null,
        pulledAt: at is String ? DateTime.tryParse(at) : null,
        format: format is String ? format : null,
        output: output is String ? output : null,
        files: files is List ? files.whereType<String>().toList() : null,
      );
    } on FormatException {
      return const CliState();
    }
  }

  void save(File file) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        if (version != null) 'version': version,
        if (pulledAt != null) 'pulledAt': pulledAt!.toUtc().toIso8601String(),
        if (format != null) 'format': format,
        if (output != null) 'output': output,
        if (files != null) 'files': files,
      }),
    );
  }
}

/// Parses a publish version id (`YYYY.MM.DD.N`, legacy `YYYY.MM.DD` = `.1`)
/// into a comparable (date, n) pair, or null. Local mini-parser - the CLI is a
/// standalone package and doesn't depend on `easyi18n_core`.
({int date, int n})? parsePublishVersion(String raw) {
  final m = RegExp(
    r'^(\d{4})\.(\d{2})\.(\d{2})(?:\.(\d+))?$',
  ).firstMatch(raw.trim());
  if (m == null) return null;
  return (
    date: int.parse(m[1]!) * 10000 + int.parse(m[2]!) * 100 + int.parse(m[3]!),
    n: m[4] == null ? 1 : int.parse(m[4]!),
  );
}

/// Chronological comparison of two version ids; unparseable ids compare as
/// plain strings (deterministic, never throws).
int comparePublishVersions(String a, String b) {
  final pa = parsePublishVersion(a);
  final pb = parsePublishVersion(b);
  if (pa == null || pb == null) return a.compareTo(b);
  final byDate = pa.date.compareTo(pb.date);
  return byDate != 0 ? byDate : pa.n.compareTo(pb.n);
}
