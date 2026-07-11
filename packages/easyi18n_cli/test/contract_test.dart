import 'dart:convert';
import 'dart:io';

import 'package:easyi18n_cli/src/contract.dart';
import 'package:test/test.dart';

/// The CLI's text-path token contract must be byte-exact with the runtime SDK
/// and the backend. `contract_vectors.json` is copied verbatim from
/// `packages/easyi18n/lib/src/contract/contract_vectors.json` — never edit it
/// here; re-copy it if the (frozen) contract ever gains vectors.
void main() {
  final raw =
      jsonDecode(File('test/contract_vectors.json').readAsStringSync())
          as Map<String, dynamic>;

  test('algo version matches the vectors file', () {
    expect(kMessageTokenAlgoVersion, raw['messageTokenAlgo']);
  });

  group('text vectors', () {
    final vectors = (raw['tokens'] as List).cast<Map<String, dynamic>>().where(
      (v) => v['kind'] == 'text',
    );
    // Only the text vectors apply: the CLI has no plural path (statically
    // extracted tr() sources are always text).
    test('the file still has text vectors', () {
      expect(vectors, isNotEmpty);
    });

    for (final v in vectors) {
      test(v['name'] as String, () {
        final source = v['source'] as String;
        final ctx = v['ctx'] as String?;
        expect(canonicalizeSource(source), v['canonical']);
        expect(messageTokenForText(source, ctx: ctx), v['token']);
      });
    }
  });

  group('canonicalizeCtx', () {
    test('null, empty and whitespace-only collapse to no-ctx', () {
      expect(canonicalizeCtx(null), '');
      expect(canonicalizeCtx(''), '');
      expect(canonicalizeCtx('   '), '');
      expect(
        messageTokenForText('Open', ctx: '  '),
        messageTokenForText('Open'),
      );
    });

    test('rejects control characters', () {
      expect(() => canonicalizeCtx('a\x00b'), throwsArgumentError);
    });
  });

  test('canonicalization: CRLF, NFC and outer trim', () {
    expect(canonicalizeSource('  a\r\nb\r'), 'a\nb');
    // e + combining acute → precomposed é.
    expect(canonicalizeSource('café'), 'café');
  });
}
