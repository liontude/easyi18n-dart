# Changelog

## 0.2.0

- `easyi18n push` — statically extracts `tr()` source strings from your source
  tree (canonical `context.tr('…')` and the `'…'.tr()` sugar), diffs them
  against a committed `easyi18n.lock`, previews the credit cost, and registers +
  translates them via the backend. Flags: `--dry-run`, `--yes`, `--max-credits`,
  `--prune`, `--lang`, `--source-dir`.
- `easyi18n extract` — the same scan, offline and read-only: reports extractable
  strings, new/orphaned vs the lockfile, and dynamic (non-literal) calls.
  `--fail-on-orphans` for CI drift checks.

## 0.1.0

- Initial CLI (`easyi18n`) for Mode A (native `.arb`).
- `easyi18n init` writes an `easyi18n.yaml` config.
- `easyi18n pull` downloads translated files from the authenticated backend
  (`GET /v1/projects/{id}/translations`) and writes them to disk so you can run
  `flutter gen-l10n`. Supports `--version`, `--lang`, and `--dry-run`.
