/// CLDR plural categories for a given language code (data-model §4.9
/// plurals). Used by the UI plural editor and by formatters that emit
/// language-specific plural blocks (ARB ICU, iOS `.stringsdict`, Android
/// `<plurals>`).
///
/// Source: Unicode CLDR plural rules v45 (matches Flutter's `intl` package).
/// Only the language portion of the locale is consulted — `pt-BR` and
/// `pt-PT` share categories with `pt`. Region-specific overrides post-v1.
library;

/// CLDR plural categories. The set returned by [pluralFormsFor] is a subset
/// of these.
enum PluralCategory { zero, one, two, few, many, other }

/// Returns the ordered set of plural categories that [langCode] uses.
/// `other` is always present (every CLDR language has it). Order is
/// canonical CLDR order — important for golden tests where the emitted
/// `{count, plural, ...}` strings must be byte-stable.
List<PluralCategory> pluralFormsFor(String langCode) {
  final lang = _baseLang(langCode);
  return _rules[lang] ?? const [PluralCategory.other];
}

String _baseLang(String code) {
  final i = code.indexOf(RegExp('[-_]'));
  return (i < 0 ? code : code.substring(0, i)).toLowerCase();
}

const List<PluralCategory> _oneOther = [
  PluralCategory.one,
  PluralCategory.other,
];

const List<PluralCategory> _otherOnly = [PluralCategory.other];

const Map<String, List<PluralCategory>> _rules = {
  // 1 form
  'ja': _otherOnly,
  'ko': _otherOnly,
  'zh': _otherOnly,
  'th': _otherOnly,
  'vi': _otherOnly,
  'id': _otherOnly,
  'ms': _otherOnly,
  'my': _otherOnly,
  'lo': _otherOnly,
  'km': _otherOnly,

  // 2 forms (one, other)
  'en': _oneOther,
  'es': _oneOther,
  'de': _oneOther,
  'it': _oneOther,
  'pt': _oneOther,
  'nl': _oneOther,
  'sv': _oneOther,
  'da': _oneOther,
  'no': _oneOther,
  'nb': _oneOther,
  'nn': _oneOther,
  'fi': _oneOther,
  'tr': _oneOther,
  'hu': _oneOther,
  'el': _oneOther,
  'he': _oneOther,
  'bg': _oneOther,
  'et': _oneOther,
  'eu': _oneOther,
  'ca': _oneOther,
  'gl': _oneOther,

  // French + variants: 1/many/other (CLDR v45 added many for French)
  'fr': [PluralCategory.one, PluralCategory.many, PluralCategory.other],

  // Polish: one/few/many/other
  'pl': [
    PluralCategory.one,
    PluralCategory.few,
    PluralCategory.many,
    PluralCategory.other,
  ],

  // Russian / Ukrainian / Belarusian / Serbian / Croatian / Bosnian: one/few/many/other
  'ru': [
    PluralCategory.one,
    PluralCategory.few,
    PluralCategory.many,
    PluralCategory.other,
  ],
  'uk': [
    PluralCategory.one,
    PluralCategory.few,
    PluralCategory.many,
    PluralCategory.other,
  ],
  'be': [
    PluralCategory.one,
    PluralCategory.few,
    PluralCategory.many,
    PluralCategory.other,
  ],
  'sr': [
    PluralCategory.one,
    PluralCategory.few,
    PluralCategory.other,
  ],
  'hr': [
    PluralCategory.one,
    PluralCategory.few,
    PluralCategory.other,
  ],
  'bs': [
    PluralCategory.one,
    PluralCategory.few,
    PluralCategory.other,
  ],

  // Czech / Slovak: one/few/many/other
  'cs': [
    PluralCategory.one,
    PluralCategory.few,
    PluralCategory.many,
    PluralCategory.other,
  ],
  'sk': [
    PluralCategory.one,
    PluralCategory.few,
    PluralCategory.many,
    PluralCategory.other,
  ],

  // Arabic: full 6-form
  'ar': [
    PluralCategory.zero,
    PluralCategory.one,
    PluralCategory.two,
    PluralCategory.few,
    PluralCategory.many,
    PluralCategory.other,
  ],

  // Welsh: full 6-form too
  'cy': [
    PluralCategory.zero,
    PluralCategory.one,
    PluralCategory.two,
    PluralCategory.few,
    PluralCategory.many,
    PluralCategory.other,
  ],

  // Romanian: one/few/other
  'ro': [
    PluralCategory.one,
    PluralCategory.few,
    PluralCategory.other,
  ],
  // Lithuanian: one/few/many/other
  'lt': [
    PluralCategory.one,
    PluralCategory.few,
    PluralCategory.many,
    PluralCategory.other,
  ],
  // Latvian: zero/one/other
  'lv': [
    PluralCategory.zero,
    PluralCategory.one,
    PluralCategory.other,
  ],
  // Irish Gaelic: one/two/few/many/other
  'ga': [
    PluralCategory.one,
    PluralCategory.two,
    PluralCategory.few,
    PluralCategory.many,
    PluralCategory.other,
  ],
};

extension PluralCategoryName on PluralCategory {
  /// CLDR canonical lowercase name (`one`, `other`, `few`, …). Used by
  /// formatters to emit the plural label.
  String get cldrName => switch (this) {
    PluralCategory.zero => 'zero',
    PluralCategory.one => 'one',
    PluralCategory.two => 'two',
    PluralCategory.few => 'few',
    PluralCategory.many => 'many',
    PluralCategory.other => 'other',
  };
}
