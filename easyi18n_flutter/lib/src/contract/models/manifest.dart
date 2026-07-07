/// Vendored, flat copy of the core `Manifest`/`ManifestLocale` (translation-API
/// contract). The runtime only reads a manifest (`fromJson` + fields), so this
/// drops freezed/json_serializable.
library;

import '../i18n/text_hash.dart' show kMessageTokenAlgoVersion;

/// One locale entry in a [Manifest]: the join between the editorial version
/// (CalVer, [version]) and the delivery artifact ([bundleHash] → immutable URL).
class ManifestLocale {
  const ManifestLocale({
    required this.version,
    required this.bundleHash,
    required this.url,
  });

  final String version;
  final String bundleHash;
  final String url;

  factory ManifestLocale.fromJson(Map<String, dynamic> json) => ManifestLocale(
        version: json['version'] as String,
        bundleHash: json['bundleHash'] as String,
        url: json['url'] as String,
      );

  Map<String, dynamic> toJson() => {
        'version': version,
        'bundleHash': bundleHash,
        'url': url,
      };
}

/// The delivery manifest. A pointer per `(project, channel)`: each locale
/// carries `{version, bundleHash, url}`; the runtime compares `bundleHash` and
/// downloads the immutable bundle only when it changed.
///
/// [tokenAlgoVersions] declares which `messageToken` algorithm versions the
/// served bundles' `tokenIndex` keys use, so an SDK on a different algorithm
/// knows whether it can resolve source-as-key against this manifest.
class Manifest {
  const Manifest({
    required this.project,
    this.channel = 'production',
    required this.revision,
    this.tokenAlgoVersions = const [kMessageTokenAlgoVersion],
    this.locales = const {},
  });

  final String project;
  final String channel;
  final String revision;
  final List<String> tokenAlgoVersions;
  final Map<String, ManifestLocale> locales;

  factory Manifest.fromJson(Map<String, dynamic> json) => Manifest(
        project: json['project'] as String,
        channel: json['channel'] as String? ?? 'production',
        revision: json['revision'] as String,
        tokenAlgoVersions:
            (json['tokenAlgoVersions'] as List?)?.cast<String>() ??
                const [kMessageTokenAlgoVersion],
        locales: {
          for (final e in (json['locales'] as Map?)?.entries ??
              const <MapEntry<dynamic, dynamic>>[])
            e.key as String:
                ManifestLocale.fromJson((e.value as Map).cast<String, dynamic>()),
        },
      );

  Map<String, dynamic> toJson() => {
        'project': project,
        'channel': channel,
        'revision': revision,
        'tokenAlgoVersions': tokenAlgoVersions,
        'locales': {for (final e in locales.entries) e.key: e.value.toJson()},
      };
}
