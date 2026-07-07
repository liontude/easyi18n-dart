import 'dart:convert';

import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  TranslationsApiClient clientReturning(
    http.Response Function(http.Request) handler,
  ) => TranslationsApiClient(
    baseUrl: 'https://api.easyi18n.com',
    token: 'eik_secret',
    httpClient: MockClient((req) async => handler(req)),
  );

  test('sends bearer auth and parses the file map', () async {
    late http.Request captured;
    final client = clientReturning((req) {
      captured = req;
      return http.Response(
        jsonEncode({
          'project': 'proj_abc',
          'version': '2026.06.26',
          'baseCode': 'en',
          'formats': ['arb'],
          'files': {
            'arb/app_en.arb': '{"hi":"Hi"}',
            'arb/app_es.arb': '{"hi":"Hola"}',
          },
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final result = await client.fetchTranslations(
      projectId: 'proj_abc',
      format: 'arb',
    );

    expect(captured.headers['authorization'], 'Bearer eik_secret');
    expect(captured.url.path, '/v1/projects/proj_abc/translations');
    expect(captured.url.queryParameters['format'], 'arb');
    expect(result.version, '2026.06.26');
    expect(result.baseCode, 'en');
    expect(result.files, hasLength(2));
    expect(result.files['arb/app_es.arb'], '{"hi":"Hola"}');
  });

  test('forwards version and lang as query params', () async {
    late http.Request captured;
    final client = clientReturning((req) {
      captured = req;
      return http.Response(jsonEncode({'files': <String, String>{}}), 200);
    });

    await client.fetchTranslations(
      projectId: 'p',
      format: 'arb',
      version: '2026.01.01',
      lang: 'es',
    );

    expect(captured.url.queryParameters['version'], '2026.01.01');
    expect(captured.url.queryParameters['lang'], 'es');
  });

  test('omits empty version and lang', () async {
    late http.Request captured;
    final client = clientReturning((req) {
      captured = req;
      return http.Response(jsonEncode({'files': <String, String>{}}), 200);
    });

    await client.fetchTranslations(projectId: 'p', format: 'arb', version: '');

    expect(captured.url.queryParameters.containsKey('version'), isFalse);
    expect(captured.url.queryParameters.containsKey('lang'), isFalse);
  });

  test('surfaces the backend error message on 404', () async {
    final client = clientReturning(
      (req) => http.Response(
        jsonEncode({
          'error': 'not_published',
          'message': 'no published version',
        }),
        404,
      ),
    );

    expect(
      () => client.fetchTranslations(projectId: 'p', format: 'arb'),
      throwsA(
        isA<CliException>().having(
          (e) => e.message,
          'message',
          contains('no published version'),
        ),
      ),
    );
  });

  test('gives an auth hint on 401', () async {
    final client = clientReturning(
      (req) => http.Response(jsonEncode({'error': 'unauthorized'}), 401),
    );

    expect(
      () => client.fetchTranslations(projectId: 'p', format: 'arb'),
      throwsA(
        isA<CliException>().having(
          (e) => e.message,
          'message',
          contains('EASYI18N_TOKEN'),
        ),
      ),
    );
  });

  test('gives a credits hint on a 402 out-of-credits push', () async {
    final client = clientReturning(
      (req) => http.Response(
        jsonEncode({
          'error': 'insufficient_credits',
          'message': 'Not enough credits.',
        }),
        402,
      ),
    );

    expect(
      () => client.translate(
        projectId: 'p',
        units: [TranslateUnit(source: 'Hi')],
      ),
      throwsA(
        isA<CliException>().having(
          (e) => e.message,
          'message',
          contains('Top up'),
        ),
      ),
    );
  });

  test('omits the credits hint on a 402 plan_limit push', () async {
    final client = clientReturning(
      (req) => http.Response(
        jsonEncode({
          'error': 'plan_limit',
          'message': 'This plan allows up to 1000 keys. Upgrade for more.',
        }),
        402,
      ),
    );

    expect(
      () => client.translate(
        projectId: 'p',
        units: [TranslateUnit(source: 'Hi')],
      ),
      throwsA(
        isA<CliException>()
            .having((e) => e.message, 'message', contains('Upgrade for more'))
            .having(
              (e) => e.message,
              'no credits hint',
              isNot(contains('Top up')),
            ),
      ),
    );
  });

  test('handles a non-JSON error body', () async {
    final client = clientReturning((req) => http.Response('Bad Gateway', 502));

    expect(
      () => client.fetchTranslations(projectId: 'p', format: 'arb'),
      throwsA(
        isA<CliException>().having(
          (e) => e.message,
          'message',
          contains('502'),
        ),
      ),
    );
  });
}
