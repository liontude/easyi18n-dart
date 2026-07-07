import 'dart:io';

import 'package:easyi18n_cli/src/config.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('easyi18n_cli_config'));
  tearDown(() => dir.deleteSync(recursive: true));

  File write(String yaml) {
    final f = File('${dir.path}/easyi18n.yaml');
    f.writeAsStringSync(yaml);
    return f;
  }

  group('load', () {
    test('reads all fields', () {
      final config = Easyi18nConfig.load(
        write('''
projectId: proj_abc
baseUrl: http://localhost:8080
format: json
output: lib/i18n
'''),
      );
      expect(config.projectId, 'proj_abc');
      expect(config.baseUrl, 'http://localhost:8080');
      expect(config.format, 'json');
      expect(config.output, 'lib/i18n');
    });

    test('applies defaults for omitted fields', () {
      final config = Easyi18nConfig.load(write('projectId: proj_abc'));
      expect(config.baseUrl, Easyi18nConfig.defaultBaseUrl);
      expect(config.format, Easyi18nConfig.defaultFormat);
      expect(config.output, Easyi18nConfig.defaultOutput);
    });

    test('strips trailing slashes from baseUrl', () {
      final config = Easyi18nConfig.load(
        write('projectId: p\nbaseUrl: https://x.com//'),
      );
      expect(config.baseUrl, 'https://x.com');
    });

    test('throws when the file is missing', () {
      expect(
        () => Easyi18nConfig.load(File('${dir.path}/nope.yaml')),
        throwsA(isA<CliException>()),
      );
    });

    test('throws when projectId is missing', () {
      expect(
        () => Easyi18nConfig.load(write('format: arb')),
        throwsA(isA<CliException>()),
      );
    });

    test('throws on invalid YAML', () {
      expect(
        () => Easyi18nConfig.load(write('projectId: [unclosed')),
        throwsA(isA<CliException>()),
      );
    });

    test('throws when a field has the wrong type', () {
      expect(
        () => Easyi18nConfig.load(write('projectId: p\nformat: 42')),
        throwsA(isA<CliException>()),
      );
    });
  });

  test('toYaml round-trips through load', () {
    final original = Easyi18nConfig(
      projectId: 'proj_xyz',
      baseUrl: 'http://localhost:8080',
      format: 'po',
      output: 'assets/l10n',
    );
    final f = write(original.toYaml());
    final reloaded = Easyi18nConfig.load(f);
    expect(reloaded.projectId, original.projectId);
    expect(reloaded.baseUrl, original.baseUrl);
    expect(reloaded.format, original.format);
    expect(reloaded.output, original.output);
  });
}
