# easyi18n_cli

Command-line tool for [easyi18n](https://easyi18n.com). **Mode A (native
`.arb`)**. It pulls the translated localization files from your project's
published version and writes them to disk, so you keep using stock Flutter
localization (`flutter_localizations` + `gen-l10n` + `AppLocalizations`). No
runtime dependency, no hot-update. _"we're your TMS"_.

> For live hot-update (Mode B), use the [`easyi18n`](https://pub.dev/packages/easyi18n)
> runtime SDK instead. The two are independent; pick per project.

## Install

**Flutter project**: add as a dev dependency (it never ships in your app):

```yaml
dev_dependencies:
  easyi18n_cli: ^0.1.0
```

```sh
dart run easyi18n_cli:easyi18n pull
```

**Non-Flutter / CI**: activate globally:

```sh
dart pub global activate easyi18n_cli
easyi18n pull
```

## Usage

### 1. Configure

```sh
dart run easyi18n_cli:easyi18n init --project-id <your-project-id>
```

This writes `easyi18n.yaml`:

```yaml
projectId: proj_abc123
baseUrl: https://api.easyi18n.com   # override for the local emulator
format: arb                          # arb, json, nested_json, po, ...
output: lib/l10n                     # your l10n.yaml arb-dir
```

### 2. Authenticate

The CLI never stores a credential. Provide a project API key (`eik_…`) with
the **read** scope via the environment (or `--token`):

```sh
export EASYI18N_TOKEN=eik_xxxxxxxx
```

Create an API key in your project settings.

### 3. Pull

```sh
dart run easyi18n_cli:easyi18n pull
flutter gen-l10n
```

`pull` downloads every locale's file for the configured format and writes them
into `output/`, ready for `gen-l10n`. It records what it writes (in
`.easyi18n/state.json` — add `.easyi18n/` to your VCS ignore) and, on the next
full pull of the same format and output dir, removes files the server no
longer serves (e.g. a locale renamed to its canonical filename). A `--lang`
pull never removes anything; switching `format:` or `output:` never prunes
either — the stranded files of the old target are listed instead.

| Flag | Description |
|------|-------------|
| `--token` | Credential (overrides `EASYI18N_TOKEN`). |
| `--version` | Pull a specific published version (CalVer). Defaults to `latest`. |
| `--lang` | Pull only one locale (e.g. `--lang es`). |
| `--dry-run` | List the files that would be written without writing them. |
| `--config` | Path to the config file (default `easyi18n.yaml`). |

## Push your source strings

If your code calls `tr()` (via the [`easyi18n`](https://pub.dev/packages/easyi18n) runtime
SDK), the CLI can register and translate those strings for you. It statically
scans your source tree for `tr()` calls (both the canonical
`context.tr('Welcome {name}')` and the `'Welcome {name}'.tr()` sugar) and
sends the **raw source strings** to the backend, which tokenizes and translates
them.

```sh
export EASYI18N_TOKEN=eik_xxxxxxxx          # needs the translate scope
dart run easyi18n_cli:easyi18n push
```

`push` is interactive by default: it previews the cost before spending any
credits.

```
Scanned 42 file(s): 18 extractable tr() string(s).
3 new since last push:
  + "Welcome {name}"
  + "Save"
  + "Open"  (ctx: verb)
3 string(s) need translation · ~30 credit(s) (balance 1000).
Translate 3 string(s) for ~30 credit(s)? [y/N]
```

| Flag | Description |
|------|-------------|
| `--dry-run` | Estimate the cost only; register and translate nothing. |
| `--yes` / `-y` | Skip the confirmation prompt (for CI). |
| `--max-credits N` | Abort if the estimate exceeds `N` credits (a CI guard). |
| `--prune` | Drop orphaned strings from the lockfile (never deletes translations). |
| `--lang` | Restrict to these target languages (repeatable). |
| `--source-dir` | Directory to scan, relative to the config (default `lib`). |
| `--token` | Credential (overrides `EASYI18N_TOKEN`). |
| `--publish` | Wait for the fill to complete, then publish a new version (needs the `publish` scope). |
| `--approved-only` | With `--publish`: treat unapproved translations as missing. |

A `tr(variable)` or an interpolated `tr('Hi $name')` can't be read statically;
the CLI reports it so you know it relies on runtime auto-capture instead.

### `easyi18n.lock`

`push` records the strings it registered in `easyi18n.lock` (commit it). On the
next run, anything new is sent; strings that vanished from your code are
reported as **orphans** (their translations are kept; pass `--prune` to drop
them from the lockfile).

### `extract`: inspect without pushing

```sh
dart run easyi18n_cli:easyi18n extract
```

`extract` runs the same scan but stays **offline and read-only**: it prints what
would be registered, what's new, what's orphaned, and which calls are dynamic.
Use `--fail-on-orphans` as a CI drift check.

### `rollback`: undo a bad publish

```sh
dart run easyi18n_cli:easyi18n rollback            # restore the previous version
dart run easyi18n_cli:easyi18n rollback 2026.07.08.2
```

Restores a prior published version as a **new** version (history is never
rewritten) and points delivery at it. Needs the `publish` scope.

## Doctor: check the whole integration

```sh
dart run easyi18n_cli:easyi18n doctor
```

`doctor` is read-only and never spends credits. It checks:

- **Local wiring** — `easyi18n.yaml`, the `easyi18n` dependency, the
  `assets/easyi18n/` offline floor, `com.apple.security.network.client` in
  BOTH macOS `.entitlements` (without it, delivery fetches fail *silently* in
  the sandbox), and that `Easyi18nScope` is mounted.
- **ICU health** — lints every extracted `tr()` string (unbalanced braces,
  `plural`/`select` without `other`, …). A malformed ICU string renders raw
  to your users.
- **Delivery** — actively fetches the public manifest (the runtime swallows
  delivery errors by design, so doctor must not): reachable, CORS served for
  web, and then grades your `tr()` scan against the published bundles —
  **missing** (never pushed/published), **untranslated** per locale, and
  **unused** published keys.

Exit code 1 on blocking problems; warnings (e.g. strings pending a push)
don't block. Most local failures are fixed by re-running `easyi18n init`.

## CI

Pull translated files:

```sh
export EASYI18N_TOKEN=$EASYI18N_TOKEN   # CI secret
dart run easyi18n_cli:easyi18n pull
flutter gen-l10n
```

Or push on merge (register + translate, with a spend guard):

```sh
export EASYI18N_TOKEN=$EASYI18N_TOKEN   # needs the translate scope
dart run easyi18n_cli:easyi18n push --yes --max-credits 500
```
