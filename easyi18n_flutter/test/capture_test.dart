import 'dart:convert';

import 'package:easyi18n/src/contract/i18n/text_hash.dart';
import 'package:easyi18n/src/contract/models/bundle.dart';
import 'package:easyi18n/src/contract/models/translation_value.dart';
import 'package:easyi18n/src/delivery/bundle_store.dart';
import 'package:easyi18n/src/delivery/capture_reporter.dart';
import 'package:easyi18n/src/delivery/cdn_client.dart';
import 'package:easyi18n/src/delivery/delivery_service.dart';
import 'package:easyi18n/src/flutter/controller.dart';
import 'package:easyi18n/src/resolver/bundle_stack.dart';
import 'package:easyi18n/src/resolver/message_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('CaptureReporter', () {
    test('dedups per session, posts one authenticated batch on flush',
        () async {
      final bodies = <String>[];
      String? authHeader;
      final reporter = CaptureReporter(
        endpoint: Uri.parse('https://x/v1/projects/p/capture'),
        token: 'eik_dev',
        client: MockClient((req) async {
          bodies.add(req.body);
          authHeader = req.headers['authorization'];
          return http.Response('{}', 200);
        }),
        flushInterval: const Duration(hours: 1), // flush manually
      );

      reporter.record('Alpha', null);
      reporter.record('Alpha', null); // duplicate → ignored
      reporter.record('Open', 'verb');
      await reporter.flush();

      expect(bodies, hasLength(1));
      expect(authHeader, 'Bearer eik_dev');
      final units = ((jsonDecode(bodies.single) as Map)['units'] as List)
          .cast<Map<String, dynamic>>();
      expect(units, hasLength(2));
      expect(units.map((u) => u['source']), containsAll(['Alpha', 'Open']));
      final open = units.firstWhere((u) => u['source'] == 'Open');
      expect(open['ctx'], 'verb');
    });

    test('a swallowed POST error does not throw', () async {
      final reporter = CaptureReporter(
        endpoint: Uri.parse('https://x/v1/projects/p/capture'),
        token: 'eik_dev',
        client: MockClient((req) async => throw Exception('network down')),
        flushInterval: const Duration(hours: 1),
      );
      reporter.record('Z', null);
      await reporter.flush(); // must not rethrow
    });

    test('flushes automatically when the batch hits maxBatch', () async {
      var posts = 0;
      final reporter = CaptureReporter(
        endpoint: Uri.parse('https://x/v1/projects/p/capture'),
        token: 'eik_dev',
        client: MockClient((req) async {
          posts++;
          return http.Response('{}', 200);
        }),
        flushInterval: const Duration(hours: 1),
        maxBatch: 2,
      );
      reporter.record('a', null);
      reporter.record('b', null); // hits maxBatch → auto-flush
      await Future<void>.delayed(Duration.zero);
      expect(posts, 1);
    });
  });

  group('resolver onMiss', () {
    test('fires on a raw fallback, not on a hit', () {
      const resolver = MessageResolver();
      final token = messageTokenForValue(const TranslationText('Hi'));
      final stack = BundleStack(
        hot: Bundle.compute(
          locale: 'es',
          messages: {'g': 'Hola'},
          tokenIndex: {token: 'g'},
        ),
      );

      var misses = 0;
      resolver.resolve(
          source: 'Hi', locale: 'es', stack: stack, onMiss: () => misses++);
      expect(misses, 0, reason: 'a hit must not report a miss');

      resolver.resolve(
          source: 'Unknown', locale: 'es', stack: stack, onMiss: () => misses++);
      expect(misses, 1, reason: 'a raw fallback must report a miss');
    });
  });

  group('controller → capture', () {
    test('a missed tr() is reported to the capture endpoint', () async {
      String? captureBody;
      final reporter = CaptureReporter(
        endpoint: buildCaptureUrl(Uri.parse('https://x'), 'p'),
        token: 'eik_dev',
        client: MockClient((req) async {
          captureBody = req.body;
          return http.Response('{}', 200);
        }),
        flushInterval: const Duration(hours: 1),
      );
      final controller = Easyi18nController(
        supportedLocales: const ['es'],
        capture: reporter,
        delivery: DeliveryService(
          client: CdnClient(
              MockClient((req) async => http.Response('', 404))),
          store: InMemoryBundleStore(),
          manifestUrl: Uri.parse('https://x/v1/projects/p/manifest'),
        ),
      );

      // No bundles loaded → raw fallback → miss recorded.
      controller.resolve(source: 'Fresh source', locale: 'es');
      await reporter.flush();

      expect(captureBody, isNotNull);
      final units = (jsonDecode(captureBody!) as Map)['units'] as List;
      expect(units.map((u) => (u as Map)['source']), contains('Fresh source'));

      controller.dispose();
    });
  });
}
