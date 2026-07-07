import '../contract/models/bundle.dart';
import 'bundle_store.dart';
import 'cdn_client.dart';

/// The manifest endpoint for a project on a delivery origin:
/// `{baseUrl}/v1/projects/{projectId}/manifest?channel={channel}`. Bundle URLs
/// are then read from the manifest itself, so they can point at the CDN or the
/// backend origin transparently.
Uri buildManifestUrl(Uri baseUrl, String projectId, String channel) {
  final base = baseUrl.toString().replaceFirst(RegExp(r'/+$'), '');
  return Uri.parse('$base/v1/projects/$projectId/manifest?channel=$channel');
}

/// The auto-capture endpoint for a project:
/// `{baseUrl}/v1/projects/{projectId}/capture`.
Uri buildCaptureUrl(Uri baseUrl, String projectId) {
  final base = baseUrl.toString().replaceFirst(RegExp(r'/+$'), '');
  return Uri.parse('$base/v1/projects/$projectId/capture');
}

/// Orchestrates offline-first delivery: load the last-good persisted bundles at
/// startup, then conditionally refresh against the manifest and download only
/// the bundles whose content address changed. Throws nothing on a network/parse
/// failure during [refresh] except a [DeliveryException] the caller swallows —
/// hot-update is best-effort, the floor always serves.
class DeliveryService {
  DeliveryService({
    required this.client,
    required this.store,
    required this.manifestUrl,
    this.channel = 'production',
  });

  final CdnClient client;
  final BundleStore store;
  final Uri manifestUrl;
  final String channel;

  /// Last-good bundles for [locales] from the previous session's saved pointer.
  Future<Map<String, Bundle>> loadPersisted(Iterable<String> locales) async {
    final state = await store.loadState(channel);
    final out = <String, Bundle>{};
    for (final locale in locales) {
      final hash = state.hashByLocale[locale];
      if (hash == null) continue;
      final bundle = await store.loadBundle(locale, hash);
      if (bundle != null) out[locale] = bundle;
    }
    return out;
  }

  /// Serializes all delivery mutations: each [refresh] runs after the previous
  /// one completes, so a startup refresh and an ad-hoc per-locale fetch can't
  /// read-modify-write the persisted state concurrently and drop a locale's
  /// hash pointer (which would force a redundant refetch next cold start).
  Future<void> _refreshLock = Future<void>.value();

  /// Conditional manifest check → download the changed bundles for [locales],
  /// persist them + the new state, and return ONLY the bundles that changed
  /// (the caller swaps those into the hot layer). Empty map = nothing to do.
  Future<Map<String, Bundle>> refresh(Iterable<String> locales) {
    final list = locales.toList(growable: false);
    final result = _refreshLock.then((_) => _refresh(list));
    // Chain the lock so the next refresh waits for this one; swallow errors so
    // a failed refresh doesn't wedge the chain.
    _refreshLock = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Map<String, Bundle>> _refresh(List<String> locales) async {
    final state = await store.loadState(channel);
    // Conditional fetch (cheap 304 when unchanged). If the manifest is
    // unchanged but a requested locale still has no persisted bundle (e.g. a
    // prior bundle fetch failed), we have no URL for it — fall back to one
    // unconditional fetch to recover, instead of forcing a full body on every
    // startup just because a locale is missing.
    var fetch = await client.fetchManifest(
      manifestUrl,
      etag: state.manifestEtag,
    );
    if (fetch is ManifestNotModified) {
      final missing = locales.any((l) => !state.hashByLocale.containsKey(l));
      if (!missing) return const {};
      fetch = await client.fetchManifest(manifestUrl, etag: null);
    }
    if (fetch is! ManifestUpdated) return const {};
    final manifest = fetch.manifest;

    final changed = <String, Bundle>{};
    final hashes = Map<String, String>.from(state.hashByLocale);
    for (final locale in locales) {
      final entry = manifest.locales[locale];
      if (entry == null) continue;
      if (state.hashByLocale[locale] == entry.bundleHash &&
          await store.loadBundle(locale, entry.bundleHash) != null) {
        continue; // already have this exact bundle persisted.
      }
      // Resolve the (root-relative) bundle URL against the manifest URL we
      // actually fetched, so the bundle is pulled from the same host/CDN as the
      // manifest. Absolute URLs (legacy manifests) resolve to themselves.
      final bundle = await client.fetchBundle(
        manifestUrl.resolveUri(Uri.parse(entry.url)),
        locale: locale,
        expectedHash: entry.bundleHash,
      );
      await store.saveBundle(bundle);
      changed[locale] = bundle;
      hashes[locale] = entry.bundleHash;
    }

    await store.saveState(
      channel,
      state.copyWith(manifestEtag: fetch.etag, hashByLocale: hashes),
    );
    return changed;
  }
}
