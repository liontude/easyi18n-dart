import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/commands/pull_command.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:easyi18n_cli/src/state.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late StringBuffer out;
  late StringBuffer err;
  late CliLogger logger;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('easyi18n_cli_pull');
    out = StringBuffer();
    err = StringBuffer();
    logger = CliLogger(out: out, err: err);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  String writeConfig({String output = 'lib/l10n', String format = 'arb'}) {
    final path = '${dir.path}/easyi18n.yaml';
    File(path).writeAsStringSync(
      'projectId: proj_abc\nformat: $format\noutput: $output\n',
    );
    return path;
  }

  /// Builds a runner whose pull command serves [files] (or a backend error)
  /// through a MockClient, with the given environment.
  CommandRunner<int> runnerWith({
    Map<String, String> files = const {'arb/app_en.arb': '{"hi":"Hi"}'},
    http.Response? errorResponse,
    Map<String, String> environment = const {'EASYI18N_TOKEN': 'eik_x'},
    void Function(http.Request)? onRequest,
  }) {
    TranslationsApiClient factory({
      required String baseUrl,
      required String token,
    }) => TranslationsApiClient(
      baseUrl: baseUrl,
      token: token,
      httpClient: MockClient((req) async {
        onRequest?.call(req);
        return errorResponse ??
            http.Response(
              jsonEncode({
                'project': 'proj_abc',
                'version': '2026.06.26',
                'baseCode': 'en',
                'formats': ['arb'],
                'files': files,
              }),
              200,
            );
      }),
    );
    final runner = CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
    runner.addCommand(
      PullCommand(
        logger: logger,
        apiClientFactory: factory,
        environment: environment,
      ),
    );
    return runner;
  }

  test('resolves a @handle/slug config once, then pulls by the id', () async {
    final path = '${dir.path}/easyi18n.yaml';
    File(path).writeAsStringSync('workspace: acme\nproject: dogfood\n');

    final paths = <String>[];
    TranslationsApiClient factory({
      required String baseUrl,
      required String token,
    }) => TranslationsApiClient(
      baseUrl: baseUrl,
      token: token,
      httpClient: MockClient((req) async {
        paths.add(req.url.path);
        if (req.url.path == '/v1/projects/resolve') {
          expect(req.url.queryParameters['workspace'], 'acme');
          expect(req.url.queryParameters['project'], 'dogfood');
          return http.Response(
            jsonEncode({'projectId': 'proj_abc', 'workspaceId': 'ws_1'}),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'project': 'proj_abc',
            'version': '2026.06.26',
            'baseCode': 'en',
            'formats': ['arb'],
            'files': {'arb/app_en.arb': '{"hi":"Hi"}'},
          }),
          200,
        );
      }),
    );
    final runner = CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
    runner.addCommand(
      PullCommand(
        logger: logger,
        apiClientFactory: factory,
        environment: const {'EASYI18N_TOKEN': 'eik_x'},
      ),
    );

    final code = await runner.run(['--config', path, 'pull']);
    expect(code, 0);
    expect(paths, [
      '/v1/projects/resolve',
      '/v1/projects/proj_abc/translations',
    ]);
    expect(
      File('${dir.path}/lib/l10n/app_en.arb').readAsStringSync(),
      '{"hi":"Hi"}',
    );
  });

  test('writes files, stripping the format prefix', () async {
    final code = await runnerWith(
      files: {
        'arb/app_en.arb': '{"hi":"Hi"}',
        'arb/app_es.arb': '{"hi":"Hola"}',
      },
    ).run(['--config', writeConfig(), 'pull']);

    expect(code, 0);
    expect(
      File('${dir.path}/lib/l10n/app_en.arb').readAsStringSync(),
      '{"hi":"Hi"}',
    );
    expect(
      File('${dir.path}/lib/l10n/app_es.arb').readAsStringSync(),
      '{"hi":"Hola"}',
    );
  });

  test('creates nested parent directories', () async {
    await runnerWith(
      files: {'arb/sub/app_en.arb': 'x'},
    ).run(['--config', writeConfig(), 'pull']);

    expect(File('${dir.path}/lib/l10n/sub/app_en.arb').existsSync(), isTrue);
  });

  test('dry-run does not write files', () async {
    await runnerWith().run(['--config', writeConfig(), 'pull', '--dry-run']);

    expect(Directory('${dir.path}/lib/l10n').existsSync(), isFalse);
    expect(out.toString(), contains('Would pull'));
  });

  test(
    'a real pull records the pulled version in .easyi18n/state.json',
    () async {
      final config = writeConfig();
      await runnerWith().run(['--config', config, 'pull']);

      final state = CliState.load(CliState.fileFor(config));
      expect(state.version, '2026.06.26'); // the mock backend's version
      expect(state.pulledAt, isNotNull);
    },
  );

  test('dry-run does not touch the state file', () async {
    final config = writeConfig();
    await runnerWith().run(['--config', config, 'pull', '--dry-run']);

    expect(CliState.fileFor(config).existsSync(), isFalse);
  });

  group('prune', () {
    /// Seeds the state of a previous pull plus its files on disk.
    void seedPreviousPull(
      String config, {
      required List<String> files,
      String format = 'arb',
      String output = 'lib/l10n',
    }) {
      CliState(
        version: '2026.06.01',
        pulledAt: DateTime.utc(2026, 6),
        format: format,
        output: output,
        files: files,
      ).save(CliState.fileFor(config));
      for (final rel in files) {
        File('${dir.path}/$output/$rel')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('old');
      }
    }

    test('a full pull removes recorded files the server renamed', () async {
      final config = writeConfig();
      seedPreviousPull(config, files: ['app_en.arb', 'app_zh-hant.arb']);

      await runnerWith(
        files: {
          'arb/app_en.arb': '{"hi":"Hi"}',
          'arb/app_zh_Hant.arb': '{"hi":"zh"}',
        },
      ).run(['--config', config, 'pull']);

      expect(
        File('${dir.path}/lib/l10n/app_zh-hant.arb').existsSync(),
        isFalse,
      );
      expect(File('${dir.path}/lib/l10n/app_zh_Hant.arb').existsSync(), isTrue);
      expect(
        File('${dir.path}/lib/l10n/app_en.arb').readAsStringSync(),
        '{"hi":"Hi"}',
      );
      expect(out.toString(), contains('Removed 1 stale file(s)'));
      final state = CliState.load(CliState.fileFor(config));
      expect(state.files, ['app_en.arb', 'app_zh_Hant.arb']);
      expect(state.format, 'arb');
    });

    test('pruning a nested file drops its emptied directory', () async {
      final config = writeConfig(format: 'ios_strings');
      seedPreviousPull(
        config,
        format: 'ios_strings',
        files: ['zh-hant.lproj/Localizable.strings'],
      );

      await runnerWith(
        files: {'ios_strings/zh-Hant.lproj/Localizable.strings': 'x'},
      ).run(['--config', config, 'pull']);

      // Compare literal entry names: on a case-insensitive filesystem
      // (APFS) Directory('zh-hant.lproj').existsSync() would match the
      // fresh zh-Hant.lproj and hide whether the stale dir was removed.
      final names = Directory('${dir.path}/lib/l10n')
          .listSync()
          .map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last)
          .toList();
      expect(names, contains('zh-Hant.lproj'));
      expect(names, isNot(contains('zh-hant.lproj')));
      expect(
        File(
          '${dir.path}/lib/l10n/zh-Hant.lproj/Localizable.strings',
        ).existsSync(),
        isTrue,
      );
    });

    test('a --lang pull never prunes and merges the recorded files', () async {
      final config = writeConfig();
      seedPreviousPull(config, files: ['app_en.arb', 'app_es.arb']);

      await runnerWith(
        files: {'arb/app_es.arb': '{"hi":"Hola"}'},
      ).run(['--config', config, 'pull', '--lang', 'es']);

      expect(File('${dir.path}/lib/l10n/app_en.arb').existsSync(), isTrue);
      final state = CliState.load(CliState.fileFor(config));
      expect(state.files, ['app_en.arb', 'app_es.arb']);
    });

    test(
      'a format switch never prunes but surfaces the stranded files',
      () async {
        final config = writeConfig(format: 'json');
        seedPreviousPull(config, format: 'arb', files: ['app_en.arb']);

        await runnerWith(
          files: {'json/en.json': '{}'},
        ).run(['--config', config, 'pull']);

        expect(File('${dir.path}/lib/l10n/app_en.arb').existsSync(), isTrue);
        expect(out.toString(), contains('no longer manages'));
        expect(out.toString(), contains('app_en.arb'));
        final state = CliState.load(CliState.fileFor(config));
        expect(state.format, 'json');
        expect(state.files, ['en.json']);
      },
    );

    test(
      'an output switch never prunes in the new dir and lists the old',
      () async {
        // The V1 hazard: recorded rel paths must not be resolved against a NEW
        // output dir — a pre-existing user file there would be deleted.
        final config = writeConfig(output: 'lib/i18n');
        seedPreviousPull(
          config,
          output: 'lib/l10n',
          files: ['app_en.arb', 'app_es.arb'],
        );
        File('${dir.path}/lib/i18n/app_es.arb')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('handwritten');

        await runnerWith(
          files: {'arb/app_en.arb': '{"hi":"Hi"}'},
        ).run(['--config', config, 'pull']);

        // The user's file in the new dir survives; the old dir is untouched.
        expect(
          File('${dir.path}/lib/i18n/app_es.arb').readAsStringSync(),
          'handwritten',
        );
        expect(File('${dir.path}/lib/l10n/app_es.arb').existsSync(), isTrue);
        expect(out.toString(), contains('no longer manages'));
        expect(out.toString(), contains('app_es.arb'));
        final state = CliState.load(CliState.fileFor(config));
        expect(state.output, 'lib/i18n');
        expect(state.files, ['app_en.arb']);
      },
    );

    test('prune sweeps a stranded .tmp from a crashed write', () async {
      final config = writeConfig();
      seedPreviousPull(config, files: ['app_zz.arb']);
      File('${dir.path}/lib/l10n/app_zz.arb.tmp').writeAsStringSync('half');

      await runnerWith(
        files: {'arb/app_en.arb': '{"hi":"Hi"}'},
      ).run(['--config', config, 'pull']);

      expect(File('${dir.path}/lib/l10n/app_zz.arb').existsSync(), isFalse);
      expect(File('${dir.path}/lib/l10n/app_zz.arb.tmp').existsSync(), isFalse);
    });

    test('a .DS_Store does not keep an emptied dir alive', () async {
      final config = writeConfig(format: 'ios_strings');
      seedPreviousPull(
        config,
        format: 'ios_strings',
        files: ['zh-hant.lproj/Localizable.strings'],
      );
      File(
        '${dir.path}/lib/l10n/zh-hant.lproj/.DS_Store',
      ).writeAsStringSync('finder');

      await runnerWith(
        files: {'ios_strings/zh-Hant.lproj/Localizable.strings': 'x'},
      ).run(['--config', config, 'pull']);

      final names = Directory('${dir.path}/lib/l10n')
          .listSync()
          .map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last)
          .toList();
      expect(names, contains('zh-Hant.lproj'));
      expect(names, isNot(contains('zh-hant.lproj')));
    });

    test('dry-run previews the prune without deleting', () async {
      final config = writeConfig();
      seedPreviousPull(config, files: ['app_zh-hant.arb']);

      await runnerWith(
        files: {'arb/app_zh_Hant.arb': 'x'},
      ).run(['--config', config, 'pull', '--dry-run']);

      expect(File('${dir.path}/lib/l10n/app_zh-hant.arb').existsSync(), isTrue);
      expect(out.toString(), contains('Would remove 1 stale file(s)'));
      // State untouched: still the seeded pull.
      expect(CliState.load(CliState.fileFor(config)).version, '2026.06.01');
    });

    test('first recording pull hints at files it cannot attribute', () async {
      final config = writeConfig();
      // Pre-upgrade pull: state exists but has no file list.
      CliState(
        version: '2026.06.01',
        pulledAt: DateTime.utc(2026, 6),
      ).save(CliState.fileFor(config));
      File('${dir.path}/lib/l10n/app_zh-hant.arb')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('old');

      await runnerWith(
        files: {'arb/app_zh_Hant.arb': 'x'},
      ).run(['--config', config, 'pull']);

      // Not deleted — only surfaced.
      expect(File('${dir.path}/lib/l10n/app_zh-hant.arb').existsSync(), isTrue);
      expect(out.toString(), contains('app_zh-hant.arb'));
      expect(out.toString(), contains('Not written by this pull'));
    });
  });

  test('uses --token over the environment', () async {
    String? sentAuth;
    await runnerWith(
      environment: const {},
      onRequest: (req) => sentAuth = req.headers['authorization'],
    ).run(['--config', writeConfig(), 'pull', '--token', 'eik_flag']);

    expect(sentAuth, 'Bearer eik_flag');
  });

  test('forwards --version and --lang', () async {
    Uri? sentUri;
    await runnerWith(onRequest: (req) => sentUri = req.url).run([
      '--config',
      writeConfig(),
      'pull',
      '--version',
      '2026.01.01',
      '--lang',
      'es',
    ]);

    expect(sentUri!.queryParameters['version'], '2026.01.01');
    expect(sentUri!.queryParameters['lang'], 'es');
    expect(sentUri!.queryParameters['format'], 'arb');
  });

  test('fails when no token is available', () async {
    expect(
      () => runnerWith(
        environment: const {},
      ).run(['--config', writeConfig(), 'pull']),
      throwsA(
        isA<CliException>().having(
          (e) => e.message,
          'message',
          contains('EASYI18N_TOKEN'),
        ),
      ),
    );
  });

  test('fails when the backend returns no files', () async {
    expect(
      () =>
          runnerWith(files: const {}).run(['--config', writeConfig(), 'pull']),
      throwsA(
        isA<CliException>().having(
          (e) => e.message,
          'message',
          contains('no files'),
        ),
      ),
    );
  });

  test('propagates backend errors', () async {
    expect(
      () => runnerWith(
        errorResponse: http.Response(
          jsonEncode({'error': 'not_published', 'message': 'not published'}),
          404,
        ),
      ).run(['--config', writeConfig(), 'pull']),
      throwsA(isA<CliException>()),
    );
  });

  test('refuses a traversing file key (path traversal guard)', () async {
    await expectLater(
      runnerWith(
        files: {'arb/../../../pwned.txt': 'x'},
      ).run(['--config', writeConfig(), 'pull']),
      throwsA(
        isA<CliException>().having(
          (e) => e.message,
          'message',
          contains('outside'),
        ),
      ),
    );
    expect(File('${dir.path}/../../../pwned.txt').existsSync(), isFalse);
  });

  test('refuses an absolute file key that escapes the output dir', () async {
    // An absolute key makes p.join ignore outputDir; the guard must reject it.
    final escaped = '${dir.path}/escaped.txt';
    await expectLater(
      runnerWith(
        files: {escaped: 'x'},
      ).run(['--config', writeConfig(), 'pull']),
      throwsA(isA<CliException>()),
    );
    expect(File(escaped).existsSync(), isFalse);
  });

  group('--watch', () {
    /// A runner whose backend serves [metaVersions] from `/meta` (one per
    /// watch cycle, clamping on the last) and version-stamped files from
    /// `/translations`. The sleeper is a no-op so cycles run instantly.
    CommandRunner<int> watchRunnerWith({
      required List<Object> metaVersions, // String version | int (HTTP error)
      required int cycles,
    }) {
      var metaCalls = 0;
      var served = '';
      TranslationsApiClient factory({
        required String baseUrl,
        required String token,
      }) => TranslationsApiClient(
        baseUrl: baseUrl,
        token: token,
        httpClient: MockClient((req) async {
          if (req.url.path.endsWith('/meta')) {
            final step =
                metaVersions[metaCalls.clamp(0, metaVersions.length - 1)];
            metaCalls++;
            if (step is int) return http.Response('boom', step);
            served = step as String;
            return http.Response(
              jsonEncode({'currentVersionId': step, 'baseCode': 'en'}),
              200,
            );
          }
          final version = served.isEmpty ? 'v1' : served;
          return http.Response(
            jsonEncode({
              'project': 'proj_abc',
              'version': version,
              'baseCode': 'en',
              'formats': ['arb'],
              'files': {'arb/app_en.arb': '{"v":"$version"}'},
            }),
            200,
          );
        }),
      );
      final runner = CommandRunner<int>('easyi18n', '')
        ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
      runner.addCommand(
        PullCommand(
          logger: logger,
          apiClientFactory: factory,
          environment: const {'EASYI18N_TOKEN': 'eik_x'},
          sleeper: (_) async {},
          watchCyclesForTest: cycles,
        ),
      );
      return runner;
    }

    test('re-pulls when meta reports a new version', () async {
      final code = await watchRunnerWith(
        metaVersions: ['v1', 'v2', 'v2'],
        cycles: 3,
      ).run(['--config', writeConfig(), 'pull', '--watch', '--interval', '5']);
      expect(code, 0);
      expect(
        File('${dir.path}/lib/l10n/app_en.arb').readAsStringSync(),
        '{"v":"v2"}',
      );
      expect(out.toString(), contains('New version v2'));
      // Initial pull + one re-pull; the unchanged cycle does not pull again.
      expect('Pulled 1 file(s)'.allMatches(out.toString()).length, 2);
    });

    test('a transient meta error warns and keeps watching', () async {
      final code = await watchRunnerWith(
        metaVersions: [500, 'v3'],
        cycles: 2,
      ).run(['--config', writeConfig(), 'pull', '--watch']);
      expect(code, 0);
      expect(err.toString(), contains('retrying next cycle'));
      expect(
        File('${dir.path}/lib/l10n/app_en.arb').readAsStringSync(),
        '{"v":"v3"}',
      );
    });

    test('rejects --version and --dry-run combinations', () async {
      await expectLater(
        runnerWith().run([
          '--config',
          writeConfig(),
          'pull',
          '--watch',
          '--version',
          'x',
        ]),
        throwsA(isA<CliException>()),
      );
      await expectLater(
        runnerWith().run([
          '--config',
          writeConfig(),
          'pull',
          '--watch',
          '--dry-run',
        ]),
        throwsA(isA<CliException>()),
      );
    });

    test('started before the first publish, it idles and pulls v1 when it '
        'lands', () async {
      // The bootstrap pull 404s (not_published); the watcher must warn and
      // keep watching, then pull once meta reports the first version.
      var translationsCalls = 0;
      TranslationsApiClient factory({
        required String baseUrl,
        required String token,
      }) => TranslationsApiClient(
        baseUrl: baseUrl,
        token: token,
        httpClient: MockClient((req) async {
          if (req.url.path.endsWith('/meta')) {
            return http.Response(
              jsonEncode({'currentVersionId': 'v1', 'baseCode': 'en'}),
              200,
            );
          }
          translationsCalls++;
          if (translationsCalls == 1) {
            return http.Response(
              jsonEncode({
                'error': 'not_published',
                'message': 'project has no published version',
              }),
              404,
            );
          }
          return http.Response(
            jsonEncode({
              'project': 'proj_abc',
              'version': 'v1',
              'baseCode': 'en',
              'formats': ['arb'],
              'files': {'arb/app_en.arb': '{"v":"v1"}'},
            }),
            200,
          );
        }),
      );
      final runner = CommandRunner<int>('easyi18n', '')
        ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
      runner.addCommand(
        PullCommand(
          logger: logger,
          apiClientFactory: factory,
          environment: const {'EASYI18N_TOKEN': 'eik_x'},
          sleeper: (_) async {},
          watchCyclesForTest: 1,
        ),
      );

      final code = await runner.run([
        '--config',
        writeConfig(),
        'pull',
        '--watch',
      ]);
      expect(code, 0);
      expect(err.toString(), contains('watching for the first publish'));
      expect(
        File('${dir.path}/lib/l10n/app_en.arb').readAsStringSync(),
        '{"v":"v1"}',
      );
    });

    test('rejects an interval under 5 seconds', () async {
      await expectLater(
        runnerWith().run([
          '--config',
          writeConfig(),
          'pull',
          '--watch',
          '--interval',
          '1',
        ]),
        throwsA(isA<CliException>()),
      );
    });
  });
}
