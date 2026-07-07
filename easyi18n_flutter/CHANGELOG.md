# Changelog

## 0.1.0

- Initial runtime SDK: `Easyi18nScope` + `context.tr(source, args:)` /
  `'source'.tr()` source-as-key resolution.
- Offline floor from baked assets (`assets/easyi18n/{locale}.json`).
- Automatic hot-update from a delivery manifest (conditional `If-None-Match`,
  content-addressed immutable bundles, atomic swap with rebuild).
- Vendored, byte-parity contract (token + bundle hashing) gated by golden
  vectors and `tool/sync_contract.dart`.
