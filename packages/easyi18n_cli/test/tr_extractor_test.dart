import 'dart:io';

import 'package:easyi18n_cli/src/extract/tr_extractor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('ei18n_extract'));
  tearDown(() => tmp.deleteSync(recursive: true));

  void write(String relPath, String content) {
    final f = File(p.join(tmp.path, relPath));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  test('extracts both call shapes with context', () {
    write('lib/a.dart', '''
import 'package:easyi18n/easyi18n.dart';
Widget build(BuildContext context) {
  context.tr('Welcome {name}', {'name': name});
  final s = 'Save'.tr();
  context.tr('Open', ctx: 'verb');
  return Text(s);
}
''');
    final result = TrExtractor().extractFromDirectory(tmp);
    expect(result.dynamics, isEmpty);
    expect(result.units.map((u) => '${u.source}|${u.ctx ?? ''}').toSet(), {
      'Welcome {name}|',
      'Save|',
      'Open|verb',
    });
  });

  test('adjacent string literals concatenate; interpolation is dynamic', () {
    write('lib/b.dart', '''
void f(BuildContext c, String name) {
  c.tr('Hello ' 'world');
  c.tr('Hi \$name');
  c.tr(someVar);
}
''');
    final result = TrExtractor().extractFromDirectory(tmp);
    expect(result.units.map((u) => u.source), contains('Hello world'));
    expect(result.units.length, 1);
    expect(result.dynamics.length, 2);
    expect(result.dynamics.first.file, 'lib/b.dart');
  });

  test('dedups identical (source, ctx) across files, keeps first location', () {
    write('lib/a.dart', "void f(c) => c.tr('Same');\n");
    write('lib/b.dart', "void g(c) => c.tr('Same');\n");
    final result = TrExtractor().extractFromDirectory(tmp);
    expect(result.units.length, 1);
    expect(result.units.single.source, 'Same');
  });

  test('same source with different ctx are distinct units', () {
    write('lib/a.dart', '''
void f(c) {
  c.tr('Post', ctx: 'noun');
  c.tr('Post', ctx: 'verb');
}
''');
    final result = TrExtractor().extractFromDirectory(tmp);
    expect(result.units.length, 2);
  });

  test('ignores tr() on non-context receivers (no false-positive billing)', () {
    write('lib/a.dart', '''
void f(BuildContext context, dynamic table, List items) {
  table.tr('<td>html</td>');
  items.tr('not i18n');
  someService.tr('also not i18n');
  context.tr('Real');
}
''');
    final result = TrExtractor().extractFromDirectory(tmp);
    expect(result.units.map((u) => u.source), ['Real']);
    expect(result.dynamics, isEmpty);
  });

  test('skips generated files', () {
    write('lib/x.g.dart', "void f(c) => c.tr('Generated');\n");
    write('lib/x.freezed.dart', "void f(c) => c.tr('Frozen');\n");
    write('lib/x.dart', "void f(c) => c.tr('Real');\n");
    final result = TrExtractor().extractFromDirectory(tmp);
    expect(result.units.map((u) => u.source), ['Real']);
  });

  test('an unparseable file is skipped, not fatal', () {
    write('lib/broken.dart', 'this is not valid dart <<<');
    write('lib/ok.dart', "void f(c) => c.tr('Ok');\n");
    final result = TrExtractor().extractFromDirectory(tmp);
    expect(result.units.map((u) => u.source), ['Ok']);
  });
}
