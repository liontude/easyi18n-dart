import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/src/commands/init_command.dart';
import 'package:easyi18n_cli/src/config.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:easyi18n_cli/src/project_ref.dart';
import 'package:easyi18n_cli/src/scaffold.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  late Directory dir;
  late StringBuffer out;
  late CliLogger logger;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('easyi18n_cli_init');
    out = StringBuffer();
    logger = CliLogger(out: out, err: StringBuffer());
  });
  tearDown(() => dir.deleteSync(recursive: true));

  CommandRunner<int> runner({String? Function(String)? prompt}) {
    final r = CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
    r.addCommand(InitCommand(logger: logger, prompt: prompt ?? (_) => null));
    return r;
  }

  String configPath() => '${dir.path}/easyi18n.yaml';
  File fileAt(String relative) => File('${dir.path}/$relative');

  /// A minimal Flutter app fixture: pubspec, trivial main, both macOS
  /// entitlements (sandbox only — the state `flutter create` leaves them in).
  void writeFlutterFixture() {
    fileAt('pubspec.yaml').writeAsStringSync('''
name: demo_app

environment:
  sdk: ^3.5.0

dependencies:
  flutter:
    sdk: flutter

flutter:
  uses-material-design: true
''');
    fileAt('lib/main.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync('''
import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => const MaterialApp();
}
''');
    for (final name in ['DebugProfile.entitlements', 'Release.entitlements']) {
      fileAt('macos/Runner/$name')
        ..createSync(recursive: true)
        ..writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
\t<key>com.apple.security.app-sandbox</key>
\t<true/>
</dict>
</plist>
''');
    }
  }

  Future<int?> runInit(List<String> extra) =>
      runner().run(['--config', configPath(), 'init', ...extra]);

  group('full scaffold', () {
    test('sets up a clean Flutter fixture end to end', () async {
      writeFlutterFixture();
      final code = await runInit(['--project-id', 'proj_abc']);
      expect(code, 0);

      // Config.
      expect(
        Easyi18nConfig.load(File(configPath())).ref,
        const IdRef('proj_abc'),
      );

      // Pubspec: dependency + assets floor, still valid YAML.
      final pubspec = fileAt('pubspec.yaml').readAsStringSync();
      final doc = loadYaml(pubspec) as Map;
      expect((doc['dependencies'] as Map).containsKey('easyi18n'), isTrue);
      expect((doc['flutter'] as Map)['assets'], contains(kAssetsFloorDir));

      // Floor dir.
      expect(fileAt('assets/easyi18n/.gitkeep').existsSync(), isTrue);

      // Gitignore.
      expect(
        fileAt('.gitignore').readAsStringSync(),
        contains(kStateIgnoreEntry),
      );

      // Both entitlements.
      for (final name in [
        'DebugProfile.entitlements',
        'Release.entitlements',
      ]) {
        expect(
          fileAt('macos/Runner/$name').readAsStringSync(),
          contains('<key>$kNetworkClientKey</key>'),
          reason: name,
        );
      }

      // Scope wiring.
      final main = fileAt('lib/main.dart').readAsStringSync();
      expect(main, contains('Easyi18nScope('));
      expect(main, contains("projectId: 'proj_abc'"));
      expect(main, contains("import 'package:easyi18n/easyi18n.dart';"));
    });

    test('is idempotent: a second run changes nothing', () async {
      writeFlutterFixture();
      await runInit(['--project-id', 'proj_abc']);

      String snapshot() => [
        for (final f in [
          'easyi18n.yaml',
          'pubspec.yaml',
          '.gitignore',
          'lib/main.dart',
          'macos/Runner/DebugProfile.entitlements',
          'macos/Runner/Release.entitlements',
        ])
          File('${dir.path}/$f').readAsStringSync(),
      ].join('\n===\n');

      final before = snapshot();
      final code = await runInit(['--project-id', 'proj_abc']);
      expect(code, 0);
      expect(snapshot(), before);
    });

    test('--dry-run writes nothing', () async {
      writeFlutterFixture();
      final mainBefore = fileAt('lib/main.dart').readAsStringSync();
      final code = await runInit(['--project-id', 'proj_abc', '--dry-run']);
      expect(code, 0);

      expect(File(configPath()).existsSync(), isFalse);
      expect(fileAt('.gitignore').existsSync(), isFalse);
      expect(fileAt('assets/easyi18n').existsSync(), isFalse);
      expect(fileAt('lib/main.dart').readAsStringSync(), mainBefore);
      expect(out.toString(), contains('would'));
    });

    test('prints the snippet for a non-trivial main', () async {
      writeFlutterFixture();
      fileAt('lib/main.dart').writeAsStringSync('''
void main() { runApp(A()); }
void alt() { runApp(B()); }
''');
      final mainBefore = fileAt('lib/main.dart').readAsStringSync();
      final code = await runInit(['--project-id', 'proj_abc']);
      expect(code, 0);
      expect(fileAt('lib/main.dart').readAsStringSync(), mainBefore);
      expect(out.toString(), contains('Easyi18nScope('));
      expect(out.toString(), contains('wire the scope manually'));
    });

    test('skips macOS entitlements when there is no macos target', () async {
      writeFlutterFixture();
      Directory('${dir.path}/macos').deleteSync(recursive: true);
      final code = await runInit(['--project-id', 'proj_abc']);
      expect(code, 0);
      expect(out.toString(), contains('no macOS target'));
    });
  });

  group('config handling', () {
    test('writes a config from flags', () async {
      final code = await runInit([
        '--project-id',
        'proj_abc',
        '--base-url',
        'http://localhost:8080',
        '--format',
        'json',
      ]);

      expect(code, 0);
      final config = Easyi18nConfig.load(File(configPath()));
      expect(config.ref, const IdRef('proj_abc'));
      expect(config.baseUrl, 'http://localhost:8080');
      expect(config.format, 'json');
      expect(config.output, Easyi18nConfig.defaultOutput);
    });

    test(
      'keeps an existing config without --force (idempotent re-run)',
      () async {
        File(configPath()).writeAsStringSync('projectId: old');
        final code = await runInit(['--project-id', 'new']);
        expect(code, 0);
        expect(Easyi18nConfig.load(File(configPath())).ref, const IdRef('old'));
        expect(out.toString(), contains('kept existing config'));
      },
    );

    test(
      'keeps an existing config when the ref flags are degenerate',
      () async {
        // A lone '@' strips to an absent workspace inside ProjectRef.parse;
        // on the keep-existing path that must warn, not abort the re-run.
        File(configPath()).writeAsStringSync('projectId: old');
        final code = await runInit([
          '--workspace',
          '@',
          '--project',
          'dogfood',
        ]);
        expect(code, 0);
        expect(Easyi18nConfig.load(File(configPath())).ref, const IdRef('old'));
        expect(out.toString(), contains('kept existing config'));
      },
    );

    test('rewrites with --force', () async {
      File(configPath()).writeAsStringSync('projectId: old');
      await runInit(['--project-id', 'new', '--force']);
      expect(Easyi18nConfig.load(File(configPath())).ref, const IdRef('new'));
    });

    test('fails without a project id when non-interactive', () async {
      expect(() => runInit([]), throwsA(isA<CliException>()));
    });

    test('prompts for the workspace handle + project slug', () async {
      final r = runner(
        prompt: (label) => label.contains('Workspace') ? 'acme' : 'dogfood',
      );
      await r.run(['--config', configPath(), 'init']);
      final config = Easyi18nConfig.load(File(configPath()));
      expect(config.ref, const HandleRef('acme', 'dogfood'));
    });

    test(
      'falls back to the project id prompt when no handle is given',
      () async {
        final r = runner(
          prompt: (label) => label.contains('Workspace') ? '' : 'proj_prompted',
        );
        await r.run(['--config', configPath(), 'init']);
        expect(
          Easyi18nConfig.load(File(configPath())).ref,
          const IdRef('proj_prompted'),
        );
      },
    );

    test('a prompted lone @ fails without blaming flags', () async {
      final r = runner(
        prompt: (label) => label.contains('Workspace') ? '@' : 'dogfood',
      );
      expect(
        () => r.run(['--config', configPath(), 'init']),
        throwsA(
          isA<CliException>().having(
            (e) => e.message,
            'message',
            contains("easyi18n init sets 'project' without 'workspace'"),
          ),
        ),
      );
    });

    test('accepts the @handle/slug flags', () async {
      await runInit(['--workspace', 'acme', '--project', 'dogfood']);
      final config = Easyi18nConfig.load(File(configPath()));
      expect(config.ref, const HandleRef('acme', 'dogfood'));
    });

    test('rejects --project-id combined with --workspace', () async {
      expect(
        () => runInit(['--project-id', 'p', '--workspace', 'acme']),
        throwsA(isA<CliException>()),
      );
    });

    test('rejects --workspace without --project', () async {
      expect(
        () => runInit(['--workspace', 'acme']),
        throwsA(isA<CliException>()),
      );
    });
  });
}
