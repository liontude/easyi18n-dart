import 'dart:io';

import 'package:yaml/yaml.dart';

import 'exceptions.dart';

/// Project config read from `easyi18n.yaml` at the repo root. Holds everything
/// `pull` needs except the credential — the token is never persisted to disk
/// (it comes from `EASYI18N_TOKEN` or `--token`).
class Easyi18nConfig {
  Easyi18nConfig({
    required this.projectId,
    String? baseUrl,
    String? format,
    String? output,
  }) : baseUrl = _normalizeBaseUrl(baseUrl ?? defaultBaseUrl),
       format = format ?? defaultFormat,
       output = output ?? defaultOutput;

  /// The project to pull translations for. Required.
  final String projectId;

  /// Backend origin. Defaults to production; override for the local emulator.
  final String baseUrl;

  /// Output format id rendered by the backend (`arb`, `json`, `po`, ...).
  final String format;

  /// Directory the rendered files are written into, relative to the config
  /// file. For Mode A this is the `arb-dir` from your `l10n.yaml`.
  final String output;

  static const String fileName = 'easyi18n.yaml';
  static const String defaultBaseUrl = 'https://api.easyi18n.com';
  static const String defaultFormat = 'arb';
  static const String defaultOutput = 'lib/l10n';

  /// Loads and validates the config from [file], throwing [CliException] with
  /// an actionable message on any problem.
  static Easyi18nConfig load(File file) {
    if (!file.existsSync()) {
      throw CliException(
        'No ${Easyi18nConfig.fileName} found at ${file.path}.\n'
        "Run 'easyi18n init' to create one.",
      );
    }

    final dynamic parsed;
    try {
      parsed = loadYaml(file.readAsStringSync());
    } on YamlException catch (e) {
      throw CliException('Invalid YAML in ${file.path}: ${e.message}');
    }
    if (parsed is! Map) {
      throw CliException('${file.path} must be a YAML map of settings.');
    }

    final projectId = _readString(parsed, 'projectId')?.trim();
    if (projectId == null || projectId.isEmpty) {
      throw CliException("${file.path} is missing required 'projectId'.");
    }

    return Easyi18nConfig(
      projectId: projectId,
      baseUrl: _readString(parsed, 'baseUrl')?.trim(),
      format: _readString(parsed, 'format')?.trim(),
      output: _readString(parsed, 'output')?.trim(),
    );
  }

  /// Serializes to YAML with explanatory comments. Deliberately hand-written
  /// (no token, stable key order) so generated configs stay reviewable.
  String toYaml() =>
      '''
# easyi18n CLI config (Mode A — native .arb).
# Docs: https://github.com/easyi18n/easyi18n-dart

# The project to pull translations for.
projectId: $projectId

# Backend origin. Override with http://localhost:8080 for the local emulator.
baseUrl: $baseUrl

# Output format rendered by the backend (arb, json, nested_json, po, ...).
format: $format

# Where the rendered files are written (your l10n.yaml arb-dir for Mode A).
output: $output
''';

  static String? _readString(Map map, String key) {
    final value = map[key];
    if (value == null) return null;
    if (value is String) return value;
    throw CliException(
      "'$key' must be a string in ${Easyi18nConfig.fileName}.",
    );
  }

  static String _normalizeBaseUrl(String raw) =>
      raw.replaceAll(RegExp(r'/+$'), '');
}
