# Changelog

## 0.5.0

- `easyi18n pull` now records what it writes (`.easyi18n/state.json`) and, on
  the next full pull of the same format and output dir, removes recorded files
  the server no longer serves — e.g. a locale renamed to its platform-canonical
  filename (`app_zh-hant.arb` → `app_zh_Hant.arb`), sweeping stranded `.tmp`
  files and emptied dirs along. A `--lang` pull never prunes; a `format:` or
  `output:` switch lists the old target's stranded files instead of deleting
  across targets; `--dry-run` previews removals. The first pull that records
  its list warns about files it cannot attribute instead of deleting them.

## 0.4.0

- `easyi18n push --publish`: after the push, waits for the AI fill to
  complete (polling the dry-run estimate) and publishes a new version via
  the public publish endpoint — no dashboard needed. `--approved-only`
  treats unapproved translations as missing when publishing. Needs an API
  key with the `publish` scope.
- New `easyi18n rollback [version]`: restores a prior published version as
  a NEW version (history is never rewritten). With no argument it restores
  the version just before the current one.

- New `easyi18n doctor`: read-only health check of the whole integration.
  Verifies the local wiring (config, `easyi18n` dependency, `assets/easyi18n/`
  floor, `com.apple.security.network.client` in both macOS entitlements,
  `Easyi18nScope` mounted), lints your `tr()` source strings as ICU (malformed
  ICU renders raw to users), and **actively probes delivery** — manifest
  reachable, CORS served, then your tr() scan graded against the published
  bundles: missing (never pushed/published), untranslated per locale, and
  unused keys. Bundles are integrity-checked against their content address
  (a stale CDN object fails doctor the same way the runtime rejects it), a
  200 that isn't a manifest is a failure (SPA catch-all / captive portal),
  and a CORS header locked to one origin is surfaced instead of passing as
  "present". Exit 1 on blocking problems; warnings don't block.
- `push` / `extract`: a `tr()` call whose `ctx:` is not a string literal is
  now reported as dynamic instead of being registered as the (wrong) no-ctx
  unit.

## 0.3.0

- `easyi18n init` is now one-command project setup: besides `easyi18n.yaml`
  it adds the `easyi18n:` dependency and the `assets/easyi18n/` offline floor
  to `pubspec.yaml` (creating the dir), ignores the derived `.easyi18n/` state
  in `.gitignore`, grants `com.apple.security.network.client` in BOTH macOS
  `.entitlements` (delivery fetches fail silently in the sandbox without it),
  and wires `Easyi18nScope` around a trivial `runApp(...)` (printed as a
  snippet when `main.dart` is not trivially patchable). Idempotent; new
  `--dry-run` flag reports without writing. An existing `easyi18n.yaml` is now
  kept (re-run friendly) instead of an error — `--force` still rewrites it.

## 0.2.0

- `easyi18n push`: statically extracts `tr()` source strings from your source
  tree (canonical `context.tr('…')` and the `'…'.tr()` sugar), diffs them
  against a committed `easyi18n.lock`, previews the credit cost, and registers +
  translates them via the backend. Flags: `--dry-run`, `--yes`, `--max-credits`,
  `--prune`, `--lang`, `--source-dir`.
- `easyi18n extract`: the same scan, offline and read-only: reports extractable
  strings, new/orphaned vs the lockfile, and dynamic (non-literal) calls.
  `--fail-on-orphans` for CI drift checks.

## 0.1.0

- Initial CLI (`easyi18n`) for Mode A (native `.arb`).
- `easyi18n init` writes an `easyi18n.yaml` config.
- `easyi18n pull` downloads translated files from the authenticated backend
  (`GET /v1/projects/{id}/translations`) and writes them to disk so you can run
  `flutter gen-l10n`. Supports `--version`, `--lang`, and `--dry-run`.
