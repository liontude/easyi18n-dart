import '../contract/models/bundle.dart';

/// Ordered, immutable resolution layers for ONE locale, newest first:
///
/// 1. **hot** - the live bundle from the latest manifest swap (in memory).
/// 2. **persisted** - the last good bundle loaded from disk at startup.
/// 3. **baked** - the offline floor shipped as an asset in the app binary.
///
/// Each layer is a self-contained `{tokenIndex, messages}`. A token resolves
/// against the first layer that BOTH indexes it and has a message for the slug,
/// so a newer layer that knows the token but lacks this locale's translation
/// falls through to an older layer - and ultimately to the raw source (see
/// [MessageResolver]). Layers are only ever set, never cleared.
class BundleStack {
  const BundleStack({this.hot, this.persisted, this.baked});

  final Bundle? hot;
  final Bundle? persisted;
  final Bundle? baked;

  /// Resolution order, skipping absent layers.
  Iterable<Bundle> get layers => [hot, persisted, baked].whereType<Bundle>();

  BundleStack copyWith({Bundle? hot, Bundle? persisted, Bundle? baked}) =>
      BundleStack(
        hot: hot ?? this.hot,
        persisted: persisted ?? this.persisted,
        baked: baked ?? this.baked,
      );
}
