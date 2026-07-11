import 'dart:convert';
import 'dart:io';

import 'package:easyi18n_cli/src/icu_lint.dart';
import 'package:test/test.dart';

void main() {
  group('shared lint vectors', () {
    // Copied verbatim from packages/easyi18n_core/test/icu_lint_vectors.json
    // (the canonical file) — core's icu_lint_test fails if the copies drift.
    final raw =
        jsonDecode(File('test/icu_lint_vectors.json').readAsStringSync())
            as Map<String, dynamic>;

    for (final v in (raw['vectors'] as List).cast<Map<String, dynamic>>()) {
      test(v['name'] as String, () {
        final problems = lintIcuMessage(v['message'] as String).join('\n');
        final expected = (v['problems'] as List).cast<String>();
        if (expected.isEmpty) {
          expect(problems, isEmpty);
        } else {
          for (final substring in expected) {
            expect(problems, contains(substring));
          }
        }
      });
    }
  });
  void expectClean(String message) {
    expect(lintIcuMessage(message), isEmpty, reason: message);
  }

  void expectProblem(String message, Pattern problem) {
    expect(
      lintIcuMessage(message).join('\n'),
      contains(problem),
      reason: message,
    );
  }

  group('clean messages', () {
    test('plain text and placeholders', () {
      expectClean('Hello');
      expectClean('Welcome {name}');
      expectClean('{a} and {b} and {a}');
      expectClean('100% sure');
    });

    test('apostrophes (DOUBLE_OPTIONAL quoting)', () {
      expectClean("it's a test");
      expectClean("l'article {n}");
      expectClean("literal '{' brace");
      expectClean("literal '}' brace");
      expectClean("quoted '{name}' is not an argument");
      expectClean("escaped '' apostrophe");
      expectClean("quoted with escape '{it''s}'");
    });

    test('simple typed arguments', () {
      expectClean('{n, number}');
      expectClean('{n, number, ::compact}');
      expectClean('{when, date, yyyy-MM-dd}');
    });

    test('quoted braces inside a simple-arg style', () {
      expectClean("{d, date, '{'}");
      expectClean("{d, date, '}'}");
    });

    test('non-ASCII argument names and select selectors', () {
      expectClean('Bonjour {prénom}');
      expectClean('{g, select, männlich{er} weiblich{sie} other{sie}}');
    });

    test('plural / select / selectordinal', () {
      expectClean('{count, plural, one{# message} other{# messages}}');
      expectClean('{count, plural, =0{none} one{one} other{#}}');
      expectClean(
        '{count, plural, offset:1 one{you and one} other{you and #}}',
      );
      expectClean('{g, select, male{he} female{she} other{they}}');
      expectClean(
        '{rank, selectordinal, one{#st} two{#nd} few{#rd} other{#th}}',
      );
      expectClean(
        '{count, plural, one{{name} has # item} other{{name} has # items}}',
      );
    });
  });

  group('problems', () {
    test('unbalanced braces', () {
      expectProblem('Unclosed {', 'never closed');
      expectProblem('Unmatched }', "unmatched '}'");
      expectProblem('{count, plural, other{#}', 'never closed');
    });

    test('empty and invalid arguments', () {
      expectProblem('empty {} arg', 'empty argument');
      expectProblem('{na me}', 'invalid argument name');
    });

    test('missing or unknown argument type', () {
      expectProblem('{n,}', 'missing its argument type');
      expectProblem(
        '{n, plurral, one{x} other{y}}',
        "unknown argument type 'plurral'",
      );
    });

    test('offset after the first branch is rejected', () {
      expectProblem(
        '{n, plural, one{x} offset:1 other{y}}',
        'invalid plural selector',
      );
    });

    test('plural without other', () {
      expectProblem('{count, plural, one{# item}}', "mandatory 'other'");
    });

    test('select without other', () {
      expectProblem('{g, select, male{he} female{she}}', "mandatory 'other'");
    });

    test('invalid plural selector', () {
      expectProblem(
        '{count, plural, uno{x} other{y}}',
        "invalid plural selector 'uno'",
      );
    });

    test('selector without a body', () {
      expectProblem('{count, plural, one other{x}}', 'invalid plural selector');
      expectProblem('{count, plural, other}', 'no {message} body');
    });

    test('unterminated quoted literal', () {
      expectProblem("broken '{ quote", 'unterminated quoted literal');
    });

    test('problems inside a branch body surface', () {
      expectProblem('{count, plural, other{unclosed { here}}', 'never closed');
    });
  });
}
