import 'dart:convert';

import 'package:easyi18n/easyi18n.dart';
import 'package:easyi18n/src/contract/i18n/text_hash.dart';
import 'package:easyi18n/src/contract/models/bundle.dart';
import 'package:easyi18n/src/contract/models/manifest.dart';
import 'package:easyi18n/src/contract/models/translation_value.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A controller whose delivery origin serves one `es` bundle translating
/// `Hello → Hola`, via an in-memory store + MockClient.
Easyi18nController buildController() {
  final token = messageTokenForValue(const TranslationText('Hello'));
  final bundle = Bundle.compute(
    locale: 'es',
    messages: {'greeting': 'Hola'},
    tokenIndex: {token: 'greeting'},
  );
  final manifest = Manifest(
    project: 'p',
    revision: 'r',
    locales: {
      'es': ManifestLocale(
        version: 'r',
        bundleHash: bundle.bundleHash,
        url: 'https://cdn/es.json',
      ),
    },
  );
  final client = MockClient((req) async {
    if (req.url.path.endsWith('manifest')) {
      return http.Response(jsonEncode(manifest.toJson()), 200,
          headers: {'etag': '"v1"'});
    }
    return http.Response(jsonEncode(bundle.toJson()), 200);
  });
  return Easyi18nController(
    supportedLocales: const ['en', 'es'],
    bakedLoader: (_) async => null,
    delivery: DeliveryService(
      client: CdnClient(client),
      store: InMemoryBundleStore(),
      manifestUrl: Uri.parse('https://x/v1/projects/p/manifest'),
    ),
  );
}

/// A bare `Localizations` (not `MaterialApp`) is enough for `context.tr`, which
/// only reads the ambient locale - and it sidesteps MaterialApp's delegate-
/// coverage warning for locales the default Material delegates don't ship.
Widget appWith(Easyi18nController controller, Locale locale) => Easyi18nScope(
      projectId: 'p',
      controller: controller,
      child: Localizations(
        locale: locale,
        delegates: const [DefaultWidgetsLocalizations.delegate],
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (context) => Text(context.tr('Hello')),
          ),
        ),
      ),
    );

void main() {
  testWidgets('raw source first, then hot-swap rebuilds in place',
      (tester) async {
    final controller = buildController();
    await tester.pumpWidget(appWith(controller, const Locale('es')));

    // Before any bundle lands, the raw (base-language) source shows.
    expect(find.text('Hello'), findsOneWidget);

    await controller.init();
    await tester.pump();

    // The hot bundle swapped in and the widget rebuilt via the notifier.
    expect(find.text('Hola'), findsOneWidget);
    expect(find.text('Hello'), findsNothing);

    controller.dispose();
  });

  testWidgets('locale with no translation falls back to the raw source',
      (tester) async {
    final controller = buildController();
    await tester.pumpWidget(appWith(controller, const Locale('en')));
    await controller.init();
    await tester.pump();

    // The manifest has no `en` bundle → raw source serves.
    expect(find.text('Hello'), findsOneWidget);
    controller.dispose();
  });
}
