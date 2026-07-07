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
  late Logger logger;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('easyi18n_cli_pull');
    out = StringBuffer();
    err = StringBuffer();
    logger = Logger(out: out, err: err);
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

  test('a real pull records the pulled version in .easyi18n/state.json',
      () async {
    final config = writeConfig();
    await runnerWith().run(['--config', config, 'pull']);

    final state = CliState.load(CliState.fileFor(config));
    expect(state.version, '2026.06.26'); // the mock backend's version
    expect(state.pulledAt, isNotNull);
  });

  test('dry-run does not touch the state file', () async {
    final config = writeConfig();
    await runnerWith().run(['--config', config, 'pull', '--dry-run']);

    expect(CliState.fileFor(config).existsSync(), isFalse);
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
}
