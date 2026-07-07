import 'package:intl/message_format.dart';

import '../contract/i18n/text_hash.dart';
import '../contract/models/translation_value.dart';
import 'bundle_stack.dart';

/// Resolves `tr(source, {args})` against a [BundleStack].
///
/// **Token parity (load-bearing):** the source is hashed as **opaque text** —
/// `messageTokenForValue(TranslationText(source), ctx:)` — NEVER parsed as ICU.
/// The backend tokenizes the same way (`message_tokens.dart`), so the bytes
/// match. Parsing an inline-ICU plural source here would canonicalize it to
/// `{count, plural, …}` and produce a DIFFERENT token, so every lookup would
/// miss. The plural still renders because the localized ICU lives in the
/// bundle message (`messages[slug]`) and [MessageFormat] resolves it; the raw
/// source is both the token preimage and the offline fallback.
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
    final token = messageTokenForValue(TranslationText(source), ctx: ctx);
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
