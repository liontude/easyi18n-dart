/// Static lint of ICU MessageFormat source strings (`doctor`,
/// flutter-integration §8): a malformed ICU string renders **raw** to the end
/// user, so it must be caught before it ships, not after.
///
/// This is a lint, not a full ICU implementation: it checks the failure modes
/// that actually reach users — unbalanced braces, empty/invalid arguments,
/// unknown argument types, `plural`/`select`/`selectordinal` blocks missing
/// the mandatory `other` branch or using an unknown selector — and
/// deliberately does not judge simple-arg *styles* (`{n, number, ::compact}`
/// etc.), where a wrong style is a formatting nit, not a raw-render.
///
/// Quoting follows ICU's DOUBLE_OPTIONAL apostrophe mode (what the runtime
/// resolver implements): `''` is a literal apostrophe; `'` starts a quoted
/// literal only when followed by `{`, `}` or `#`; a lone `'` is literal.
///
/// NOTE: the parser walk is mirrored in
/// `packages/easyi18n_core/lib/src/i18n/icu_lint.dart` (the backend's
/// source↔target gate) — this published CLI cannot depend on that unpublished
/// package. Fix a parsing bug in BOTH.
library;

/// Lints one ICU message. Returns human-readable problems; empty = clean.
List<String> lintIcuMessage(String message) => _IcuLinter(message).lint();

/// Plural selectors: CLDR categories plus `=N` literals.
const Set<String> _pluralCategories = {
  'zero',
  'one',
  'two',
  'few',
  'many',
  'other',
};

/// Argument types whose body is a `selector{message}` branch list.
const Set<String> _branchTypes = {'plural', 'select', 'selectordinal'};

/// Simple argument types ICU accepts (an unknown type renders raw, so it is
/// flagged; `choice` is deprecated but still parses).
const Set<String> _simpleTypes = {
  'number',
  'date',
  'time',
  'spellout',
  'ordinal',
  'duration',
  'choice',
};

final RegExp _literalPluralSelector = RegExp(r'^=\d+$');
final RegExp _offsetPrefix = RegExp(r'^offset\s*:\s*\d+\s*');
final RegExp _whitespace = RegExp(r'\s');

class _IcuLinter {
  _IcuLinter(this._src);

  final String _src;
  final List<String> _problems = [];
  int _pos = 0;

  bool get _done => _pos >= _src.length;
  String get _char => _src[_pos];

  List<String> lint() {
    _message(topLevel: true);
    return _problems;
  }

  /// Consumes message text until EOF (top level) or an unconsumed `}` (inside
  /// an argument — the caller eats the brace).
  void _message({required bool topLevel}) {
    while (!_done) {
      switch (_char) {
        case "'":
          _quoted();
        case '{':
          _pos++;
          _argument();
        case '}':
          if (!topLevel) return;
          _problems.add("unmatched '}' at offset $_pos");
          _pos++;
        default:
          _pos++;
      }
    }
  }

  /// Handles an apostrophe under DOUBLE_OPTIONAL rules.
  void _quoted() {
    final next = _pos + 1 < _src.length ? _src[_pos + 1] : null;
    if (next == "'") {
      _pos += 2; // escaped literal apostrophe
      return;
    }
    if (next == '{' || next == '}' || next == '#') {
      // Inside a quoted literal, `''` is an escaped apostrophe and quoting
      // continues; only a lone `'` closes it.
      var close = _src.indexOf("'", _pos + 2);
      while (close >= 0 && close + 1 < _src.length && _src[close + 1] == "'") {
        close = _src.indexOf("'", close + 2);
      }
      if (close < 0) {
        _problems.add('unterminated quoted literal starting at offset $_pos');
        _pos = _src.length;
        return;
      }
      _pos = close + 1;
      return;
    }
    _pos++; // lone apostrophe is literal
  }

  /// Parses an argument after its opening `{`.
  void _argument() {
    final name = _until(const {',', '}'});
    if (_done) {
      _problems.add("unbalanced braces: '{' is never closed");
      return;
    }
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      _problems.add("empty argument '{}' at offset $_pos");
    } else if (!_isName(trimmed)) {
      _problems.add(
        "invalid argument name '{$trimmed…' (must not contain whitespace)",
      );
    }

