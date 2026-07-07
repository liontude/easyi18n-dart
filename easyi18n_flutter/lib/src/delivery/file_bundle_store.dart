import 'dart:convert';
import 'dart:io';

import '../contract/models/bundle.dart';
import 'bundle_store.dart';

/// Filesystem-backed [BundleStore] for IO platforms (desktop/mobile). Layout
/// under [dir]:
///
/// ```
/// {dir}/state-{channel}.json            ← delivery state (etag + hash pointer)
/// {dir}/bundles/{locale}/{hash}.json    ← immutable, content-addressed
/// ```
///
/// Writes are atomic (write a temp sibling, then `rename`) so a crash mid-write
/// never leaves a torn file the next launch would read as a valid bundle. The
/// [dir] is injected (e.g. from `path_provider`) which keeps this testable with
/// a plain temp directory — no platform-channel mock needed.
class FileBundleStore implements BundleStore {
  FileBundleStore(this.dir);
  final Directory dir;

  File _stateFile(String channel) => File('${dir.path}/state-$channel.json');
  File _bundleFile(String locale, String hash) =>
      File('${dir.path}/bundles/$locale/$hash.json');

  Future<void> _atomicWrite(File file, String contents) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(contents, flush: true);
    await tmp.rename(file.path);
  }

  @override
  Future<DeliveryState> loadState(String channel) async {
    final file = _stateFile(channel);
    if (!await file.exists()) return const DeliveryState();
    try {
      return DeliveryState.fromJson(
          jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return const DeliveryState();
    }
  }

  @override
  Future<void> saveState(String channel, DeliveryState state) =>
      _atomicWrite(_stateFile(channel), jsonEncode(state.toJson()));

  @override
  Future<Bundle?> loadBundle(String locale, String bundleHash) async {
    final file = _bundleFile(locale, bundleHash);
    if (!await file.exists()) return null;
    try {
      return Bundle.fromJson(
          jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveBundle(Bundle bundle) => _atomicWrite(
        _bundleFile(bundle.locale, bundle.bundleHash),
        jsonEncode(bundle.toJson()),
      );
}
