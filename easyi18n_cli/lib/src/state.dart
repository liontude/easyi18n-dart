import 'dart:convert';
import 'dart:io';

/// Derived local state: what the last `pull` actually wrote to disk. Kept in
/// `.easyi18n/state.json` next to the config — deliberately SEPARATE from
/// `easyi18n.yaml` (the config is user intent, this is derived; add the
/// `.easyi18n/` dir to your VCS ignore). Read by `easyi18n status` to compare
/// against the server's current version.
class CliState {
  const CliState({this.version, this.pulledAt});

  /// Publish version id of the last pull (`YYYY.MM.DD.N`, or the legacy
  /// `YYYY.MM.DD` form for pre-counter servers).
  final String? version;

  /// When that pull happened (UTC).
  final DateTime? pulledAt;

  static const String dirName = '.easyi18n';
  static const String fileName = 'state.json';

  /// The state file that belongs to the config at [configPath].
  static File fileFor(String configPath) => File(
    '${File(configPath).parent.path}${Platform.pathSeparator}$dirName${Platform.pathSeparator}$fileName',
  );

  /// Loads the state, tolerating a missing or corrupt file (→ empty state —
  /// it's a cache, never worth failing a command over).
  static CliState load(File file) {
    if (!file.existsSync()) return const CliState();
    try {
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map) return const CliState();
      final at = raw['pulledAt'];
      return CliState(
        version: raw['version'] as String?,
        pulledAt: at is String ? DateTime.tryParse(at) : null,
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
      }),
    );
  }
}

/// Parses a publish version id (`YYYY.MM.DD.N`, legacy `YYYY.MM.DD` = `.1`)
/// into a comparable (date, n) pair, or null. Local mini-parser — the CLI is a
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
