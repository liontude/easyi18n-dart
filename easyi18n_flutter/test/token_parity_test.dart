import 'dart:convert';
import 'dart:io';

import 'package:easyi18n/src/contract/i18n/text_hash.dart';
import 'package:easyi18n/src/contract/models/translation_value.dart';
import 'package:flutter_test/flutter_test.dart';

/// The single most load-bearing invariant of the runtime: the SDK must compute
/// the SAME `messageToken` for a source string as the backend did when it
/// registered that source — otherwise every `tr()` lookup misses and the app
/// silently shows untranslated text.
///
/// The backend tokenizes the source as **opaque text**
/// (`message_tokens.dart`: `messageTokenForValue(TranslationText(unit.source))`),
/// never parsing ICU. This test pins both halves:
///   • POSITIVE — source-as-text reproduces the golden token byte-for-byte.
///   • NEGATIVE — parsing an inline-ICU plural source produces a DIFFERENT
///     token, documenting the trap an SDK author must NOT fall into.
void main() {
  final vectors = jsonDecode(
    File('lib/src/contract/contract_vectors.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final tokens = (vectors['tokens'] as List).cast<Map<String, dynamic>>();

  group('positive: source-as-text matches the backend', () {
    for (final v in tokens.where((t) => t['kind'] == 'text')) {
      test(v['name'] as String, () {
        expect(
          messageTokenForValue(
            TranslationText(v['source'] as String),
            ctx: v['ctx'] as String?,
          ),
          v['token'],
        );
      });
    }
  });

  group('negative: the inline-ICU plural trap', () {
    test('hashing the source AS TEXT differs from parsing it as a plural', () {
      // A dev writes a plural inline with a non-canonical variable name (`num`,
      // not `count`) — the common case. Canonicalizing-as-plural would rename
      // the variable and re-space the body, changing the bytes; hashing the raw
      // text (what the backend does) does NOT.
      const inline = '{num, plural, one{cat} other{cats}}';

      // The SDK (and backend) hash this as opaque text:
      final asText = messageTokenForValue(const TranslationText(inline));
      // The WRONG thing — parsing into a TranslationPlural normalizes the var to
      // `count` (see icu_canonical) → canonical "{count, plural, …}":
      final asPlural = messageTokenForValue(
        const TranslationPlural({'one': 'cat', 'other': 'cats'}),
      );

      expect(asText, isNot(asPlural),
          reason: 'raw text vs canonical plural must diverge');

      // Pin the parsed side to the golden plural_basic token, so the trap is
      // concrete: that is the token the SDK would compute if it (wrongly) parsed.
      final pluralVector =
          tokens.firstWhere((t) => t['name'] == 'plural_basic');
      expect(asPlural, pluralVector['token']); // what parsing yields
      expect(asText, isNot(pluralVector['token'])); // what the SDK must use
    });

    test('a source written in exact canonical form coincides (harmless)', () {
      // If the dev happens to write the byte-exact canonical form, text- and
      // plural-hashing coincide — a harmless coincidence, not a contradiction:
      // the SDK still hashes as text and still matches the backend.
      const canonical = '{count, plural, one{cat} other{cats}}';
      expect(
        messageTokenForValue(const TranslationText(canonical)),
        messageTokenForValue(
          const TranslationPlural({'one': 'cat', 'other': 'cats'}),
        ),
      );
    });
  });
}
