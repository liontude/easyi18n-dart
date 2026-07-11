import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;

import 'source_unit.dart';

/// Statically extracts `tr()` source strings from a Dart source tree, the
/// deterministic counterpart to the runtime auto-capture: it sees every literal
/// `tr()` call whether or not it runs. Two call shapes are recognized:
///
///   context.tr('Welcome {name}', {...}, ctx: 'noun')   // canonical
///   'Welcome {name}'.tr({...})                           // sugar
///
/// Only string-literal sources are extractable; a `tr(variable)` or an
/// interpolated `tr('Hi $name')` is reported as a [DynamicUnit] (it relies on
/// auto-capture). Parsing is syntax-only (no resolution) so it is fast and works
/// on a tree that doesn't compile.
class TrExtractor {
  /// Scans every `.dart` file under [dir] (recursively), skipping generated
  /// outputs. Returns deduped, sorted units plus the non-extractable calls.
  ExtractionResult extractFromDirectory(Directory dir, {String? relativeTo}) {
    final base = relativeTo ?? dir.path;
    final units = <String, ExtractedUnit>{};
    final dynamics = <DynamicUnit>[];
    String? scopeFile;
    var filesScanned = 0;

    for (final file in _dartFiles(dir)) {
      filesScanned++;
      final String content;
      try {
        content = file.readAsStringSync();
      } on FileSystemException {
        continue;
      }
      final ParseStringResult parsed;
      try {
        parsed = parseString(
          content: content,
          path: file.path,
          throwIfDiagnostics: false,
        );
      } catch (_) {
        // An unparseable file shouldn't abort the whole scan.
        continue;
      }
      final rel = p.relative(file.path, from: base);
      final visitor = _TrVisitor(parsed.lineInfo, rel);
      parsed.unit.visitChildren(visitor);
      for (final u in visitor.units) {
        units.putIfAbsent(u.identity, () => u);
      }
      dynamics.addAll(visitor.dynamics);
      if (visitor.sawScope) scopeFile ??= rel;
    }

    final sorted = units.values.toList()
      ..sort((a, b) => a.identity.compareTo(b.identity));
    return ExtractionResult(
      units: sorted,
      dynamics: dynamics,
      filesScanned: filesScanned,
      scopeFile: scopeFile,
    );
  }

  Iterable<File> _dartFiles(Directory dir) sync* {
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('.g.dart') ||
          entity.path.endsWith('.freezed.dart')) {
        continue;
      }
      yield entity;
    }
  }
}

class _TrVisitor extends RecursiveAstVisitor<void> {
  _TrVisitor(this._lineInfo, this._file);

  final LineInfo _lineInfo;
  final String _file;
  final units = <ExtractedUnit>[];
  final dynamics = <DynamicUnit>[];

  /// Whether this file constructs an `Easyi18nScope(...)` (the SDK wiring
  /// `doctor` verifies). AST-level, so comments/strings don't count.
  var sawScope = false;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'tr') _handle(node);
    // Without resolution, a plain `Easyi18nScope(...)` parses as a method
    // invocation; `const`/`new` forms are InstanceCreationExpressions below.
    if (node.methodName.name == 'Easyi18nScope' && node.target == null) {
      sawScope = true;
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (node.constructorName.type.name.lexeme == 'Easyi18nScope') {
      sawScope = true;
    }
    super.visitInstanceCreationExpression(node);
  }

  void _handle(MethodInvocation node) {
    final line = _lineInfo.getLocation(node.offset).lineNumber;
    final target = node.target;

    // Is this one of OUR tr() shapes? Parsing is syntax-only (no type
    // resolution), so gate on the conventional BuildContext receivers to avoid
    // capturing - and billing - unrelated methods named `tr` (e.g.
    // `table.tr('<td>html</td>')`, `items.tr(...)`):
    //   'literal'.tr(...)               → receiver is a StringLiteral (sugar)
    //   tr('x') / context.tr('x')       → no receiver, or a context-like one
    // An arbitrary `<expr>.tr('literal')` is rejected (the runtime auto-capture
    // still catches a genuine i18n call we skip here - false negatives are free,
    // false positives cost a translation).
    const contextNames = {'context', 'ctx', 'c'};
    final isSugar = target is StringLiteral;
    final isCanonical =
        target == null ||
        (target is SimpleIdentifier && contextNames.contains(target.name));
    if (!isSugar && !isCanonical) return;

    final positional = node.argumentList.arguments.where(
      (a) => a is! NamedArgument,
    );

    // The source is the string the method receives: the receiver for the
    // `'x'.tr()` sugar, else the first positional arg for `context.tr('x')`.
    final Expression? sourceExpr;
    if (isSugar) {
      sourceExpr = target;
    } else if (positional.isNotEmpty) {
      sourceExpr = positional.first.argumentExpression;
    } else {
      return; // a bare `.tr()` with no string - not one of our call shapes.
    }

    final value = sourceExpr is StringLiteral ? sourceExpr.stringValue : null;
    if (value == null) {
      dynamics.add(
        DynamicUnit(file: _file, line: line, snippet: _snippet(node)),
      );
      return;
    }
    final (ctx, ctxIsStatic) = _ctxArg(node);
    if (!ctxIsStatic) {
      // A non-literal ctx changes the messageToken; registering the no-ctx
      // unit would be the WRONG string. Only auto-capture sees the real one.
      dynamics.add(
        DynamicUnit(file: _file, line: line, snippet: _snippet(node)),
      );
      return;
    }
    units.add(ExtractedUnit(source: value, ctx: ctx, file: _file, line: line));
  }

  /// The `ctx:` argument value, plus whether it is statically known (absent
  /// and an explicit `ctx: null` both count as known-null — they produce the
  /// same runtime token; a non-literal expression does not).
  (String?, bool) _ctxArg(MethodInvocation node) {
    for (final a in node.argumentList.arguments) {
      if (a is NamedArgument && a.name.lexeme == 'ctx') {
        final v = a.argumentExpression;
        if (v is NullLiteral) return (null, true);
        final literal = v is StringLiteral ? v.stringValue : null;
        return (literal, literal != null);
      }
    }
    return (null, true);
  }

  String _snippet(AstNode node) {
    final s = node.toSource().replaceAll(RegExp(r'\s+'), ' ');
    return s.length > 80 ? '${s.substring(0, 77)}...' : s;
  }
}
