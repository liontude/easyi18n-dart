import 'dart:convert';

import 'package:http/http.dart' as http;

import '../contract/i18n/text_hash.dart' show kMessageTokenAlgoVersion;
import '../contract/models/bundle.dart';
import '../contract/models/manifest.dart';

/// Raised when a delivery fetch fails in a way the caller should treat as "no
/// update available" (network error, bad status, or a content-integrity
/// violation). Hot-update is best-effort: the offline floor still serves.
class DeliveryException implements Exception {
  DeliveryException(this.message);
  final String message;
  @override
  String toString() => 'DeliveryException: $message';
}

/// Result of a conditional manifest fetch.
sealed class ManifestFetch {
  const ManifestFetch();
}

/// The manifest is unchanged since [etag] (HTTP 304).
class ManifestNotModified extends ManifestFetch {
  const ManifestNotModified();
}

/// The manifest changed; [manifest] is the new pointer, [etag] its validator.
class ManifestUpdated extends ManifestFetch {
  const ManifestUpdated(this.manifest, this.etag);
  final Manifest manifest;
  final String? etag;
}

/// Thin HTTP client for the delivery origin (CDN or backend-origin — the SDK is
/// agnostic, it only follows the URLs the manifest hands it). Injectable
/// [http.Client] so tests run against a `MockClient`.
class CdnClient {
  CdnClient(this._client);
  final http.Client _client;

  /// Conditional GET of the manifest. Sends `If-None-Match: <etag>` when known
  /// so an unchanged manifest costs a cheap 304.
  Future<ManifestFetch> fetchManifest(Uri url, {String? etag}) async {
    final http.Response res;
    try {
      res = await _client.get(url, headers: {
        'if-none-match': ?etag,
      });
    } catch (e) {
      throw DeliveryException('manifest fetch failed: $e');
    }
    if (res.statusCode == 304) return const ManifestNotModified();
    if (res.statusCode != 200) {
      throw DeliveryException('manifest status ${res.statusCode}');
    }
    final Manifest manifest;
    try {
      manifest = Manifest.fromJson(
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
    } catch (e) {
      throw DeliveryException('manifest parse failed: $e');
    }
    // The SDK can only resolve source-as-key if the served tokenIndex uses an
    // algorithm version it understands.
    if (!manifest.tokenAlgoVersions.contains(kMessageTokenAlgoVersion)) {
      throw DeliveryException(
          'manifest tokenAlgoVersions ${manifest.tokenAlgoVersions} '
          'lacks $kMessageTokenAlgoVersion');
    }
    return ManifestUpdated(manifest, res.headers['etag'] ?? etag);
  }

  /// GET + verify one immutable bundle. Rejects an unknown future schema and a
  /// content address that does not match [expectedHash] (tamper / wrong object).
  Future<Bundle> fetchBundle(
    Uri url, {
    required String locale,
    required String expectedHash,
  }) async {
    final http.Response res;
    try {
      res = await _client.get(url);
    } catch (e) {
      throw DeliveryException('bundle fetch failed: $e');
    }
    if (res.statusCode != 200) {
      throw DeliveryException('bundle status ${res.statusCode}');
    }
    final Bundle bundle;
    try {
      bundle = Bundle.fromJson(
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
    } catch (e) {
      throw DeliveryException('bundle parse failed: $e');
    }
    if (bundle.schemaVersion > kBundleSchemaVersion) {
      throw DeliveryException(
          'bundle schemaVersion ${bundle.schemaVersion} > $kBundleSchemaVersion');
    }
    final computed = computeBundleHash(
      schemaVersion: bundle.schemaVersion,
      locale: bundle.locale,
      messages: bundle.messages,
      tokenIndex: bundle.tokenIndex,
    );
    if (computed != expectedHash || bundle.bundleHash != expectedHash) {
      throw DeliveryException('bundle hash mismatch for $locale');
    }
    return bundle;
  }
}
