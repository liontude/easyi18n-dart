/// Pure text transforms for `easyi18n init` (flutter-integration §4).
///
/// Every function returns the patched content, or **null when the input
/// already satisfies the invariant** — that null is what makes `init`
/// idempotent: a re-run reports "ok" instead of stacking duplicate edits.
/// All file I/O and reporting stay in the command; these are deliberately
/// side-effect-free so they can be tested on fixture strings.
library;

import 'package:yaml/yaml.dart';

import 'project_ref.dart';

/// Version constraint written for the runtime SDK dependency.
const String kRuntimeDependency = '^0.1.0';

/// The offline-floor assets directory (trailing slash: pubspec asset dirs
/// require it to include the folder's files).
const String kAssetsFloorDir = 'assets/easyi18n/';

/// macOS sandbox entitlement the SDK needs for delivery fetches (friction F3).
const String kNetworkClientKey = 'com.apple.security.network.client';

/// Derived CLI state dir (`CliState.dirName`) — cache, never committed.
const String kStateIgnoreEntry = '.easyi18n/';

/// Adds `easyi18n: ^x.y.z` under `dependencies:`. Null when the package is
/// already a dependency (any form: version, path, git, override).
String? addRuntimeDependency(String pubspec) {
  final doc = _tryLoadMap(pubspec);
  final deps = doc?['dependencies'];
  if (deps is Map && deps.containsKey('easyi18n')) return null;

  final lines = pubspec.split('\n');
  final depsIndex = lines.indexWhere((l) => l.trimRight() == 'dependencies:');
  if (depsIndex >= 0) {
    lines.insert(depsIndex + 1, '  easyi18n: $kRuntimeDependency');
    return lines.join('\n');
  }
  return '${_closeBlock(pubspec)}'
      'dependencies:\n'
      '  easyi18n: $kRuntimeDependency\n';
}

/// Registers the assets floor dir under `flutter: assets:`. Null when already
/// listed.
String? addAssetsFloor(String pubspec) {
  final doc = _tryLoadMap(pubspec);
  final flutter = doc?['flutter'];
  if (flutter is Map) {
    final assets = flutter['assets'];
    if (assets is List && assets.contains(kAssetsFloorDir)) return null;
  }

  final lines = pubspec.split('\n');
  final flutterIndex = lines.indexWhere((l) => l.trimRight() == 'flutter:');
  if (flutterIndex < 0) {
    return '${_closeBlock(pubspec)}'
        'flutter:\n'
        '  assets:\n'
        '    - $kAssetsFloorDir\n';
  }

  // Scan the flutter: block (until the next top-level key) for an assets: key.
  var end = lines.length;
  for (var i = flutterIndex + 1; i < lines.length; i++) {
    final l = lines[i];
    if (l.isNotEmpty && !l.startsWith(' ') && !l.startsWith('#')) {
      end = i;
      break;
    }
  }
  for (var i = flutterIndex + 1; i < end; i++) {
    if (lines[i].trimRight() == '  assets:') {
      lines.insert(i + 1, '    - $kAssetsFloorDir');
      return lines.join('\n');
    }
  }
  lines.insert(flutterIndex + 1, '  assets:\n    - $kAssetsFloorDir');
  return lines.join('\n');
}

/// Ensures `com.apple.security.network.client` is `<true/>` in a plist
/// `.entitlements` file. Null when already true; patches a `<false/>` in
/// place; otherwise inserts the pair before the closing `</dict>`.
String? patchEntitlements(String plist) {
  const key = '<key>$kNetworkClientKey</key>';
  final keyIndex = plist.indexOf(key);
  if (keyIndex >= 0) {
    // The value tag follows the key (whitespace between them).
    final after = plist.substring(keyIndex + key.length);
    final valueMatch = RegExp(r'<(true|false)\s*/>').firstMatch(after);
    if (valueMatch == null) return null; // malformed — leave it alone
    if (valueMatch.group(1) == 'true') return null;
    return plist.substring(0, keyIndex + key.length) +
        after.replaceFirst(valueMatch.group(0)!, '<true/>');
  }
  final close = plist.lastIndexOf('</dict>');
  if (close < 0) return null; // not a plist dict — leave it alone
  return '${plist.substring(0, close)}'
      '\t$key\n\t<true/>\n'
      '${plist.substring(close)}';
}