    if (_char == '}') {
      _pos++;
      return;
    }

    _pos++; // the ','
    final type = _until(const {',', '}'}).trim();
    if (_done) {
      _problems.add("unbalanced braces: '{$trimmed' is never closed");
      return;
    }
    final knownSimple = _simpleTypes.contains(type);
    if (!knownSimple && !_branchTypes.contains(type)) {
      _problems.add(
        type.isEmpty
            ? "'{$trimmed,}' is missing its argument type"
            : "unknown argument type '$type' in '{$trimmed, $type…'",
      );
    }
    if (_char == '}') {
      _pos++;
      return; // `{n, number}` — nothing more to check
    }
    _pos++; // the ','

    if (_branchTypes.contains(type)) {
      _branches(trimmed, type);
    } else {
      _skipStyle(trimmed);
    }
  }

  /// Parses `selector{message}` branches until the argument's closing `}`.
  void _branches(String argName, String type) {
    final seen = <String>[];
    var first = true;
    while (true) {
      _skipWhitespace();
      if (_done) {
        _problems.add("unbalanced braces: '{$argName, $type' is never closed");
        return;
      }
      if (_char == '}') {
        _pos++;
        break;
      }
      final selector = _until(const {'{', '}'}).trim();
      if (_done || _char == '}') {
        _problems.add(
          "'$selector' in '{$argName, $type, …}' has no {message} body",
        );
        if (!_done) _pos++;
        break;
      }
      // `offset:N` may only precede the FIRST branch of a plural/selectordinal;
      // it reaches us glued to that selector because `_until` stops at braces.
      var effective = selector;
      if (first && type != 'select') {
        final offset = _offsetPrefix.firstMatch(effective);
        if (offset != null) effective = effective.substring(offset.end);
      }
      first = false;
      if (effective.isEmpty) {
        _problems.add("empty selector in '{$argName, $type, …}'");
      } else if (!_validSelector(type, effective)) {
        _problems.add(
          "invalid $type selector '$effective' in '{$argName, $type, …}'",
        );
      } else {
        seen.add(effective);
      }
      _pos++; // the '{'
      _message(topLevel: false);
      if (_done) {
        _problems.add(
          "unbalanced braces: branch '$effective' of "
          "'{$argName, $type, …}' is never closed",
        );
        return;
      }
      _pos++; // the branch's '}'
    }
    if (!seen.contains('other')) {
      _problems.add(
        "'{$argName, $type, …}' is missing the mandatory 'other' branch",
      );
    }
  }

  /// Consumes a simple-arg style (e.g. `{n, number, ::compact}`) up to the
  /// argument's closing `}`, honoring apostrophe quoting so a quoted brace
  /// (`{d, date, '{'}`) is not counted as structural.
  void _skipStyle(String argName) {
    var depth = 1;
    while (!_done && depth > 0) {
      if (_char == "'") {
        _quoted();
        continue;
      }
      if (_char == '{') depth++;
      if (_char == '}') depth--;
      _pos++;
    }
    if (depth > 0) {
      _problems.add("unbalanced braces: '{$argName' is never closed");
    }
  }

  bool _validSelector(String type, String selector) {
    if (type == 'select') return _isName(selector);
    if (_literalPluralSelector.hasMatch(selector)) return true;
    return _pluralCategories.contains(selector);
  }

  /// ICU pattern identifiers allow any non-syntax, non-whitespace characters
  /// (so `{prénom}` is valid); whitespace inside a name is the authoring
  /// mistake worth flagging. Brace/comma/quote can't reach here (`_until`
  /// stops on them).
  static bool _isName(String s) => !s.contains(_whitespace);

  String _until(Set<String> stops) {
    final start = _pos;
    while (!_done && !stops.contains(_char)) {
      _pos++;
    }
    return _src.substring(start, _pos);
  }

  void _skipWhitespace() {
    while (!_done && _char.trim().isEmpty) {
      _pos++;
    }
  }
}
