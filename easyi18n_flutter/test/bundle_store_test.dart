import 'dart:io';

import 'package:easyi18n/src/contract/models/bundle.dart';
import 'package:easyi18n/src/delivery/bundle_store.dart';
import 'package:easyi18n/src/delivery/file_bundle_store.dart';
import 'package:flutter_test/flutter_test.dart';

Bundle sample(String locale) => Bundle.compute(
      locale: locale,
      messages: {'k': 'v-$locale'},
      tokenIndex: {'tok': 'k'},
    );

void main() {
  group('FileBundleStore', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('easyi18n_store_test');
    });
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('round-trips a content-addressed bundle', () async {
      final store = FileBundleStore(dir);
      final bundle = sample('es');
      await store.saveBundle(bundle);

      final loaded = await store.loadBundle('es', bundle.bundleHash);
      expect(loaded, isNotNull);
      expect(loaded!.messages['k'], 'v-es');
      expect(loaded.bundleHash, bundle.bundleHash);
    });

    test('missing bundle → null', () async {
      final store = FileBundleStore(dir);
      expect(await store.loadBundle('es', 'nope'), isNull);
    });

    test('round-trips delivery state per channel', () async {
      final store = FileBundleStore(dir);
      const state = DeliveryState(
        manifestEtag: '"v3"',
        hashByLocale: {'es': 'h-es', 'en': 'h-en'},
      );
      await store.saveState('production', state);

      final loaded = await store.loadState('production');
      expect(loaded.manifestEtag, '"v3"');
      expect(loaded.hashByLocale, {'es': 'h-es', 'en': 'h-en'});
      // A different channel is independent.
      expect((await store.loadState('staging')).manifestEtag, isNull);
    });

    test('survives a fresh store instance over the same dir (persistence)',
        () async {
      final bundle = sample('fr');
      await FileBundleStore(dir).saveBundle(bundle);
      final reopened = await FileBundleStore(dir).loadBundle('fr', bundle.bundleHash);
      expect(reopened!.messages['k'], 'v-fr');
    });
  });

  group('InMemoryBundleStore', () {
    test('round-trips bundle + state in memory', () async {
      final store = InMemoryBundleStore();
      final bundle = sample('de');
      await store.saveBundle(bundle);
      await store.saveState(
          'production', const DeliveryState(hashByLocale: {'de': 'x'}));

      expect((await store.loadBundle('de', bundle.bundleHash))!.messages['k'],
          'v-de');
      expect((await store.loadState('production')).hashByLocale, {'de': 'x'});
    });
  });
}
