import 'package:intl/message_format.dart';

import '../contract/i18n/text_hash.dart';
import '../contract/models/translation_value.dart';
import 'bundle_stack.dart';

/// Resolves `tr(source, {args})` against a [BundleStack].
///
/// **Token parity (load-bearing):** the source is hashed as **opaque text**,
/// via `messageTokenForValue(TranslationText(source), ctx:)`, and NEVER parsed
/// as ICU. The backend tokenizes the same way, so the bytes match. Parsing an
/// inline-ICU plural source here would canonicalize it to `{count, plural, ...}`
/// and produce a DIFFERENT token, so every lookup would miss. The plural still
/// renders because the localized ICU lives in the bundle message
/// (`messages[slug]`) and [MessageFormat] resolves it; the raw source is both
/// the token preimage and the offline fallback.
class MessageResolver {
  const MessageResolver();

  String resolve({
    required String source,
    String? ctx,
    Map<String, Object> args = const {},
    required String locale,
    required BundleStack stack,
    void Function()? onMiss,
  }) {
    final token = _tokenFor(source, ctx);
    for (final bundle in stack.layers) {
      final slug = bundle.tokenIndex[token];
      if (slug == null) continue;
      final pattern = bundle.messages[slug];
      if (pattern == null) continue; // indexed but untranslated here → fall on.
      return _render(pattern, locale, args);
    }
    // Raw fallback: no rendered message for this source. Signal a miss (the
    // auto-capture hook reports it; the backend dedups against registered keys).
    onMiss?.call();
    // Offline / untranslated floor: the raw source IS the base-language string
    // and may itself carry ICU placeholders, so render it through the same path
    // (a `tr('Hi {name}', {...})` with no bundle still interpolates `name`).
    return _render(source, locale, args);
  }

  String _render(String pattern, String locale, Map<String, Object> args) {
    try {
      return MessageFormat(pattern, locale: locale).format(args);
    } catch (_) {
      // Malformed pattern (e.g. unbalanced literal brace) → show it verbatim
      // rather than crash the widget tree.
      return pattern;
    }
  }
}

/// `resolve()` runs on every widget rebuild and the (source, ctx) → token hash
/// is pure, so memoize it behind a bounded cache instead of re-hashing each
/// frame. Cleared wholesale when it grows past the cap (call sites are a small,
/// stable set in practice, so a plain map amortizes to hits).
final Map<String, String> _tokenCache = {};
const int _tokenCacheMax = 4096;

String _tokenFor(String source, String? ctx) {
  // Length-prefixed ctx keeps the key unambiguous (ctx can always be split back
  // out), so two different (source, ctx) pairs can't collide; `-1` marks a null
  // ctx distinctly from an empty one.
  final key = '${ctx?.length ?? -1}:${ctx ?? ''}$source';
  final hit = _tokenCache[key];
  if (hit != null) return hit;
  final token = messageTokenForValue(TranslationText(source), ctx: ctx);
  if (_tokenCache.length >= _tokenCacheMax) _tokenCache.clear();
  _tokenCache[key] = token;
  return token;
}
