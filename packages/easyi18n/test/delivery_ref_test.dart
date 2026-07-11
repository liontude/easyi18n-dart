import 'package:easyi18n/easyi18n.dart';
import 'package:easyi18n/src/delivery/delivery_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final base = Uri.parse('https://api.easyi18n.com');

  group('manifest URL builders (F1)', () {
    test('by opaque id', () {
      expect(
        buildManifestUrl(base, 'N7Nayd', 'production').toString(),
        'https://api.easyi18n.com/v1/projects/N7Nayd/manifest?channel=production',
      );
    });

    test('by @handle/slug', () {
      expect(
        buildManifestUrlByHandle(base, 'acme', 'dogfood', 'production')
            .toString(),
        'https://api.easyi18n.com/v1/@acme/dogfood/manifest?channel=production',
      );
    });

    test('a trailing slash on the base is trimmed', () {
      expect(
        buildManifestUrlByHandle(
                Uri.parse('https://x/'), 'acme', 'dogfood', 'production')
            .toString(),
        'https://x/v1/@acme/dogfood/manifest?channel=production',
      );
    });
  });

  group('Easyi18nScope ref validation (F1)', () {
    const child = SizedBox();

    test('accepts a projectId ref', () {
      expect(() => Easyi18nScope(projectId: 'p', child: child), returnsNormally);
    });

    test('accepts a workspace + slug ref', () {
      expect(() => Easyi18nScope(workspace: 'acme', slug: 'dogfood', child: child),
          returnsNormally);
    });

    test('rejects both refs at once', () {
      expect(
        () => Easyi18nScope(
            projectId: 'p', workspace: 'acme', slug: 'dogfood', child: child),
        throwsA(isA<AssertionError>()),
      );
    });

    test('rejects a half-specified handle ref (slug missing)', () {
      expect(
        () => Easyi18nScope(workspace: 'acme', child: child),
        throwsA(isA<AssertionError>()),
      );
    });

    test('rejects no ref at all', () {
      expect(() => Easyi18nScope(child: child), throwsA(isA<AssertionError>()));
    });
  });
}
