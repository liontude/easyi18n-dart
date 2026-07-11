import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/project_ref.dart';
import 'package:test/test.dart';

void main() {
  group('parse', () {
    test('accepts a bare projectId', () {
      final ref = ProjectRef.parse(projectId: 'proj_abc', source: 's');
      expect(ref, IdRef('proj_abc'));
    });

    test('accepts the workspace + project pair', () {
      final ref = ProjectRef.parse(
        workspace: 'acme',
        project: 'dogfood',
        source: 's',
      );
      expect(ref, HandleRef('acme', 'dogfood'));
    });

    test('strips a leading @ from the workspace handle', () {
      final ref = ProjectRef.parse(
        workspace: '@acme',
        project: 'dogfood',
        source: 's',
      );
      expect(ref, HandleRef('acme', 'dogfood'));
    });

    test('rejects projectId combined with workspace/project', () {
      expect(
        () => ProjectRef.parse(
          projectId: 'p',
          workspace: 'acme',
          source: 'easyi18n.yaml',
        ),
        throwsA(
          isA<CliException>().having(
            (e) => e.message,
            'message',
            contains(
              "easyi18n.yaml sets both 'projectId' and "
              "'workspace'/'project'",
            ),
          ),
        ),
      );
      expect(
        () => ProjectRef.parse(projectId: 'p', project: 'dogfood', source: 's'),
        throwsA(isA<CliException>()),
      );
    });

    test('rejects each half of an incomplete handle pair', () {
      expect(
        () => ProjectRef.parse(workspace: 'acme', source: 'easyi18n.yaml'),
        throwsA(
          isA<CliException>().having(
            (e) => e.message,
            'message',
            contains("easyi18n.yaml sets 'workspace' without 'project'"),
          ),
        ),
      );
      expect(
        () => ProjectRef.parse(project: 'dogfood', source: 'easyi18n.yaml'),
        throwsA(
          isA<CliException>().having(
            (e) => e.message,
            'message',
            contains("easyi18n.yaml sets 'project' without 'workspace'"),
          ),
        ),
      );
    });

    test('rejects an absent ref, labeled with the source', () {
      expect(
        () => ProjectRef.parse(source: 'flags'),
        throwsA(
          isA<CliException>().having(
            (e) => e.message,
            'message',
            contains('flags is missing the project ref'),
          ),
        ),
      );
    });

    test('normalizes empty strings to absent (no phantom id ref)', () {
      // An empty projectId must not read as "id form" — that would resolve
      // to ''.
      final ref = ProjectRef.parse(
        projectId: '',
        workspace: '@acme',
        project: 'dogfood',
        source: 's',
      );
      expect(ref, HandleRef('acme', 'dogfood'));
    });

    test('a lone @ strips down to an absent workspace', () {
      expect(
        () => ProjectRef.parse(workspace: '@', project: 'dogfood', source: 's'),
        throwsA(
          isA<CliException>().having(
            (e) => e.message,
            'message',
            contains("sets 'project' without 'workspace'"),
          ),
        ),
      );
    });
  });

  test('describe', () {
    expect(IdRef('proj_abc').describe, 'proj_abc');
    expect(HandleRef('acme', 'dogfood').describe, '@acme/dogfood');
  });

  test('lockSeed is the id, or inert for a handle ref', () {
    expect(IdRef('proj_abc').lockSeed, 'proj_abc');
    expect(HandleRef('acme', 'dogfood').lockSeed, '');
  });

  test('value equality within and across variants', () {
    expect(IdRef('a'), IdRef('a'));
    expect(IdRef('a'), isNot(IdRef('b')));
    expect(HandleRef('w', 's'), HandleRef('w', 's'));
    expect(HandleRef('w', 's'), isNot(HandleRef('w', 'x')));
    expect(HandleRef('w', 's'), isNot(HandleRef('x', 's')));
    expect(IdRef('a'), isNot(HandleRef('a', 'a')));
    expect(IdRef('a').hashCode, IdRef('a').hashCode);
    expect(HandleRef('w', 's').hashCode, HandleRef('w', 's').hashCode);
  });
}
