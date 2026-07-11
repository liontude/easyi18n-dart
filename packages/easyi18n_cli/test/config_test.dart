import 'dart:io';

import 'package:easyi18n_cli/src/config.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/project_ref.dart';
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
      expect(config.ref, IdRef('proj_abc'));
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

    test('throws when no project ref is set', () {
      expect(
        () => Easyi18nConfig.load(write('format: arb')),
        throwsA(isA<CliException>()),
      );
    });

    test('reads the @handle/slug ref', () {
      final config = Easyi18nConfig.load(
        write('workspace: acme\nproject: dogfood'),
      );
      expect(config.ref, HandleRef('acme', 'dogfood'));
      expect(config.describeRef, '@acme/dogfood');
    });

    test('strips a leading @ from the workspace handle', () {
      final config = Easyi18nConfig.load(
        write('workspace: "@acme"\nproject: dogfood'),
      );
      expect(config.ref, HandleRef('acme', 'dogfood'));
      expect(config.describeRef, '@acme/dogfood');
      // The written config must be re-loadable (a bare @ is invalid YAML).
      expect(config.toYaml(), contains('workspace: acme'));
    });

    test('projectId form is not a handle ref', () {
      final config = Easyi18nConfig.load(write('projectId: proj_abc'));
      expect(config.ref, IdRef('proj_abc'));
      expect(config.describeRef, 'proj_abc');
    });

    test('rejects projectId combined with workspace/project', () {
      expect(
        () => Easyi18nConfig.load(
          write('projectId: p\nworkspace: acme\nproject: dogfood'),
        ),
        throwsA(isA<CliException>()),
      );
    });

    test('rejects workspace without project', () {
      expect(
        () => Easyi18nConfig.load(write('workspace: acme')),
        throwsA(isA<CliException>()),
      );
    });

    test('rejects project without workspace', () {
      expect(
        () => Easyi18nConfig.load(write('project: dogfood')),
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

    test('throws on a scheme-less baseUrl instead of crashing later', () {
      expect(
        () =>
            Easyi18nConfig.load(write('projectId: p\nbaseUrl: localhost:8080')),
        throwsA(isA<CliException>()),
      );
    });
  });

  test('toYaml round-trips the projectId form through load', () {
    final original = Easyi18nConfig(
      ref: IdRef('proj_xyz'),
      baseUrl: 'http://localhost:8080',
      format: 'po',
      output: 'assets/l10n',
    );
    final reloaded = Easyi18nConfig.load(write(original.toYaml()));
    expect(reloaded.ref, original.ref);
    expect(reloaded.baseUrl, original.baseUrl);
    expect(reloaded.format, original.format);
    expect(reloaded.output, original.output);
  });

  test('toYaml round-trips the @handle/slug form through load', () {
    final original = Easyi18nConfig(
      ref: HandleRef('acme', 'dogfood'),
      baseUrl: 'http://localhost:8080',
    );
    final reloaded = Easyi18nConfig.load(write(original.toYaml()));
    expect(reloaded.ref, HandleRef('acme', 'dogfood'));
  });
}
