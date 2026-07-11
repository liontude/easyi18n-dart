import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/src/commands/doctor_command.dart';
import 'package:easyi18n_cli/src/contract.dart';
import 'package:easyi18n_cli/src/delivery.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('easyi18n_cli_doctor');
    out = StringBuffer();
    err = StringBuffer();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  String configPath() => '${dir.path}/easyi18n.yaml';
  File fileAt(String relative) =>
      File('${dir.path}/$relative')..createSync(recursive: true);

  // ----- fixture -------------------------------------------------------------

  /// A fully-initialized Flutter app fixture (what `init` leaves behind).
  void writeHealthyFixture({List<String> sources = const ['Hello']}) {
    fileAt('easyi18n.yaml').writeAsStringSync('''
projectId: proj_abc
baseUrl: http://localhost:9
''');
    fileAt('pubspec.yaml').writeAsStringSync('''
name: demo_app

dependencies:
  flutter:
    sdk: flutter
  easyi18n: ^0.1.0

flutter:
  assets:
    - assets/easyi18n/
''');
    Directory('${dir.path}/assets/easyi18n').createSync(recursive: true);
    final trCalls = [
      for (final s in sources)
        "      Text(context.tr('${s.replaceAll("'", r"\'")}')),",
    ].join('\n');
    fileAt('lib/main.dart').writeAsStringSync('''
import 'package:easyi18n/easyi18n.dart';
import 'package:flutter/material.dart';

void main() => runApp(
  Easyi18nScope(projectId: 'proj_abc', child: const MyApp()),
);

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => Column(children: [
$trCalls
  ]);
}
''');
    for (final name in ['DebugProfile.entitlements', 'Release.entitlements']) {
      fileAt('macos/Runner/$name').writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
\t<key>com.apple.security.app-sandbox</key>
\t<true/>
\t<key>com.apple.security.network.client</key>
\t<true/>
</dict>
</plist>
''');
    }
  }

  // ----- fake delivery -------------------------------------------------------

  /// Serves a manifest + bundles for `proj_abc`. Published state:
  /// - `Hello`   → slug `hello`, translated in es
  /// - `Pending` → slug `pending`, NOT translated in es
  /// - `Ghost string` → slug `ghost`, translated, never called from code
  MockClient fakeDelivery({
    bool cors = true,
    bool published = true,
    String corsValue = '*',
    bool corruptEs = false,
  }) {
    final tHello = messageTokenForText('Hello');
    final tPending = messageTokenForText('Pending');
    final tGhost = messageTokenForText('Ghost string');
    final tokenIndex = {tHello: 'hello', tPending: 'pending', tGhost: 'ghost'};
    Map<String, Object?> bundle(String locale, Map<String, String> messages) =>
        {
          'schemaVersion': 1,
          'locale': locale,
          'bundleHash': computeBundleHash(
            schemaVersion: 1,
            locale: locale,
            messages: messages,
            tokenIndex: tokenIndex,
          ),
          'messages': messages,
          'tokenIndex': tokenIndex,
        };
    final bundles = {
      'en': bundle('en', {
        'hello': 'Hello',
        'pending': 'Pending',
        'ghost': 'Ghost string',
      }),
      'es': bundle('es', {'hello': 'Hola', 'ghost': 'Fantasma'}),
    };
    if (corruptEs) {
      // Content no longer matches the advertised address (stale CDN object).
      (bundles['es']!['messages'] as Map<String, String>)['hello'] = 'HolaX';
    }

    return MockClient((request) async {
      final headers = {
        'content-type': 'application/json',
        if (cors) 'access-control-allow-origin': corsValue,
      };
      final path = request.url.path;
      if (path == '/v1/projects/proj_abc/manifest') {
        if (!published) {
          return http.Response(
            jsonEncode({
              'error': 'not_published',
              'message': 'project has no published version',
            }),
            404,
            headers: headers,
          );
        }
        return http.Response(
          jsonEncode({
            'project': 'proj_abc',
            'channel': 'production',
            'revision': '2026.07.09.1',
            'tokenAlgoVersions': ['m1'],
            'locales': {
              for (final e in bundles.entries)
                e.key: {
                  'version': '2026.07.09.1',
                  'bundleHash': e.value['bundleHash'],
                  'url':
                      '/v1/projects/proj_abc/bundles/${e.key}/'
                      '${e.value['bundleHash']}.json',
                },
            },
          }),
          200,
          headers: headers,
        );
      }
      final bundleMatch = RegExp(
        r'^/v1/projects/proj_abc/bundles/(\w+)/',
      ).firstMatch(path);
      if (bundleMatch != null) {
        final bundle = bundles[bundleMatch.group(1)];
        if (bundle != null) {
          return http.Response(jsonEncode(bundle), 200, headers: headers);
        }
      }
      return http.Response('not found', 404);
    });
  }

  Future<int?> runDoctor({
    MockClient? client,
    Map<String, String> environment = const {'EASYI18N_TOKEN': 'eik_test'},
  }) {
    final runner = CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
    runner.addCommand(
      DoctorCommand(
        logger: CliLogger(out: out, err: err),
        environment: environment,
        deliveryFactory: ({required String baseUrl}) => DeliveryClient(
          baseUrl: baseUrl,
          httpClient: client ?? fakeDelivery(),
        ),
      ),
    );
    return runner.run(['--config', configPath(), 'doctor']);
  }

  // ----- tests ---------------------------------------------------------------

  group('healthy project', () {
    test('all checks pass, exit 0', () async {
      writeHealthyFixture();
      final code = await runDoctor();
      final o = out.toString();
      expect(code, 0, reason: o);
      expect(o, contains('All checks passed.'));
      expect(o, contains('ok    credential'));
      expect(o, contains('easyi18n is a dependency'));
      expect(o, contains('offline floor dir present'));
      expect(o, contains('Easyi18nScope mounted'));
      expect(o, contains('revision 2026.07.09.1'));
      expect(o, contains('CORS allows browser fetches'));
      expect(o, contains('every tr() string is published'));
      // Ghost string is published but never called - informational only.
      expect(o, contains('info  scan - 2 published key(s) not referenced'));
      expect(o, isNot(contains('FAIL')));
    });
  });

  group('handle-ref config', () {
    test('probes the @handle/slug manifest with no auth header', () async {
      // Same fixture, but addressed by the legible ref.
      writeHealthyFixture();
      fileAt('easyi18n.yaml').writeAsStringSync('''
workspace: acme
project: dogfood
baseUrl: http://localhost:9
''');
      fileAt('lib/main.dart').writeAsStringSync('''
import 'package:easyi18n/easyi18n.dart';
import 'package:flutter/material.dart';

void main() => runApp(
  Easyi18nScope(workspace: 'acme', slug: 'dogfood', child: const MyApp()),
);

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => Column(children: [
      Text(context.tr('Hello')),
  ]);
}
''');

      String? manifestPath;
      String? manifestAuth;
      final base = fakeDelivery();
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/manifest')) {
          manifestPath = request.url.path;
          manifestAuth = request.headers['authorization'];
          // Rewrite the alias path to the id path the base fake serves; its
          // manifest advertises canonical (id-path) bundle URLs, so bundle
          // fetches below hit the id path the base already handles.
          final rewritten = request.url.replace(
            path: '/v1/projects/proj_abc/manifest',
          );
          return base.get(rewritten, headers: request.headers);
        }
        return base.get(request.url, headers: request.headers);
      });

      final code = await runDoctor(client: client);
      expect(manifestPath, '/v1/@acme/dogfood/manifest');
      expect(manifestAuth, isNull);
      expect(code, 0, reason: out.toString());
      expect(out.toString(), contains('project @acme/dogfood'));
    });
  });

  group('platform wiring', () {
    test(
      'flags an entitlements file missing network.client (spec §12 gate)',
      () async {
        writeHealthyFixture();
        fileAt('macos/Runner/Release.entitlements').writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
\t<key>com.apple.security.app-sandbox</key>
\t<true/>
</dict>
</plist>
''');
        final code = await runDoctor();
        final o = out.toString();
        expect(code, 1, reason: o);
        expect(
          o,
          contains(
            'FAIL  ${dir.path}/macos/Runner/Release.entitlements - '
            'com.apple.security.network.client missing',
          ),
        );
        // The debug one is still fine.
        expect(
          o,
          contains('ok    ${dir.path}/macos/Runner/DebugProfile.entitlements'),
        );
      },
    );

    test('flags an entitlement explicitly set to false, distinctly', () async {
      writeHealthyFixture();
      fileAt('macos/Runner/Release.entitlements').writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
\t<key>com.apple.security.network.client</key>
\t<false/>
</dict>
</plist>
''');
      final code = await runDoctor();
      expect(code, 1);
      expect(out.toString(), contains('explicitly <false/>'));
    });

    test(
      'a commented-out entitlement pair does not count as granted',
      () async {
        writeHealthyFixture();
        fileAt('macos/Runner/Release.entitlements').writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
\t<!-- <key>com.apple.security.network.client</key>
\t<true/> -->
</dict>
</plist>
''');
        final code = await runDoctor();
        expect(code, 1);
        expect(
          out.toString(),
          contains('com.apple.security.network.client missing'),
        );
      },
    );

    test('a scope mention in a comment does not count as mounted', () async {
      writeHealthyFixture();
      fileAt('lib/main.dart').writeAsStringSync('''
// TODO: re-add Easyi18nScope when ready
void main() => runApp(const MyApp());
''');
      final code = await runDoctor();
      expect(code, 1);
      expect(out.toString(), contains('Easyi18nScope not mounted'));
    });

    test('accepts an itemized asset entry under the floor dir', () async {
      writeHealthyFixture();
      final pubspec = fileAt('pubspec.yaml').readAsStringSync();
      fileAt('pubspec.yaml').writeAsStringSync(
        pubspec.replaceFirst(
          '- assets/easyi18n/',
          '- assets/easyi18n/floor.json',
        ),
      );
      final code = await runDoctor();
      expect(code, 0, reason: out.toString());
      expect(out.toString(), contains('assets/easyi18n/ assets registered'));
    });

    test('skips entitlements when there is no macOS target', () async {
      writeHealthyFixture();
      Directory('${dir.path}/macos').deleteSync(recursive: true);
      final code = await runDoctor();
      expect(code, 0);
      expect(out.toString(), contains('info  macos/ - no macOS target'));
    });

    test('fails when the scope is not mounted anywhere', () async {
      writeHealthyFixture();
      fileAt('lib/main.dart').writeAsStringSync('''
void main() => runApp(const MyApp());
''');
      final code = await runDoctor();
      expect(code, 1);
      expect(out.toString(), contains('Easyi18nScope not mounted'));
    });

    test('fails on missing pubspec dependency and floor', () async {
      writeHealthyFixture();
      fileAt('pubspec.yaml').writeAsStringSync('name: demo_app\n');
      Directory('${dir.path}/assets/easyi18n').deleteSync();
      final code = await runDoctor();
      final o = out.toString();
      expect(code, 1);
      expect(o, contains("missing the 'easyi18n' dependency"));
      expect(o, contains('not under flutter: assets:'));
      expect(o, contains('offline floor dir missing'));
    });
  });

  group('credential', () {
    test('warns when EASYI18N_TOKEN is not set', () async {
      writeHealthyFixture();
      final code = await runDoctor(environment: const {});
      expect(code, 0);
      expect(
        out.toString(),
        contains('warn  credential - EASYI18N_TOKEN not set'),
      );
    });
  });

  group('delivery', () {
    test('warns (does not fail) when nothing is published yet', () async {
      writeHealthyFixture();
      final code = await runDoctor(client: fakeDelivery(published: false));
      final o = out.toString();
      expect(code, 0, reason: o);
      expect(o, contains('warn  delivery - nothing published yet'));
      expect(o, isNot(contains('every tr() string is published')));
    });

    test('fails when CORS is not served', () async {
      writeHealthyFixture();
      final code = await runDoctor(client: fakeDelivery(cors: false));
      expect(code, 1);
      expect(out.toString(), contains('no access-control-allow-origin'));
    });

    test('warns when CORS is locked to one origin', () async {
      writeHealthyFixture();
      final code = await runDoctor(
        client: fakeDelivery(corsValue: 'https://app.easyi18n.com'),
      );
      expect(code, 0);
      expect(
        out.toString(),
        contains('warn  delivery - CORS is locked to https://app.easyi18n.com'),
      );
    });

    test('fails on a 200 that is not a manifest (SPA catch-all)', () async {
      writeHealthyFixture();
      final code = await runDoctor(
        client: MockClient(
          (_) async => http.Response(
            '<!doctype html><html>app</html>',
            200,
            headers: const {'content-type': 'text/html'},
          ),
        ),
      );
      expect(code, 1);
      expect(out.toString(), contains('not a delivery manifest'));
    });

    test('skips a bundle whose content does not match its address', () async {
      writeHealthyFixture(sources: ['Hello', 'Pending']);
      final code = await runDoctor(client: fakeDelivery(corruptEs: true));
      final o = out.toString();
      expect(code, 0, reason: o);
      expect(o, contains('warn  delivery - bundle es:'));
      expect(o, contains('stale CDN object'));
      // en still grades; es untranslated report is skipped with the locale.
      expect(o, contains('every tr() string is published'));
    });

    test('fails when the origin is unreachable', () async {
      writeHealthyFixture();
      final code = await runDoctor(
        client: MockClient(
          (_) async => throw http.ClientException('connection refused'),
        ),
      );
      expect(code, 1);
      expect(out.toString(), contains('FAIL  delivery - Could not reach'));
    });
  });

  group('scan vs published keys', () {
    test('classifies missing, untranslated and unused', () async {
      writeHealthyFixture(sources: ['Hello', 'Pending', 'Brand new string']);
      final code = await runDoctor();
      final o = out.toString();
      // Warnings only: nothing here blocks, it just needs a push/translation.
      expect(code, 0, reason: o);
      expect(
        o,
        contains('warn  scan - 1 tr() string(s) not in the published version'),
      );
      expect(o, contains('"Brand new string"'));
      expect(
        o,
        contains('warn  scan - 1 of your tr() string(s) untranslated in es'),
      );
      expect(o, contains('info  scan - 1 published key(s) not referenced'));
      expect(o, contains('No blocking problems'));
    });
  });

  group('icu lint', () {
    test('a malformed source string fails the run', () async {
      writeHealthyFixture(sources: ['Hello', 'Unclosed {brace']);
      final code = await runDoctor();
      final o = out.toString();
      expect(code, 1, reason: o);
      expect(o, contains('FAIL  icu - 1 ICU problem(s)'));
      expect(o, contains('"Unclosed {brace"'));
      expect(o, contains('never closed'));
    });
  });
}
