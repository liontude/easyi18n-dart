import 'bundle_store.dart';

/// Platforms without a filesystem (web): no cross-launch persistence — the baked
/// asset floor covers cold starts and hot-update repopulates in-session.
Future<BundleStore> createBundleStore() async => InMemoryBundleStore();
