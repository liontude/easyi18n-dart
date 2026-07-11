import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Reports the `tr()` sources the runtime had to render raw (unknown to the
/// project) to the backend capture endpoint, so they show up as draft keys -
/// the "install → tr() → run → it appears" loop, with no CLI.
///
/// Debug-only by construction (the [Easyi18nScope] only builds one in debug,
/// and only when a capture [token] is provided - that token is a `capture`-scope
/// dev credential that must NEVER ship in a release build). Cheap on the hot
/// path: each unique `(source, ctx)` is recorded once per session and flushed in
/// a debounced batch. Best-effort - a failed POST is swallowed.
class CaptureReporter {
  CaptureReporter({
    Uri? endpoint,
    required this.token,
    required http.Client client,
    this.flushInterval = const Duration(seconds: 3),
    this.maxBatch = 200,
  })  : _client = client,
        _endpoint = endpoint;

  /// `…/v1/projects/{id}/capture`. Deferred (null) when the scope was addressed
  /// by `@handle/slug`: capture is id-only, and the id isn't known until the
  /// first manifest — [setEndpoint] fills it in then. Misses recorded before it
  /// resolves stay buffered in [_pending] (never dropped).
  Uri? _endpoint;

  /// Provide the capture endpoint once the project id is known (from the first
  /// manifest). First call wins; drains anything buffered meanwhile.
  void setEndpoint(Uri endpoint) {
    if (_disposed || _endpoint != null) return;
    _endpoint = endpoint;
    if (_pending.isNotEmpty) unawaited(flush());
  }

  /// A `capture`-scope dev token (`Authorization: Bearer …`). Debug-only.
  final String token;
  final http.Client _client;
  final Duration flushInterval;
  final int maxBatch;

  final Set<String> _seen = {};
  final List<({String source, String? ctx})> _pending = [];
  Timer? _timer;
  bool _disposed = false;

  /// Record a missed source. Deduped per session; schedules a debounced flush.
  void record(String source, String? ctx) {
    if (_disposed) return;
    final key = '$source${ctx ?? ''}';
    if (!_seen.add(key)) return;
    _pending.add((source: source, ctx: ctx));
    if (_pending.length >= maxBatch) {
      unawaited(flush());
    } else {
      _timer ??= Timer(flushInterval, () => unawaited(flush()));
    }
  }

  /// Send the pending batch now (best-effort).
  Future<void> flush() async {
    if (_pending.isEmpty) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    final endpoint = _endpoint;
    if (endpoint == null) {
      // Endpoint not known yet (deferred until the first manifest). Keep the
      // buffer and re-arm so a later tick — or setEndpoint — drains it.
      if (!_disposed) _timer ??= Timer(flushInterval, () => unawaited(flush()));
      return;
    }
    _timer?.cancel();
    _timer = null;
    final batch = List.of(_pending);
    _pending.clear();
    try {
      await _client.post(
        endpoint,
        headers: {
          'content-type': 'application/json',
          'authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'units': [
            for (final u in batch)
              {'source': u.source, if (u.ctx != null) 'ctx': u.ctx},
          ],
        }),
      );
    } catch (_) {
      // Best-effort, but don't lose the batch on a transient failure: re-queue
      // it and re-arm the timer so the next tick retries (the sources stay in
      // `_seen`, so the backend - which dedups anyway - never sees duplicates).
      if (!_disposed) {
        _pending.addAll(batch);
        _timer ??= Timer(flushInterval, () => unawaited(flush()));
      }
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