/// Appends the derived-state dir to `.gitignore`. Null when already ignored.
String? addGitignoreEntry(String gitignore) {
  final entries = gitignore.split('\n').map((l) => l.trim());
  if (entries.contains(kStateIgnoreEntry) || entries.contains('.easyi18n')) {
    return null;
  }
  return '${_closeBlock(gitignore)}'
      '# easyi18n derived CLI state (cache)\n'
      '$kStateIgnoreEntry\n';
}

/// The `Easyi18nScope` ref argument line(s) — `projectId:` for an [IdRef], or
/// the `workspace:` + `slug:` pair for a [HandleRef]. [indent] prefixes each
/// emitted line.
String scopeRefArgs(ProjectRef ref, {String indent = '    '}) => switch (ref) {
  IdRef(:final id) => "${indent}projectId: '$id',",
  HandleRef(:final workspace, :final slug) =>
    "${indent}workspace: '$workspace',\n${indent}slug: '$slug',",
};

/// The `Easyi18nScope` wiring printed when `main.dart` can't be patched
/// mechanically.
String scopeSnippet(ProjectRef ref) =>
    '''
import 'package:easyi18n/easyi18n.dart';

runApp(
  Easyi18nScope(
${scopeRefArgs(ref)}
    child: const MyApp(),
  ),
);''';

/// Wraps the app's single trivial `runApp(<expr>)` in an `Easyi18nScope` and
/// adds the SDK import. Returns:
/// - null when the scope is already mounted (idempotent), or
/// - the patched source, or
/// - throws [ScaffoldUnpatchable] when the shape isn't trivial (zero or
///   multiple `runApp(` call sites, or unbalanced parens) — the caller prints
///   [scopeSnippet] instead. Never blindly rewrites a non-trivial `main`.
String? wrapRunApp(String source, ProjectRef ref) {
  if (source.contains('Easyi18nScope')) return null;

  const marker = 'runApp(';
  final first = source.indexOf(marker);
  if (first < 0 || source.indexOf(marker, first + 1) >= 0) {
    throw const ScaffoldUnpatchable('no single runApp(...) call site');
  }

  final argStart = first + marker.length;
  var depth = 1;
  var i = argStart;
  while (i < source.length && depth > 0) {
    final c = source[i];
    // Conservative: a string literal or comment inside the argument can hide
    // parens, and counting through one silently corrupts main.dart. This is
    // not a Dart lexer — bail to the printed snippet instead.
    if (c == "'" ||
        c == '"' ||
        (c == '/' &&
            i + 1 < source.length &&
            (source[i + 1] == '/' || source[i + 1] == '*'))) {
      throw const ScaffoldUnpatchable(
        'runApp argument contains a string or comment',
      );
    }
    if (c == '(') depth++;
    if (c == ')') depth--;
    i++;
  }
  if (depth != 0) {
    throw const ScaffoldUnpatchable('unbalanced parentheses after runApp(');
  }
  final argEnd = i - 1; // the matching ')'
  final arg = source.substring(argStart, argEnd).trim();
  if (arg.isEmpty) {
    throw const ScaffoldUnpatchable('empty runApp() argument');
  }

  final refArgs = scopeRefArgs(ref, indent: '      ');
  final wrapped =
      '${source.substring(0, argStart)}\n'
      '    Easyi18nScope(\n'
      '$refArgs\n'
      '      child: $arg,\n'
      '    ),\n'
      '  ${source.substring(argEnd)}';

  const import = "import 'package:easyi18n/easyi18n.dart';";
  if (wrapped.contains(import)) return wrapped;
  final lines = wrapped.split('\n');
  final lastImport = lines.lastIndexWhere(
    (l) => l.trimLeft().startsWith('import '),
  );
  lines.insert(lastImport + 1, import);
  return lines.join('\n');
}

/// A `main.dart` whose `runApp` shape is too risky to rewrite mechanically.
class ScaffoldUnpatchable implements Exception {
  const ScaffoldUnpatchable(this.reason);
  final String reason;
}

Map<Object?, Object?>? _tryLoadMap(String yaml) {
  try {
    final doc = loadYaml(yaml);
    return doc is Map ? doc : null;
  } on YamlException {
    return null;
  }
}

/// Existing content trimmed and closed with a blank separator line, ready to
/// have a new top-level block appended ('' when there was no content).
String _closeBlock(String s) {
  final t = s.trimRight();
  return t.isEmpty ? '' : '$t\n\n';
}
