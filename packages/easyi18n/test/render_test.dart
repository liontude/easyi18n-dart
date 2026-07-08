import 'package:easyi18n/src/contract/i18n/text_hash.dart';
import 'package:easyi18n/src/contract/models/bundle.dart';
import 'package:easyi18n/src/contract/models/translation_value.dart';
import 'package:easyi18n/src/resolver/bundle_stack.dart';
import 'package:easyi18n/src/resolver/message_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

/// The runtime must render the EXACT ICU shapes the backend serializer emits.
/// These are the patterns that land in `bundle.messages`; `intl`'s
/// [MessageFormat] resolves them at runtime.
void main() {
  const resolver = MessageResolver();

  BundleStack stackFor(String source, String pattern) {
    final token = messageTokenForValue(TranslationText(source));
    return BundleStack(
      hot: Bundle.compute(
        locale: 'en',
        messages: {'k': pattern},
        tokenIndex: {token: 'k'},
      ),
    );
  }

  test('plural selects the right form by count', () {
    // The exact ICU string the backend emits for an en plural.
    const pattern = '{count, plural, one{{count} item} other{{count} items}}';
    final stack = stackFor('items', pattern);

    expect(
      resolver.resolve(
          source: 'items', locale: 'en', args: {'count': 1}, stack: stack),
      '1 item',
    );
    expect(
      resolver.resolve(
          source: 'items', locale: 'en', args: {'count': 5}, stack: stack),
      '5 items',
    );
  });

  test('locale drives plural categories (pl: few vs many)', () {
    const pattern =
        '{count, plural, one{# plik} few{# pliki} many{# plików} other{# pliku}}';
    final stack = stackFor('files', pattern);

    String pl(int n) => resolver.resolve(
        source: 'files', locale: 'pl', args: {'count': n}, stack: stack);

    expect(pl(1), '1 plik'); // one
    expect(pl(3), '3 pliki'); // few
    expect(pl(5), '5 plików'); // many
  });

  test('plain placeholder text renders', () {
    final stack = stackFor('Welcome {name}', 'Bienvenido {name}');
    expect(
      resolver.resolve(
        source: 'Welcome {name}',
        locale: 'es',
        args: {'name': 'Leo'},
        stack: stack,
      ),
      'Bienvenido Leo',
    );
  });

  test('select renders the chosen branch', () {
    const pattern = '{gender, select, male{él} female{ella} other{elle}}';
    final stack = stackFor('they', pattern);
    expect(
      resolver.resolve(
          source: 'they', locale: 'es', args: {'gender': 'female'}, stack: stack),
      'ella',
    );
  });
}
