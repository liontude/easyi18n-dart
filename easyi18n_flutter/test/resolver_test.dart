import 'package:easyi18n/src/contract/i18n/text_hash.dart';
import 'package:easyi18n/src/contract/models/bundle.dart';
import 'package:easyi18n/src/contract/models/translation_value.dart';
import 'package:easyi18n/src/resolver/bundle_stack.dart';
import 'package:easyi18n/src/resolver/message_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

String tokenOf(String source, {String? ctx}) =>
    messageTokenForValue(TranslationText(source), ctx: ctx);

Bundle bundleWith({
  required String locale,
  required Map<String, String> messages,
  required Map<String, String> tokenIndex,
}) =>
    Bundle.compute(locale: locale, messages: messages, tokenIndex: tokenIndex);

void main() {
  const resolver = MessageResolver();

  test('resolves source → token → slug → message', () {
    final token = tokenOf('Hello');
    final stack = BundleStack(
      hot: bundleWith(
        locale: 'es',
        messages: {'greeting': 'Hola'},
        tokenIndex: {token: 'greeting'},
      ),
    );
    expect(
      resolver.resolve(source: 'Hello', locale: 'es', stack: stack),
      'Hola',
    );
  });

  test('interpolates args via MessageFormat', () {
    final token = tokenOf('Hi {name}');
    final stack = BundleStack(
      hot: bundleWith(
        locale: 'es',
        messages: {'hi': 'Hola {name}'},
        tokenIndex: {token: 'hi'},
      ),
    );
    expect(
      resolver.resolve(
        source: 'Hi {name}',
        locale: 'es',
        args: {'name': 'Leo'},
        stack: stack,
      ),
      'Hola Leo',
    );
  });

  test('ctx discriminates between two sources with the same text', () {
    final verb = tokenOf('Open', ctx: 'verb');
    final adj = tokenOf('Open', ctx: 'adjective');
    final stack = BundleStack(
      hot: bundleWith(
        locale: 'es',
        messages: {'open_verb': 'Abrir', 'open_adj': 'Abierto'},
        tokenIndex: {verb: 'open_verb', adj: 'open_adj'},
      ),
    );
    expect(
      resolver.resolve(source: 'Open', ctx: 'verb', locale: 'es', stack: stack),
      'Abrir',
    );
    expect(
      resolver.resolve(
          source: 'Open', ctx: 'adjective', locale: 'es', stack: stack),
      'Abierto',
    );
  });

  group('fallback chain', () {
    test('no bundle at all → raw source (rendered)', () {
      expect(
        resolver.resolve(
          source: 'Hi {name}',
          locale: 'es',
          args: {'name': 'Leo'},
          stack: const BundleStack(),
        ),
        'Hi Leo',
      );
    });

    test('token indexed but slug untranslated here → falls to next layer', () {
      final token = tokenOf('Bye');
      // hot knows the token but has no message for the slug in this locale;
      // baked (older) does → resolution must fall through, not stop at hot.
      final stack = BundleStack(
        hot: bundleWith(
          locale: 'es',
          messages: const {}, // untranslated in the hot layer
          tokenIndex: {token: 'farewell'},
        ),
        baked: bundleWith(
          locale: 'es',
          messages: {'farewell': 'Adiós'},
          tokenIndex: {token: 'farewell'},
        ),
      );
      expect(
        resolver.resolve(source: 'Bye', locale: 'es', stack: stack),
        'Adiós',
      );
    });

    test('token nowhere indexed → raw source', () {
      final stack = BundleStack(
        hot: bundleWith(
          locale: 'es',
          messages: {'other': 'X'},
          tokenIndex: {tokenOf('Something else'): 'other'},
        ),
      );
      expect(
        resolver.resolve(source: 'Untranslated', locale: 'es', stack: stack),
        'Untranslated',
      );
    });

    test('hot layer wins over baked when both translate the slug', () {
      final token = tokenOf('Save');
      final stack = BundleStack(
        hot: bundleWith(
          locale: 'es',
          messages: {'save': 'Guardar (nuevo)'},
          tokenIndex: {token: 'save'},
        ),
        baked: bundleWith(
          locale: 'es',
          messages: {'save': 'Guardar (viejo)'},
          tokenIndex: {token: 'save'},
        ),
      );
      expect(
        resolver.resolve(source: 'Save', locale: 'es', stack: stack),
        'Guardar (nuevo)',
      );
    });
  });
}
