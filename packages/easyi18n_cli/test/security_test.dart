import 'package:easyi18n_cli/src/logger.dart';
import 'package:easyi18n_cli/src/security.dart';
import 'package:test/test.dart';

void main() {
  group('warnOnUntrustedTarget', () {
    late StringBuffer err;
    late CliLogger logger;

    setUp(() {
      err = StringBuffer();
      logger = CliLogger(out: StringBuffer(), err: err);
    });

    test('is silent for the default https origin', () {
      warnOnUntrustedTarget('https://api.easyi18n.com', logger);
      expect(err.toString(), isEmpty);
    });

    test('is silent for the local emulator over http', () {
      warnOnUntrustedTarget('http://localhost:8080', logger);
      expect(err.toString(), isEmpty);
    });

    test('warns when the token would go to a non-default host', () {
      warnOnUntrustedTarget('https://evil.example.com', logger);
      expect(err.toString(), contains('evil.example.com'));
    });

    test('warns about plaintext http to a remote host', () {
      warnOnUntrustedTarget('http://evil.example.com', logger);
      expect(err.toString(), contains('plaintext'));
    });
  });
}
