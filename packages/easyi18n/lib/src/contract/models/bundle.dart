/// Vendored, flat copy of the core `Bundle` (translation-API contract). The
/// runtime needs `fromJson`, the fields, and `computeBundleHash`/
/// `canonicalJsonEncode` to verify a downloaded bundle's content address - but
/// NOT freezed/json_serializable codegen (which would force `build_runner` on
/// every consumer's `pub get`). The hashing logic is reproduced verbatim; the
/// golden vectors (`contract_vectors.json`) gate byte-parity with the backend.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Current bundle schema version. The SDK refuses bundles whose
/// [Bundle.schemaVersion] it does not understand.
const int kBundleSchemaVersion = 1;

/// A per-locale delivery bundle. **Slug-keyed** (`messages: {slug → ICU}`) plus
/// a small `{token → slug}` [tokenIndex] so the runtime resolves
/// `tr(source) → messageToken → slug → ICU`. [bundleHash] is the content
/// address (`bundles/{locale}/{bundleHash}.json`), excluded from its own
/// preimage. Build with [Bundle.compute] so the hash is always consistent.
class Bundle {
  const Bundle({
    this.schemaVersion = kBundleSchemaVersion,
    required this.locale,
    required this.bundleHash,
    this.messages = const {},
    this.tokenIndex = const {},
  });

  final int schemaVersion;
  final String locale;
  final String bundleHash;
  final Map<String, String> messages;
  final Map<String, String> tokenIndex;

  /// Build a bundle and compute its [bundleHash] from the content.
  factory Bundle.compute({
    required String locale,
    required Map<String, String> messages,
    required Map<String, String> tokenIndex,
    int schemaVersion = kBundleSchemaVersion,
  }) =>
      Bundle(
        schemaVersion: schemaVersion,
        locale: locale,
        bundleHash: computeBundleHash(
          schemaVersion: schemaVersion,
          locale: locale,
          messages: messages,
          tokenIndex: tokenIndex,
        ),
        messages: messages,
        tokenIndex: tokenIndex,
      );

  factory Bundle.fromJson(Map<String, dynamic> json) => Bundle(
        schemaVersion: (json['schemaVersion'] as num?)?.toInt() ??
            kBundleSchemaVersion,
        locale: json['locale'] as String,
        bundleHash: json['bundleHash'] as String,
        messages: (json['messages'] as Map?)?.cast<String, String>() ??
            const {},
        tokenIndex: (json['tokenIndex'] as Map?)?.cast<String, String>() ??
            const {},
      );

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'locale': locale,
        'bundleHash': bundleHash,
        'messages': messages,
        'tokenIndex': tokenIndex,
      };
}

/// Content hash of a bundle: `sha256` over the UTF-8 bytes of the **canonical
/// JSON** of `{schemaVersion, locale, messages, tokenIndex}` (the `bundleHash`
/// field itself is excluded). Must reproduce the backend's bytes exactly.
String computeBundleHash({
  required int schemaVersion,
  required String locale,
  required Map<String, String> messages,
  required Map<String, String> tokenIndex,
}) {
  final canonical = canonicalJsonEncode({
    'schemaVersion': schemaVersion,
    'locale': locale,
    'messages': messages,
    'tokenIndex': tokenIndex,
  });
  return sha256.convert(utf8.encode(canonical)).toString();
}

/// Deterministic JSON encoding: object keys sorted ascending, arrays preserved,
/// minified, UTF-8. The single source of byte-stability for [computeBundleHash].
String canonicalJsonEncode(Object? value) => jsonEncode(_sortDeep(value));

Object? _sortDeep(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k as String).toList()..sort();
    return {for (final k in keys) k: _sortDeep(value[k])};
  }
  if (value is Iterable) return [for (final e in value) _sortDeep(e)];
  return value;
}
