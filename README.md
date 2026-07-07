# easyi18n — Dart & Flutter SDKs

Official client SDKs for [easyi18n](https://easyi18n.com), the i18n management
platform. This repository holds the open-source packages you install in your
app or CI; the easyi18n platform itself is a separate hosted service.

## Packages

| Package | pub.dev | What it does |
| --- | --- | --- |
| [`easyi18n`](packages/easyi18n) | `easyi18n` | Runtime Flutter SDK — source-as-key `tr()`, an offline floor from baked assets, and live hot-updates from the delivery manifest/CDN. No codegen, no rebuild to change a value. |
| [`easyi18n_cli`](packages/easyi18n_cli) | `easyi18n_cli` | Command-line tool — **Mode A (native `.arb`)**. Pull translated files into your project and push your `tr()` source strings for translation. No runtime dependency. |

> Pick the flow that fits: the **runtime SDK** (`easyi18n`) for hot-updating
> strings, or the **CLI** (`easyi18n_cli`) to stay on stock
> `flutter_localizations` + `gen-l10n`.

## Install

```sh
# Runtime Flutter SDK
flutter pub add easyi18n

# CLI (global dev/CI tool)
dart pub global activate easyi18n_cli
```

## License

MIT — see [LICENSE](LICENSE). Each package also ships its own copy.
