import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/commands/push_command.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/lockfile.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late StringBuffer out;
  late StringBuffer err;
  late Logger logger;
  late List<http.Request> requests;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('easyi18n_cli_push');
    out = StringBuffer();
    err = StringBuffer();
    logger = Logger(out: out, err: err);
    requests = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  String writeConfig() {
    final path = p.join(dir.path, 'easyi18n.yaml');
    File(path).writeAsStringSync('projectId: proj_abc\n');
    return path;
  }

  void writeSource(String relPath, String content) {
    final f = File(p.join(dir.path, relPath));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  File lockFile() => File(p.join(dir.path, Lockfile.fileName));

  /// A runner whose push command talks to a MockClient that prices each unit at
  /// 10 credits and reports one pending lang. [balance] sets the dry-run gate;
  /// [confirm] answers the prompt.
  CommandRunner<int> runnerWith({
    int balance = 1000,
    bool confirm = true,
    Map<String, String> environment = const {'EASYI18N_TOKEN': 'eik_x'},
  }) {
    TranslationsApiClient factory({
      required String baseUrl,
      required String token,
    }) => TranslationsApiClient(
      baseUrl: baseUrl,
      token: token,
      httpClient: MockClient((req) async {
        requests.add(req);
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final units = (body['units'] as List).cast<Map<String, dynamic>>();
        final dryRun = req.url.queryParameters['dryRun'] == 'true';
        final estimated = units.length * 10;
        return http.Response(
          jsonEncode({
            'dryRun': dryRun,
            'trackingToken': dryRun ? null : 'job_1',
            'estimatedCredits': estimated,
            'balance': balance,
            'accepted': estimated <= balance,
            'baseCode': 'en',
            'targetLangs': ['fr'],
            'units': [
              for (final u in units)
                {
                  'key': 'k_${u['source']}',
                  'token': 't',
                  'outcome': 'created',
                  'translated': <String>[],
                  'pending': ['fr'],
                },
            ],
          }),
          200,
        );
      }),
    );

    final runner = CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
    runner.addCommand(
      PushCommand(
        logger: logger,
        apiClientFactory: factory,
        environment: environment,
        confirm: (_) => confirm,
      ),
    );
    return runner;
  }

  test(
    'pushes new strings, writes the lockfile, prints a job message',
    () async {
      writeSource('lib/main.dart', '''
void build(c) {
  c.tr('Hello');
  c.tr('World');
}
''');
      final code = await runnerWith().run([
        '--config',
        writeConfig(),
        'push',
        '--yes',
      ]);

      expect(code, 0);
      // One dry-run call + one real call.
      expect(requests.length, 2);
      expect(requests.first.url.queryParameters['dryRun'], 'true');
      expect(requests.last.url.queryParameters.containsKey('dryRun'), isFalse);
      expect(out.toString(), contains('Translating in the background'));

      final lock = Lockfile.loadOrEmpty(lockFile(), project: 'x');
      expect(lock.units.map((u) => u.source).toSet(), {'Hello', 'World'});
    },
  );

  test('dry-run estimates without a real push or a lockfile write', () async {
    writeSource('lib/main.dart', "void f(c) => c.tr('Hi');\n");
    final code = await runnerWith().run([
      '--config',
      writeConfig(),
      'push',
      '--dry-run',
    ]);

    expect(code, 0);
    expect(requests.length, 1);
    expect(requests.single.url.queryParameters['dryRun'], 'true');
    expect(lockFile().existsSync(), isFalse);
    expect(out.toString(), contains('need translation'));
  });

  test('--max-credits below the estimate aborts before pushing', () async {
    writeSource('lib/main.dart', "void f(c) => c.tr('Hi');\n");
    await expectLater(
      runnerWith().run([
        '--config',
        writeConfig(),
        'push',
        '--yes',
        '--max-credits',
        '5',
      ]),
      throwsA(
        isA<CliException>().having(
          (e) => e.message,
          'message',
          contains('max-credits'),
        ),
      ),
    );
    // Only the dry-run happened; no real push.
    expect(requests.length, 1);
  });

  test('a declined confirmation aborts without a real push', () async {
    writeSource('lib/main.dart', "void f(c) => c.tr('Hi');\n");
    final code = await runnerWith(
      confirm: false,
    ).run(['--config', writeConfig(), 'push']);

    expect(code, 0);
    expect(requests.length, 1); // dry-run only
    expect(out.toString(), contains('Aborted'));
    expect(lockFile().existsSync(), isFalse);
  });

  test('reports orphans and --prune drops them from the lockfile', () async {
    Lockfile.fromExtraction('proj_abc', []).write(lockFile());
    // Seed a lockfile with a string that is NOT in the source.
    File(lockFile().path).writeAsStringSync(
      jsonEncode({
        'version': 1,
        'project': 'proj_abc',
        'units': [
          {'source': 'Gone'},
          {'source': 'Hi'},
        ],
      }),
    );
    writeSource('lib/main.dart', "void f(c) => c.tr('Hi');\n");

    await runnerWith().run([
      '--config',
      writeConfig(),
      'push',
      '--yes',
      '--prune',
    ]);

    expect(out.toString(), contains('orphan'));
    final lock = Lockfile.loadOrEmpty(lockFile(), project: 'x');
    expect(lock.units.map((u) => u.source), ['Hi']);
  });

  test('without --prune, orphans stay in the lockfile', () async {
    File(lockFile().path).writeAsStringSync(
      jsonEncode({
        'version': 1,
        'project': 'proj_abc',
        'units': [
          {'source': 'Gone'},
        ],
      }),
    );
    writeSource('lib/main.dart', "void f(c) => c.tr('Hi');\n");

    await runnerWith().run(['--config', writeConfig(), 'push', '--yes']);

    final lock = Lockfile.loadOrEmpty(lockFile(), project: 'x');
    expect(lock.units.map((u) => u.source).toSet(), {'Gone', 'Hi'});
  });

  test('warns about non-literal tr() calls', () async {
    writeSource('lib/main.dart', '''
void f(c, name) {
  c.tr('Hi');
  c.tr(name);
}
''');
    await runnerWith().run(['--config', writeConfig(), 'push', '--yes']);
    expect(err.toString(), contains('non-literal source'));
  });

  test('no extractable strings → nothing to push, no network', () async {
    writeSource('lib/main.dart', 'void f() {}\n');
    final code = await runnerWith().run([
      '--config',
      writeConfig(),
      'push',
      '--yes',
    ]);
    expect(code, 0);
    expect(requests, isEmpty);
    expect(out.toString(), contains('Nothing to push'));
  });

  test('missing token throws before any network', () async {
    writeSource('lib/main.dart', "void f(c) => c.tr('Hi');\n");
    await expectLater(
      runnerWith(
        environment: const {},
      ).run(['--config', writeConfig(), 'push']),
      throwsA(
        isA<CliException>().having(
          (e) => e.message,
          'message',
          contains('EASYI18N_TOKEN'),
        ),
      ),
    );
    expect(requests, isEmpty);
  });
}
