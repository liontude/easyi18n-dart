import 'dart:convert';

import 'package:easyi18n/src/contract/models/bundle.dart';
import 'package:easyi18n/src/contract/models/manifest.dart';
import 'package:easyi18n/src/delivery/cdn_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Bundle esBundle() => Bundle.compute(
      locale: 'es',
      messages: {'greeting': 'Hola'},
      tokenIndex: {'tok': 'greeting'},
    );

void main() {
  final manifestUrl = Uri.parse('https://x/v1/projects/p/manifest');

  group('fetchManifest', () {
    test('200 → ManifestUpdated with parsed manifest + etag', () async {
      final bundle = esBundle();
      final manifest = Manifest(
        project: 'p',
        revision: '2026.01.01',
        locales: {
          'es': ManifestLocale(
              version: '2026.01.01',
              bundleHash: bundle.bundleHash,
              url: 'https://cdn/es.json'),
        },
      );
      final client = CdnClient(MockClient((req) async => http.Response(
            jsonEncode(manifest.toJson()),
            200,
            headers: {'etag': '"v1"'},
          )));
      final res = await client.fetchManifest(manifestUrl);
      expect(res, isA<ManifestUpdated>());
      res as ManifestUpdated;
      expect(res.etag, '"v1"');
      expect(res.manifest.locales['es']!.bundleHash, bundle.bundleHash);
    });

    test('304 → ManifestNotModified, and sends If-None-Match', () async {
      String? sentEtag;
      final client = CdnClient(MockClient((req) async {
        sentEtag = req.headers['if-none-match'];
        return http.Response('', 304);
      }));
      final res = await client.fetchManifest(manifestUrl, etag: '"v1"');
      expect(res, isA<ManifestNotModified>());
      expect(sentEtag, '"v1"');
    });

    test('non-200/304 → DeliveryException', () async {
      final client = CdnClient(MockClient((req) async => http.Response('x', 500)));
      expect(client.fetchManifest(manifestUrl),
          throwsA(isA<DeliveryException>()));
    });

    test('unknown tokenAlgoVersions → DeliveryException', () async {
      final manifest = Manifest(
        project: 'p',
        revision: 'r',
        tokenAlgoVersions: const ['m2'],
      );
      final client = CdnClient(MockClient(
          (req) async => http.Response(jsonEncode(manifest.toJson()), 200)));
      expect(client.fetchManifest(manifestUrl),
          throwsA(isA<DeliveryException>()));
    });
  });

  group('fetchBundle', () {
    final url = Uri.parse('https://cdn/es.json');

    test('200 + matching hash → Bundle', () async {
      final bundle = esBundle();
      final client = CdnClient(MockClient(
          (req) async => http.Response(jsonEncode(bundle.toJson()), 200)));
      final got = await client.fetchBundle(url,
          locale: 'es', expectedHash: bundle.bundleHash);
      expect(got.messages['greeting'], 'Hola');
    });

    test('hash mismatch → DeliveryException', () async {
      final bundle = esBundle();
      final client = CdnClient(MockClient(
          (req) async => http.Response(jsonEncode(bundle.toJson()), 200)));
      expect(
        client.fetchBundle(url, locale: 'es', expectedHash: 'deadbeef'),
        throwsA(isA<DeliveryException>()),
      );
    });

    test('future schemaVersion → DeliveryException', () async {
      final json = esBundle().toJson()..['schemaVersion'] = 999;
      final client = CdnClient(
          MockClient((req) async => http.Response(jsonEncode(json), 200)));
      expect(
        client.fetchBundle(url, locale: 'es', expectedHash: json['bundleHash'] as String),
        throwsA(isA<DeliveryException>()),
      );
    });

    test('non-200 → DeliveryException', () async {
      final client =
          CdnClient(MockClient((req) async => http.Response('', 404)));
      expect(
        client.fetchBundle(url, locale: 'es', expectedHash: 'x'),
        throwsA(isA<DeliveryException>()),
      );
    });
  });
}
