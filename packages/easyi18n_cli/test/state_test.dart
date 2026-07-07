import 'dart:io';

import 'package:easyi18n_cli/src/state.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('easyi18n_cli_state');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('CliState', () {
    test('round-trips version + pulledAt', () {
      final file = CliState.fileFor('${dir.path}/easyi18n.yaml');
      final at = DateTime.utc(2026, 7, 4, 12, 30);
      CliState(version: '2026.07.04.2', pulledAt: at).save(file);

      final loaded = CliState.load(file);
      expect(loaded.version, '2026.07.04.2');
      expect(loaded.pulledAt, at);
      expect(file.path, contains('.easyi18n'));
    });

    test('missing or corrupt file loads as empty state', () {
      final file = CliState.fileFor('${dir.path}/easyi18n.yaml');
      expect(CliState.load(file).version, isNull);

      file.parent.createSync(recursive: true);
      file.writeAsStringSync('not json');
      expect(CliState.load(file).version, isNull);
    });
  });

  group('parsePublishVersion / comparePublishVersions', () {
    test('parses both forms; legacy is an implicit .1', () {
      expect(parsePublishVersion('2026.07.04.3'), (date: 20260704, n: 3));
      expect(parsePublishVersion('2026.07.04'), (date: 20260704, n: 1));
      expect(parsePublishVersion('garbage'), isNull);
    });

    test('orders numerically within a day (.10 after .9)', () {
      expect(
        comparePublishVersions('2026.07.04.9', '2026.07.04.10'),
        lessThan(0),
      );
      expect(comparePublishVersions('2026.07.04', '2026.07.04.1'), 0);
      expect(
        comparePublishVersions('2026.07.03.99', '2026.07.04.1'),
        lessThan(0),
      );
    });
  });
}
