// Picks the right BundleStore for the platform: a filesystem store on IO
// (desktop/mobile), an in-memory store on web. Conditional import keeps
// dart:io/path_provider out of the web build.
export 'default_store_stub.dart'
    if (dart.library.io) 'default_store_io.dart';
