import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/src/commands/init_command.dart';
import 'package:easyi18n_cli/src/config.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late CliLogger logger;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('easyi18n_cli_init');
    logger = CliLogger(out: StringBuffer(), err: StringBuffer());
  });
  tearDown(() => dir.deleteSync(recursive: true));

  CommandRunner<int> runner({String? Function(String)? prompt}) {
    final r = CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
    r.addCommand(InitCommand(logger: logger, prompt: prompt ?? (_) => null));
    return r;
  }

  String configPath() => '${dir.path}/easyi18n.yaml';

  test('writes a config from flags', () async {
    final code = await runner().run([
      '--config',
      configPath(),
      'init',
      '--project-id',
      'proj_abc',
      '--base-url',
      'http://localhost:8080',
      '--format',
      'json',
    ]);

    expect(code, 0);
    final config = Easyi18nConfig.load(File(configPath()));
    expect(config.projectId, 'proj_abc');
    expect(config.baseUrl, 'http://localhost:8080');
    expect(config.format, 'json');
    expect(config.output, Easyi18nConfig.defaultOutput);
  });

  test('refuses to overwrite an existing config', () async {
    File(configPath()).writeAsStringSync('projectId: old');
    expect(
      () => runner().run([
        '--config',
        configPath(),
        'init',
        '--project-id',
        'new',
      ]),
      throwsA(
        isA<CliException>().having(
          (e) => e.message,
          'message',
          contains('--force'),
        ),
      ),
    );
  });

  test('overwrites with --force', () async {
    File(configPath()).writeAsStringSync('projectId: old');
    await runner().run([
      '--config',
      configPath(),
      'init',
      '--project-id',
      'new',
      '--force',
    ]);

    expect(Easyi18nConfig.load(File(configPath())).projectId, 'new');
  });

  test('fails without a project id when non-interactive', () async {
    expect(
      () => runner().run(['--config', configPath(), 'init']),
      throwsA(isA<CliException>()),
    );
  });

  test('falls back to the interactive prompt for the project id', () async {
    await runner(
      prompt: (_) => 'proj_prompted',
    ).run(['--config', configPath(), 'init']);

    expect(Easyi18nConfig.load(File(configPath())).projectId, 'proj_prompted');
  });
}
