/// Content-only string hashing for source-as-key resolution.
///
/// Every unique string (whether it originated as a key source or as a
/// translation, in any language) hashes to one value. The hash is
/// **content-only**: it does NOT include the language/baseCode, so the same
/// text used as a source in one key and as a translation in another collapses
/// to a single identity. A string is a string.
///
/// The same algorithm runs on the backend (when interning) and the client
/// (for optimistic local resolution). Byte-exact agreement is what guarantees
/// the front never references a string the back stored under a different hash.
///
/// ```
/// textHash   = sha256("t|" + canonicalize(text))
/// pluralHash = sha256("p|" + canonicalPluralForms(forms))
/// ```
///
/// Notes:
/// - `canonicalize`: Unicode NFC + normalize line endings to `\n` + trim outer
///   whitespace. No lowercase. Internal whitespace and placeholders are NOT
///   touched. The canonical form is what gets STORED (not the raw input), so
///   `stored value == hashed value` - no "first writer wins" surprise.
/// - The `t|`/`p|` prefix keeps a one-form plural named `other` from colliding
///   with the equivalent non-plural string.
/// - Plural maps are serialized with keys sorted lexicographically so
///   `{one, other}` and `{other, one}` produce the same hash.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../models/translation_value.dart';
import 'icu_canonical.dart';

/// Hard cap on a single string value (source or translation), in characters.
/// These are UI strings, not documents - long content is split across keys.
const int kMaxStringLength = 10000;

/// Algorithm version baked into every [messageToken]. The version prefix lets a
/// future canonicalization change ship as `m2` with a dual index while `m1`
/// tokens stay valid; the manifest declares which versions it serves
/// (`tokenAlgoVersions`).
const String kMessageTokenAlgoVersion = 'm1';

/// Canonicalize a non-plural string: NFC, normalize line endings, trim outer
/// whitespace. Internal whitespace is preserved.
String canonicalizeSource(String source) {
  final lfNormalized = source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  return unorm.nfc(lfNormalized).trim();
}

/// Serialize a plural-forms map for hashing. Keys are sorted lexicographically;
/// each form is canonicalized; entries are joined with `\x1f` (unit separator)
/// so empty forms can't collide with adjacent ones.
String canonicalPluralForms(Map<String, String> forms) {
  final keys = forms.keys.toList()..sort();
  final buf = StringBuffer();
  for (var i = 0; i < keys.length; i++) {
    if (i > 0) buf.write('\x1f');
    final k = keys[i];
    buf
      ..write(k)
      ..write('\x1e') // record separator between key and value
      ..write(canonicalizeSource(forms[k] ?? ''));
  }
  return buf.toString();
}

/// Content-only hash for a non-plural string.
String stringHashForText(String text) => _sha256Hex('t|${canonicalizeSource(text)}');

/// Content-only hash for a plural string (whole form-set as one entry).
String stringHashForPlural(Map<String, String> forms) =>
    _sha256Hex('p|${canonicalPluralForms(forms)}');

/// Content-only hash for a [TranslationValue] (text or plural).
String stringHash(TranslationValue value) => switch (value) {
  TranslationText(:final text) => stringHashForText(text),
  TranslationPlural(:final forms) => stringHashForPlural(forms),
};

/// The canonical form of a [TranslationValue] - i.e. the value that should be
/// STORED in the pool so it matches what [stringHash] hashed.
TranslationValue canonicalizeValue(TranslationValue value) => switch (value) {
  TranslationText(:final text) => TranslationText(canonicalizeSource(text)),
  TranslationPlural(:final forms) => TranslationPlural({
    for (final e in forms.entries) e.key: canonicalizeSource(e.value),
  }),
};

/// Runtime **message token**: the source-as-key address the SDK uses to
/// resolve `tr(source)` to a token, then to its translated value.
///
/// `messageToken = sha256('<algo>|' + canonicalIcu + '\x1f' + ctx)` with
/// [kMessageTokenAlgoVersion] as the version prefix and `\x1f` (unit separator)
/// between the canonical body and the context. This is **separate from the
/// string pool** (`stringHashForText`/`stringHashForPlural`): adding `ctx` to
/// the pool hash would fork it and re-hash every stored string. The token is a
/// derived projection of content for the runtime; the durable identity is the
/// slug.
///
/// [canonicalIcu] must already be the canonical serialization (see
/// `canonicalIcu` in `icu_canonical.dart`). [ctx] is canonicalized here:
/// `null`/empty/whitespace-only ≡ no-ctx (all produce the same token).
String messageToken(String canonicalIcu, {String? ctx}) {
  final canonicalCtx = canonicalizeCtx(ctx);
  return _sha256Hex('$kMessageTokenAlgoVersion|$canonicalIcu\x1f$canonicalCtx');
}

/// Convenience: compute the [messageToken] for a [TranslationValue] directly,
/// canonicalizing it via `canonicalIcu` first.
String messageTokenForValue(TranslationValue value, {String? ctx}) =>
    messageToken(canonicalIcu(value), ctx: ctx);

String _sha256Hex(String input) {
  final digest = sha256.convert(utf8.encode(input));
  return digest.toString();
}
