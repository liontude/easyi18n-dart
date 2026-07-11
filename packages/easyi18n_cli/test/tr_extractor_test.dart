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

  test('an explicit ctx: null is the no-ctx unit, not a dynamic', () {
    // `ctx: null` produces the same runtime token as omitting ctx — demoting
    // it to dynamics would silently drop the string from registration.
    write('lib/b.dart', '''
void f(BuildContext c) {
  c.tr('Delete', ctx: null);
}
''');
    final result = TrExtractor().extractFromDirectory(tmp);
    expect(result.dynamics, isEmpty);
    expect(result.units.single.source, 'Delete');
    expect(result.units.single.ctx, isNull);
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

  test('a non-literal ctx is dynamic, not a wrong no-ctx unit', () {
    write('lib/ctx.dart', '''
const kVerb = 'verb';
void f(BuildContext context) {
  context.tr('Save', ctx: kVerb);
  context.tr('Open', ctx: 'verb');
}
''');
    final result = TrExtractor().extractFromDirectory(tmp);
    expect(result.units.map((u) => '${u.source}|${u.ctx}'), ['Open|verb']);
    expect(result.dynamics, hasLength(1));
    expect(result.dynamics.single.snippet, contains('Save'));
  });

  test('detects a mounted Easyi18nScope at the AST level', () {
    write('lib/main.dart', '''
// A comment mentioning Easyi18nScope does not count.
void main() => runApp(const MyApp());
''');
    expect(TrExtractor().extractFromDirectory(tmp).scopeFile, isNull);

    write('lib/app.dart', '''
Widget build() => Easyi18nScope(projectId: 'p', child: const MyApp());
''');
    final result = TrExtractor().extractFromDirectory(tmp);
    expect(result.scopeFile, 'lib/app.dart');
  });

  test('detects a const/new Easyi18nScope construction', () {
    write('lib/main.dart', '''
Widget build() => const Easyi18nScope(projectId: 'p', child: MyApp());
''');
    expect(TrExtractor().extractFromDirectory(tmp).scopeFile, 'lib/main.dart');
  });
}
