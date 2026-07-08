import 'package:easyi18n_cli/src/logger.dart';
import 'package:test/test.dart';

void main() {
  late StringBuffer out;
  late StringBuffer err;
  late CliLogger logger;

  setUp(() {
    out = StringBuffer();
    err = StringBuffer();
    logger = CliLogger(out: out, err: err);
  });

  test('strips the escape byte from an ANSI sequence', () {
    logger.info('\x1b[31mred\x1b[0m');
    expect(out.toString(), '[31mred[0m\n');
  });

  test('strips a bare carriage return used to overwrite the line', () {
    logger.error('boom\rEverything up to date.');
    expect(err.toString(), 'error: boomEverything up to date.\n');
  });

  test('keeps tabs and newlines', () {
    logger.info('a\tb\nc');
    expect(out.toString(), 'a\tb\nc\n');
  });
}
