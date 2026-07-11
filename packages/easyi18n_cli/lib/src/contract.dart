/// Text-path slice of the cross-SDK `messageToken` contract.
///
/// The CLI never computes tokens to *register* strings (`push` sends raw
/// sources; the backend tokenizes). `doctor` however must answer "will
/// `tr(source)` resolve at runtime?", which is exactly a local token lookup
/// against the published bundle's `tokenIndex` — the same computation the
/// runtime SDK does. So this file duplicates the **frozen, normative** contract
/// (`easyi18n_core` → `i18n/text_hash.dart` + `icu_canonical.dart`), text path
/// only: statically extracted `tr()` sources are always plain text (plurals
/// are authored through other surfaces), so the plural serialization is not
/// needed here.
///
/// Byte-exact agreement is guarded by the golden `contract_vectors.json`
/// vectors (copied verbatim from the runtime SDK) in `test/contract_test.dart`.
/// Never "improve" the canonicalization here — a divergence silently breaks
/// every doctor verdict.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Algorithm version baked into every `messageToken`. A manifest declares the
/// versions its bundles serve (`tokenAlgoVersions`); doctor refuses to judge a
/// manifest it can't resolve against.
const String kMessageTokenAlgoVersion = 'm1';

/// Canonicalize a non-plural string: Unicode NFC, line endings normalized to
/// `\n`, outer whitespace trimmed. Internal whitespace and placeholders are
/// preserved verbatim. For a text value this IS the canonical ICU form.
String canonicalizeSource(String source) {
  final lfNormalized = source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  return unorm.nfc(lfNormalized).trim();
}

/// Canonicalize a context discriminator: NFC, outer-trim, case-preserved.
/// `null`, empty, and whitespace-only all collapse to `''` (≡ no-ctx). Throws
/// [ArgumentError] if the result contains a control character (C0 range or
/// DEL), which would corrupt the `\x1f`-separated token preimage.
String canonicalizeCtx(String? ctx) {
  if (ctx == null) return '';
  final normalized = canonicalizeSource(ctx);
  if (normalized.isEmpty) return '';
  for (final rune in normalized.runes) {
    if (rune <= 0x1F || rune == 0x7F) {
      throw ArgumentError.value(
        ctx,
        'ctx',
        'context must not contain control characters',
      );
    }
  }
  return normalized;
}

/// Runtime message token for a plain-text source:
/// `sha256('<algo>|' + canonicalizeSource(source) + '\x1f' + canonicalizeCtx(ctx))`.
String messageTokenForText(String source, {String? ctx}) {
  final preimage =
      '$kMessageTokenAlgoVersion|${canonicalizeSource(source)}'
      '\x1f${canonicalizeCtx(ctx)}';
  return sha256.convert(utf8.encode(preimage)).toString();
}

/// Bundle schema version this CLI understands (mirrors the runtime SDK, which
/// refuses bundles whose version it doesn't know).
const int kBundleSchemaVersion = 1;

/// Content hash of a bundle: sha256 over the canonical JSON of
/// `{schemaVersion, locale, messages, tokenIndex}` (the hash field itself is
/// excluded). Doctor recomputes it so a stale CDN object is caught the same
/// way the runtime SDK rejects it.
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

/// Deterministic JSON encoding: object keys sorted ascending, arrays kept in
/// order, minified. Byte-stability source for [computeBundleHash].
String canonicalJsonEncode(Object? value) => jsonEncode(_sortDeep(value));

Object? _sortDeep(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k as String).toList()..sort();
    return {for (final k in keys) k: _sortDeep(value[k])};
  }
  if (value is Iterable) return [for (final e in value) _sortDeep(e)];
  return value;
}
