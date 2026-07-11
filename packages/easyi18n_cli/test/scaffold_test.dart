import 'package:easyi18n_cli/src/project_ref.dart';
import 'package:easyi18n_cli/src/scaffold.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('addRuntimeDependency', () {
    const pubspec = '''
name: demo
dependencies:
  flutter:
    sdk: flutter
''';

    test('inserts under dependencies:', () {
      final out = addRuntimeDependency(pubspec)!;
      expect(out, contains('  easyi18n: $kRuntimeDependency'));
      final doc = loadYaml(out) as Map;
      expect((doc['dependencies'] as Map).containsKey('easyi18n'), isTrue);
      // The pre-existing dep survived the line surgery.
      expect((doc['dependencies'] as Map).containsKey('flutter'), isTrue);
    });

    test('is idempotent for any dependency form', () {
      expect(
        addRuntimeDependency('dependencies:\n  easyi18n: ^0.1.0\n'),
        isNull,
      );
      expect(
        addRuntimeDependency('dependencies:\n  easyi18n:\n    path: ../x\n'),
        isNull,
      );
    });

    test('appends a dependencies block when the section is missing', () {
      final out = addRuntimeDependency('name: demo\n')!;
      final doc = loadYaml(out) as Map;
      expect((doc['dependencies'] as Map)['easyi18n'], kRuntimeDependency);
    });
  });

  group('addAssetsFloor', () {
    test('inserts into an existing flutter.assets list', () {
      final out = addAssetsFloor('flutter:\n  assets:\n    - assets/img/\n')!;
      final assets =
          ((loadYaml(out) as Map)['flutter'] as Map)['assets'] as List;
      expect(assets, containsAll(['assets/img/', kAssetsFloorDir]));
    });

    test('adds assets: to a flutter block that lacks it', () {
      final out = addAssetsFloor('flutter:\n  uses-material-design: true\n')!;
      final flutter = (loadYaml(out) as Map)['flutter'] as Map;
      expect(flutter['assets'], [kAssetsFloorDir]);
      expect(flutter['uses-material-design'], isTrue);
    });

    test('appends a flutter block when missing entirely', () {
      final out = addAssetsFloor('name: demo\n')!;
      expect(((loadYaml(out) as Map)['flutter'] as Map)['assets'], [
        kAssetsFloorDir,
      ]);
    });

    test('is idempotent', () {
      expect(
        addAssetsFloor('flutter:\n  assets:\n    - $kAssetsFloorDir\n'),
        isNull,
      );
    });

    test('does not touch an assets: key of another top-level section', () {
      // `assets:` under a sibling section must not be mistaken for
      // flutter.assets.
      final out = addAssetsFloor(
        'other:\n  assets:\n    - x/\nflutter:\n  uses-material-design: true\n',
      )!;
      final doc = loadYaml(out) as Map;
      expect((doc['flutter'] as Map)['assets'], [kAssetsFloorDir]);
      expect((doc['other'] as Map)['assets'], ['x/']);
    });
  });

  group('patchEntitlements', () {
    const plist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
\t<key>com.apple.security.app-sandbox</key>
\t<true/>
</dict>
</plist>
''';

    test('inserts the key before the closing dict', () {
      final out = patchEntitlements(plist)!;
      expect(out, contains('<key>$kNetworkClientKey</key>'));
      expect(out.indexOf(kNetworkClientKey), lessThan(out.indexOf('</dict>')));
      // The existing entitlement survived.
      expect(out, contains('com.apple.security.app-sandbox'));
    });

    test('flips an explicit false to true', () {
      final withFalse = plist.replaceFirst(
        '</dict>',
        '\t<key>$kNetworkClientKey</key>\n\t<false/>\n</dict>',
      );
      final out = patchEntitlements(withFalse)!;
      expect(out, isNot(contains('<false/>')));
      expect(out, contains('<key>$kNetworkClientKey</key>'));
    });

    test('is idempotent when already true', () {
      final patched = patchEntitlements(plist)!;
      expect(patchEntitlements(patched), isNull);
    });

    test('leaves a non-plist file alone', () {
      expect(patchEntitlements('not a plist'), isNull);
    });
  });

  group('addGitignoreEntry', () {
    test('appends the state dir', () {
      final out = addGitignoreEntry('build/\n')!;
      expect(out, contains('build/'));
      expect(out.split('\n'), contains(kStateIgnoreEntry));
    });

    test('creates content for an empty file', () {
      expect(addGitignoreEntry('')!.split('\n'), contains(kStateIgnoreEntry));
    });

    test('is idempotent (with or without the slash)', () {
      expect(addGitignoreEntry('$kStateIgnoreEntry\n'), isNull);
      expect(addGitignoreEntry('.easyi18n\n'), isNull);
    });
  });

  group('wrapRunApp', () {
    const arrowMain = '''
import 'package:flutter/material.dart';

void main() => runApp(const MyApp());
''';

    test('wraps a trivial arrow main and adds the import', () {
      final out = wrapRunApp(arrowMain, const IdRef('p1'))!;
      expect(out, contains("import 'package:easyi18n/easyi18n.dart';"));
      expect(out, contains('Easyi18nScope('));
      expect(out, contains("projectId: 'p1'"));
      expect(out, contains('child: const MyApp()'));
      // Balanced: same net paren count as a valid wrap.
      expect('('.allMatches(out).length, ')'.allMatches(out).length);
    });

    test('wraps with the @handle/slug ref', () {
      final out = wrapRunApp(arrowMain, const HandleRef('acme', 'dogfood'))!;
      expect(out, contains("workspace: 'acme'"));
      expect(out, contains("slug: 'dogfood'"));
      expect(out, isNot(contains('projectId:')));
      expect('('.allMatches(out).length, ')'.allMatches(out).length);
    });

    test('wraps a block-body main', () {
      const blockMain = '''
void main() {
  runApp(const MyApp());
}
''';
      final out = wrapRunApp(blockMain, const IdRef('p1'))!;
      expect(out, contains('child: const MyApp()'));
    });

    test('is idempotent once the scope is mounted', () {
      final out = wrapRunApp(arrowMain, const IdRef('p1'))!;
      expect(wrapRunApp(out, const IdRef('p1')), isNull);
    });

    test('refuses an argument containing strings or comments', () {
      // A `)` inside a literal or comment would defeat the paren counter and
      // silently corrupt main.dart — the conservative answer is the snippet.
      expect(
        () => wrapRunApp(
          "void main() => runApp(MyApp(title: ':)'));",
          const IdRef('p1'),
        ),
        throwsA(isA<ScaffoldUnpatchable>()),
      );
      expect(
        () => wrapRunApp(
          'void main() => runApp(MyApp(\n  // :) tricky\n));',
          const IdRef('p1'),
        ),
        throwsA(isA<ScaffoldUnpatchable>()),
      );
    });

    test('refuses zero or multiple runApp call sites', () {
      expect(
        () => wrapRunApp('void main() {}', const IdRef('p1')),
        throwsA(isA<ScaffoldUnpatchable>()),
      );
      expect(
        () => wrapRunApp(
          'void main() { runApp(A()); }\nvoid alt() { runApp(B()); }',
          const IdRef('p1'),
        ),
        throwsA(isA<ScaffoldUnpatchable>()),
      );
    });
  });
}
