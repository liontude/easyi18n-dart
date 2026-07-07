import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'bundle_store.dart';
import 'file_bundle_store.dart';

/// IO platforms: persist under an `easyi18n/` subfolder of the app's support
/// directory so hot-updated bundles survive restarts (offline-first cold start).
Future<BundleStore> createBundleStore() async {
  final base = await getApplicationSupportDirectory();
  final dir = Directory('${base.path}/easyi18n');
  await dir.create(recursive: true);
  return FileBundleStore(dir);
}
