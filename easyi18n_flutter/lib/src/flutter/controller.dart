import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../contract/models/bundle.dart';
import '../delivery/bundle_store.dart';
import '../delivery/capture_reporter.dart';
import '../delivery/cdn_client.dart';
import '../delivery/default_store.dart';
import '../delivery/delivery_service.dart';
import '../resolver/bundle_stack.dart';
import '../resolver/message_resolver.dart';

/// Loads the offline-floor bundle for a locale (e.g. a shipped asset). Returns
/// null when none is baked for that locale.
typedef BakedLoader = Future<Bundle?> Function(String locale);

/// The runtime brain: owns the per-locale [BundleStack]s and resolves `tr()`.
/// It is a [ChangeNotifier] so the Flutter layer rebuilds on a hot-swap.
///
/// Never does async work in a synchronous resolve: a locale that isn't loaded
/// yet resolves against the raw source (base language) and schedules a load that
/// notifies when ready. Load order per locale: baked floor → persisted last-good
/// → network hot-update; each phase that changes anything notifies.
class Easyi18nController extends ChangeNotifier {
  Easyi18nController({
    required this.supportedLocales,
    required DeliveryService delivery,
    BakedLoader? bakedLoader,
    CaptureReporter? capture,
    MessageResolver resolver = const MessageResolver(),
  })  : _delivery = delivery,
        _bakedLoader = bakedLoader,
        _capture = capture,
        _resolver = resolver;

  /// Wire a production controller against a delivery origin (CDN or backend).
  /// [baseUrl] is the API origin; the manifest is fetched from
  /// `…/v1/projects/{projectId}/manifest?channel=…` and bundle URLs come from
  /// the manifest itself.
  static Future<Easyi18nController> create({
    required String projectId,
    required Uri baseUrl,
    required List<String> supportedLocales,
    String channel = 'production',
    BakedLoader? bakedLoader,
    http.Client? httpClient,
    BundleStore? store,
  }) async {
    final resolvedStore = store ?? await createBundleStore();
    final delivery = DeliveryService(
      client: CdnClient(httpClient ?? http.Client()),
      store: resolvedStore,
      manifestUrl: buildManifestUrl(baseUrl, projectId, channel),
      channel: channel,
    );
    return Easyi18nController(
      supportedLocales: supportedLocales,
      delivery: delivery,
      bakedLoader: bakedLoader,
    );
  }

  final List<String> supportedLocales;
  final DeliveryService _delivery;
  final BakedLoader? _bakedLoader;
  final CaptureReporter? _capture;
  final MessageResolver _resolver;

  final Map<String, BundleStack> _stacks = {};
  final Set<String> _loading = {};
  bool _disposed = false;

  /// Resolve `tr(source)` for [locale]. Pure + synchronous; schedules a load if
  /// the locale's bundles aren't in memory yet (raw source serves meanwhile).
  String resolve({
    required String source,
    String? ctx,
    Map<String, Object> args = const {},
    required String locale,
  }) {
    final code = matchLocale(locale);
    final capture = _capture;
    final onMiss =
        capture == null ? null : () => capture.record(source, ctx);
    final stack = _stacks[code];
    if (stack == null) {
      _ensureLocale(code);
      return _resolver.resolve(
          source: source, ctx: ctx, args: args, locale: code,
          stack: const BundleStack(), onMiss: onMiss);
    }
    return _resolver.resolve(
        source: source, ctx: ctx, args: args, locale: code, stack: stack,
        onMiss: onMiss);
  }

  /// Best supported bundle code for a requested locale tag: exact match, else a
  /// language-only match, else the base (first) supported locale.
  String matchLocale(String requested) {
    if (supportedLocales.contains(requested)) return requested;
    final lang = _lang(requested);
    for (final l in supportedLocales) {
      if (_lang(l) == lang) return l;
    }
    return supportedLocales.isNotEmpty ? supportedLocales.first : requested;
  }

  String _lang(String code) => code.split(RegExp('[-_]')).first.toLowerCase();

  /// Full startup: baked floor → persisted → network, for all supported
  /// locales. Safe to await; each phase notifies as bundles land.
  Future<void> init() async {
    await _loadBaked(supportedLocales);
    await _loadPersisted(supportedLocales);
    await refresh();
  }

  /// Re-check the manifest and hot-swap any changed bundles.
  Future<void> refresh() async {
    try {
      final changed = await _delivery.refresh(supportedLocales);
      if (changed.isNotEmpty) _applyHot(changed);
    } on DeliveryException {
      // Best-effort: the floor still serves.
    }
  }

  Future<void> _loadBaked(Iterable<String> locales) async {
    final loader = _bakedLoader;
    if (loader == null) return;
    var any = false;
    for (final locale in locales) {
      final baked = await loader(locale);
      if (baked == null) continue;
      _stacks[locale] = (_stacks[locale] ?? const BundleStack())
          .copyWith(baked: baked);
      any = true;
    }
    if (any) _notify();
  }

  Future<void> _loadPersisted(Iterable<String> locales) async {
    final persisted = await _delivery.loadPersisted(locales);
    if (persisted.isEmpty) return;
    for (final e in persisted.entries) {
      _stacks[e.key] =
          (_stacks[e.key] ?? const BundleStack()).copyWith(persisted: e.value);
    }
    _notify();
  }

  void _applyHot(Map<String, Bundle> changed) {
    for (final e in changed.entries) {
      _stacks[e.key] =
          (_stacks[e.key] ?? const BundleStack()).copyWith(hot: e.value);
    }
    _notify();
  }

  /// Load a single locale requested at runtime that wasn't pre-loaded.
  Future<void> _ensureLocale(String code) async {
    if (_loading.contains(code) || _stacks.containsKey(code)) return;
    _loading.add(code);
    try {
      await _loadBaked([code]);
      await _loadPersisted([code]);
      try {
        final changed = await _delivery.refresh([code]);
        if (changed.isNotEmpty) _applyHot(changed);
      } on DeliveryException {
        // floor serves
      }
      // Mark as attempted even if empty, so we don't reschedule every frame.
      _stacks[code] ??= const BundleStack();
    } finally {
      _loading.remove(code);
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _capture?.dispose();
    super.dispose();
  }
}
