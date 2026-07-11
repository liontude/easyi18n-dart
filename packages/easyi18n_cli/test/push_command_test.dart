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
  late CliLogger logger;
  late List<http.Request> requests;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('easyi18n_cli_push');
    out = StringBuffer();
    err = StringBuffer();
    logger = CliLogger(out: out, err: err);
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

  test(
    'a @handle/slug config resolves, then keys the lockfile by the id',
    () async {
      final configFile = p.join(dir.path, 'easyi18n.yaml');
      File(configFile).writeAsStringSync('workspace: acme\nproject: dogfood\n');
      writeSource('lib/main.dart', "void f(c) => c.tr('Hi');\n");

      TranslationsApiClient factory({
        required String baseUrl,
        required String token,
      }) => TranslationsApiClient(
        baseUrl: baseUrl,
        token: token,
        httpClient: MockClient((req) async {
          requests.add(req);
          if (req.url.path == '/v1/projects/resolve') {
            return http.Response(
              jsonEncode({'projectId': 'proj_abc', 'workspaceId': 'ws_1'}),
              200,
            );
          }
          final units = (jsonDecode(req.body)['units'] as List)
              .cast<Map<String, dynamic>>();
          final dryRun = req.url.queryParameters['dryRun'] == 'true';
          return http.Response(
            jsonEncode({
              'dryRun': dryRun,
              'trackingToken': dryRun ? null : 'job_1',
              'estimatedCredits': 0,
              'balance': 1000,
              'accepted': true,
              'baseCode': 'en',
              'targetLangs': ['fr'],
              'units': [
                for (final u in units)
                  {
                    'key': 'k_${u['source']}',
                    'token': 't',
                    'outcome': 'created',
                    'translated': ['fr'],
                    'pending': <String>[],
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
          environment: const {'EASYI18N_TOKEN': 'eik_x'},
          confirm: (_) => true,
        ),
      );

      final code = await runner.run(['--config', configFile, 'push', '--yes']);
      expect(code, 0);
      expect(requests.first.url.path, '/v1/projects/resolve');
      // The lockfile carries the RESOLVED opaque id, not the handle ref.
      final lockJson =
          jsonDecode(lockFile().readAsStringSync()) as Map<String, dynamic>;
      expect(lockJson['project'], 'proj_abc');
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

  group('--publish', () {
    /// Stateful fake mirroring the backend's dry-run semantics:
    /// - a lang left IN FLIGHT by an earlier push counts in `pending` but is
    ///   free to re-estimate (estimatedCredits == 0);
    /// - a FAILED lang is re-queued, so it is both pending AND priced.
    ///
    /// [startPending] seeds in-flight langs before this run's push;
    /// [pollsUntilDone] is how many polls the fill takes; [failAfterPush]
    /// makes the fill settle as failed instead of translated.
    CommandRunner<int> publishRunner({
      int pollsUntilDone = 1,
      bool startPending = false,
      bool failAfterPush = false,
      required List<String> publishBodies,
    }) {
      var pushed = startPending;
      var polls = 0;
      TranslationsApiClient factory({
        required String baseUrl,
        required String token,
      }) => TranslationsApiClient(
        baseUrl: baseUrl,
        token: token,
        httpClient: MockClient((req) async {
          requests.add(req);
          if (req.url.path.endsWith('/publish')) {
            publishBodies.add(req.body);
            return http.Response(
              jsonEncode({'versionId': '2026.07.09.9', 'keyCount': 3}),
              201,
            );
          }
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final units = (body['units'] as List).cast<Map<String, dynamic>>();
          final dryRun = req.url.queryParameters['dryRun'] == 'true';

          var pending = <String>['fr'];
          var priced = !pushed; // an unregistered lang needs a paid fill
          if (dryRun && pushed) {
            polls++;
            if (polls >= pollsUntilDone) {
              if (failAfterPush) {
                priced = true; // failed → re-queued, so it costs again
              } else {
                pending = [];
              }
            }
          }
          if (!dryRun) pushed = true;
          return http.Response(
            jsonEncode({
              'dryRun': dryRun,
              'trackingToken': dryRun ? null : 'job_1',
              'estimatedCredits': priced ? units.length * 10 : 0,
              'balance': 1000,
              'accepted': true,
              'units': [
                for (final u in units)
                  {
                    'key': 'k_${u['source']}',
                    'outcome': 'created',
                    'translated': <String>[],
                    'pending': pending,
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
          environment: const {'EASYI18N_TOKEN': 'eik_x'},
          confirm: (_) => true,
          wait: (_) async {},
        ),
      );
      return runner;
    }

    test('pushes, waits for the fill, then publishes', () async {
      final config = writeConfig();
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      final publishBodies = <String>[];
      final code = await publishRunner(
        pollsUntilDone: 2,
        publishBodies: publishBodies,
      ).run(['--config', config, 'push', '--publish', '--yes']);
      final o = out.toString();
      expect(code, 0, reason: o);
      expect(o, contains('Waiting for the AI fill'));
      expect(o, contains('Fill complete.'));
      expect(o, contains('Published 2026.07.09.9 (3 key(s))'));
      expect(publishBodies, hasLength(1));
      expect(jsonDecode(publishBodies.single), isEmpty);
    });

    test('--approved-only is forwarded to the publish call', () async {
      final config = writeConfig();
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      final publishBodies = <String>[];
      final code = await publishRunner(publishBodies: publishBodies).run([
        '--config',
        config,
        'push',
        '--publish',
        '--approved-only',
        '--yes',
      ]);
      expect(code, 0, reason: out.toString());
      expect(jsonDecode(publishBodies.single), equals({'approvedOnly': true}));
    });

    test('already-translated push publishes without waiting', () async {
      final config = writeConfig();
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      final publishBodies = <String>[];
      // First run pushes + publishes; the second preview then sees 0 pending
      // and must publish directly, without the fill wait.
      final runner = publishRunner(publishBodies: publishBodies);
      var code = await runner.run([
        '--config',
        config,
        'push',
        '--publish',
        '--yes',
      ]);
      expect(code, 0, reason: out.toString());
      out.clear();
      publishBodies.clear();
      code = await runner.run([
        '--config',
        config,
        'push',
        '--publish',
        '--yes',
      ]);
      final o = out.toString();
      expect(code, 0, reason: o);
      expect(o, contains('Everything is already translated.'));
      expect(o, isNot(contains('Waiting for the AI fill')));
      expect(publishBodies, hasLength(1));
    });

    test('waits for a fill left in flight by an EARLIER push', () async {
      // The regression: those langs are pending but free, so the estimate is
      // 0 - publishing on that signal would bake base text (friction F2).
      final config = writeConfig();
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      final publishBodies = <String>[];
      // The preview itself consumes one poll; the fill lands on the third.
      final code = await publishRunner(
        startPending: true,
        pollsUntilDone: 3,
        publishBodies: publishBodies,
      ).run(['--config', config, 'push', '--publish', '--yes']);
      final o = out.toString();
      expect(code, 0, reason: o);
      expect(o, contains('still being translated from an earlier push'));
      expect(o, contains('Waiting for the AI fill'));
      expect(o, contains('Fill complete.'));
      expect(publishBodies, hasLength(1));
    });

    test('a failed fill aborts instead of polling to the timeout', () async {
      final config = writeConfig();
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      final publishBodies = <String>[];
      await expectLater(
        publishRunner(
          failAfterPush: true,
          publishBodies: publishBodies,
        ).run(['--config', config, 'push', '--publish', '--yes']),
        throwsA(
          isA<CliException>().having(
            (e) => e.message,
            'message',
            contains('did not translate'),
          ),
        ),
      );
      expect(publishBodies, isEmpty);
    });

    test(
      '--publish --prune with no strings never touches the lockfile',
      () async {
        final config = writeConfig();
        lockFile().writeAsStringSync(
          jsonEncode({
            'project': 'proj_abc',
            'units': [
              {'source': 'Hello', 'ctx': null},
            ],
          }),
        );
        final before = lockFile().readAsStringSync();
        final publishBodies = <String>[];
        final code = await publishRunner(
          publishBodies: publishBodies,
        ).run(['--config', config, 'push', '--publish', '--prune', '--yes']);
        expect(code, 0, reason: out.toString());
        expect(out.toString(), contains('publishing the current state'));
        expect(lockFile().readAsStringSync(), before);
        expect(publishBodies, hasLength(1));
      },
    );

    test('--approved-only without --publish is rejected', () async {
      final config = writeConfig();
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      await expectLater(
        publishRunner(
          publishBodies: [],
        ).run(['--config', config, 'push', '--approved-only', '--yes']),
        throwsA(isA<CliException>()),
      );
    });

    test('--publish with --dry-run is rejected', () async {
      final config = writeConfig();
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      await expectLater(
        publishRunner(
          publishBodies: [],
        ).run(['--config', config, 'push', '--publish', '--dry-run']),
        throwsA(isA<CliException>()),
      );
    });
  });
}
