import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../config.dart';
import '../contract.dart';
import '../delivery.dart';
import '../extract/extraction_report.dart' show ellipsize;
import '../extract/source_unit.dart';
import '../extract/tr_extractor.dart';
import '../icu_lint.dart';
import '../logger.dart';
import '../project_ref.dart';
import '../scaffold.dart';

/// Builds the delivery client `doctor` probes with. Injected so tests can
/// swap in a `MockClient`-backed instance.
typedef DeliveryClientFactory =
    DeliveryClient Function({required String baseUrl});

/// Cap on itemized findings printed per check, so a large drift doesn't
/// scroll the summary away.
const int _maxListed = 10;

/// `easyi18n doctor` — read-only health check of the whole integration
/// (flutter-integration §4): local wiring (config, pubspec, assets floor,
/// macOS entitlements, `Easyi18nScope`), source quality (ICU lint of extracted
/// `tr()` strings), and delivery (manifest reachable + CORS, then the tr()
/// scan graded against the published bundles: missing / untranslated /
/// unused).
///
/// Delivery is probed **actively** because the runtime swallows fetch errors
/// by design (friction F3): an app with a broken delivery path renders its
/// baked floor and nobody notices. Everything here is read-only and
/// unauthenticated — the delivery origin is public — so doctor never mutates
/// the project or spends credits.
class DoctorCommand extends Command<int> {
  DoctorCommand({
    required CliLogger logger,
    DeliveryClientFactory? deliveryFactory,
    TrExtractor? extractor,
    Map<String, String>? environment,
  }) : _logger = logger,
       _deliveryFactory = deliveryFactory ?? _defaultFactory,
       _extractor = extractor ?? TrExtractor(),
       _environment = environment ?? Platform.environment {
    argParser
      ..addOption(
        'token',
        help:
            'API key (eik_). Only checked for presence - doctor itself '
            'never sends it. Defaults to \$EASYI18N_TOKEN.',
      )
      ..addOption(
        'source-dir',
        help: 'Directory to scan for tr() calls, relative to the config file.',
        defaultsTo: 'lib',
      );
  }

  final CliLogger _logger;
  final DeliveryClientFactory _deliveryFactory;
  final TrExtractor _extractor;
  final Map<String, String> _environment;

  @override
  String get name => 'doctor';

  @override
  String get description =>
      'Check the easyi18n integration: config, platform wiring, ICU health '
      'and the published translations vs your tr() calls.';

  int _failures = 0;
  int _warnings = 0;

  @override
  Future<int> run() async {
    _failures = 0;
    _warnings = 0;
    final results = argResults!;
    final configPath =
        globalResults?['config'] as String? ?? Easyi18nConfig.fileName;
    // Same root idiom as push/extract, so every command scans the same tree.
    final root = p.dirname(configPath);

    // ---- local wiring -------------------------------------------------------
    final config = Easyi18nConfig.load(File(configPath));
    _ok(configPath, 'project ${config.describeRef}');

    _checkCredential(results['token'] as String?);
    _checkPubspec(File(p.join(root, 'pubspec.yaml')));
    _checkFloorDir(Directory(p.join(root, 'assets', 'easyi18n')));
    _checkEntitlements(Directory(p.join(root, 'macos')));

    // ---- source scan (tr() + scope) + ICU lint -------------------------------
    final sourceDir = Directory(p.join(root, results['source-dir'] as String));
    final extraction = _extractor.extractFromDirectory(
      sourceDir,
      relativeTo: root,
    );
    _checkScope(extraction, root, sourceDir);
    _reportScan(extraction);
    _lintSources(extraction);

    // ---- delivery probe + published-vs-code grading -------------------------
    final client = _deliveryFactory(baseUrl: config.baseUrl);
    try {
      final probe = await _probeDelivery(client, config);
      if (probe != null && extraction.units.isNotEmpty) {
        await _gradeAgainstBundles(client, probe, extraction.units);
      }
    } finally {
      client.close();
    }

    // ---- verdict -------------------------------------------------------------
    if (_failures > 0) {
      _logger.info(
        '$_failures problem(s), $_warnings warning(s). '
        "Most local issues are fixed by 'easyi18n init'.",
      );
      return 1;
    }
    _logger.info(
      _warnings > 0
          ? 'No blocking problems, $_warnings warning(s).'
          : 'All checks passed.',
    );
    return 0;
  }

  // ----- local checks --------------------------------------------------------

  void _checkCredential(String? flagToken) {
    final token = flagToken?.trim() ?? _environment['EASYI18N_TOKEN']?.trim();
    if (token != null && token.isNotEmpty) {
      _ok('credential', 'EASYI18N_TOKEN set');
    } else {
      _warn(
        'credential',
        "EASYI18N_TOKEN not set - 'easyi18n push/pull' will need it",
      );
    }
  }

  void _checkPubspec(File pubspec) {
    if (!pubspec.existsSync()) {
      _fail(pubspec.path, 'not found - not a package root?');
      return;
    }
    final content = pubspec.readAsStringSync();
    // addRuntimeDependency returns null exactly when the dependency already
    // exists (any form), which makes it a free read-only check.
    if (addRuntimeDependency(content) == null) {
      _ok(pubspec.path, 'easyi18n is a dependency');
    } else {
      _fail(pubspec.path, "missing the 'easyi18n' dependency");
    }
    if (_floorRegistered(content)) {
      _ok(pubspec.path, '$kAssetsFloorDir assets registered');
    } else {
      _fail(pubspec.path, '$kAssetsFloorDir not under flutter: assets:');
    }
  }

  /// Whether the offline floor is bundled: the exact dir entry `init` writes,
  /// or any itemized entry under it (Flutter accepts both).
  static bool _floorRegistered(String pubspec) {
    final dynamic doc;
    try {
      doc = loadYaml(pubspec);
    } on YamlException {
      return false;
    }
    if (doc is! Map) return false;
    final flutter = doc['flutter'];
    final assets = flutter is Map ? flutter['assets'] : null;
    if (assets is! List) return false;
    return assets.any(
      (e) =>
          e is String &&
          (e == kAssetsFloorDir || e.startsWith(kAssetsFloorDir)),
    );
  }

  void _checkFloorDir(Directory dir) {
    if (dir.existsSync()) {
      _ok('${dir.path}/', 'offline floor dir present');
    } else {
      _fail('${dir.path}/', 'offline floor dir missing');
    }
  }

  void _checkEntitlements(Directory macosDir) {
    if (!macosDir.existsSync()) {
      _skip('macos/', 'no macOS target');
      return;
    }
    for (final name in const [
      'DebugProfile.entitlements',
      'Release.entitlements',
    ]) {
      final file = File(p.join(macosDir.path, 'Runner', name));
      if (!file.existsSync()) {
        _fail(file.path, 'not found - macOS target without entitlements?');
        continue;
      }
      switch (_entitlementState(file.readAsStringSync())) {
        case _Entitlement.granted:
          _ok(file.path, '$kNetworkClientKey granted');
        case _Entitlement.denied:
          _fail(
            file.path,
            '$kNetworkClientKey is explicitly <false/> - delivery fetches '
            'fail SILENTLY in the macOS sandbox',
          );
        case _Entitlement.missing:
          _fail(
            file.path,
            '$kNetworkClientKey missing - delivery fetches fail SILENTLY in '
            'the macOS sandbox',
          );
        case _Entitlement.unverifiable:
          _warn(
            file.path,
            'could not verify $kNetworkClientKey (unrecognized plist shape)',
          );
      }
    }
  }

  /// Structural read of the entitlement pair. Checked directly (not via the
  /// init patcher, whose null conflates "already true" with "malformed").
  static _Entitlement _entitlementState(String rawPlist) {
    // A commented-out pair must not count as granted.
    final plist = rawPlist.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
    final pair = RegExp(
      '<key>${RegExp.escape(kNetworkClientKey)}</key>'
      r'\s*<(true|false)\s*/>',
    ).firstMatch(plist);
    if (pair != null) {
      return pair.group(1) == 'true'
          ? _Entitlement.granted
          : _Entitlement.denied;
    }
    if (plist.contains(kNetworkClientKey)) return _Entitlement.unverifiable;
    if (!plist.contains('</dict>')) return _Entitlement.unverifiable;
    return _Entitlement.missing;
  }

  void _checkScope(
    ExtractionResult extraction,
    String root,
    Directory sourceDir,
  ) {
    var scopeFile = extraction.scopeFile;
    // A narrowed --source-dir must not false-FAIL a scope mounted elsewhere
    // under lib/ (the wiring usually lives in main.dart / a bootstrap file).
    final lib = Directory(p.join(root, 'lib'));
    if (scopeFile == null &&
        lib.existsSync() &&
        !p.equals(sourceDir.path, lib.path)) {
      scopeFile = _extractor
          .extractFromDirectory(lib, relativeTo: root)
          .scopeFile;
    }
    if (scopeFile != null) {
      _ok(p.join(root, scopeFile), 'Easyi18nScope mounted');
    } else {
      _fail(
        p.join(root, 'lib', 'main.dart'),
        'Easyi18nScope not mounted - tr() will never resolve; run '
        "'easyi18n init'",
      );
    }
  }

  // ----- source checks -------------------------------------------------------

  void _reportScan(ExtractionResult extraction) {
    _ok(
      'scan',
      '${extraction.filesScanned} file(s), ${extraction.units.length} '
          'extractable tr() string(s)',
    );
    if (extraction.dynamics.isNotEmpty) {
      _warn(
        'scan',
        '${extraction.dynamics.length} tr() call(s) with a non-literal '
            'source rely on runtime auto-capture',
      );
      for (final d in extraction.dynamics.take(_maxListed)) {
        _logger.detail('${d.file}:${d.line}  ${d.snippet}');
      }
      _elided(extraction.dynamics.length);
    }
  }

  void _lintSources(ExtractionResult extraction) {
    var problems = 0;
    for (final unit in extraction.units) {
      final found = lintIcuMessage(unit.source);
      try {
        canonicalizeCtx(unit.ctx);
      } on ArgumentError {
        found.add('ctx contains control characters');
      }
      for (final problem in found) {
        problems++;
        if (problems <= _maxListed) {
          _logger.detail(
            '${unit.file}:${unit.line}  "${ellipsize(unit.source)}"'
            ' - $problem',
          );
        }
      }
    }
    if (problems == 0) {
      _ok('icu', '${extraction.units.length} source string(s) lint clean');
    } else {
      _elided(problems);
      _fail(
        'icu',
        '$problems ICU problem(s) - a malformed string renders RAW to users',
      );
    }
  }

  // ----- delivery checks -----------------------------------------------------

  /// Probes the manifest. Returns it when the scan can proceed, null when
  /// delivery is absent/broken (already reported).
  Future<ManifestProbe?> _probeDelivery(
    DeliveryClient client,
    Easyi18nConfig config,
  ) async {
    final ManifestProbe probe;
    try {
      probe = switch (config.ref) {
        IdRef(:final id) => await client.fetchManifest(id),
        HandleRef(:final workspace, :final slug) =>
          await client.fetchManifestByRef(workspace, slug),
      };
    } on Exception catch (e) {
      _fail('delivery', '$e');
      return null;
    }

    if (probe.statusCode == 404 && probe.errorCode == 'not_published') {
      _warn(
        'delivery',
        "nothing published yet - run 'easyi18n push', then publish",
      );
      return null;
    }
    if (probe.statusCode != 200) {
      _fail(
        'delivery',
        'GET ${probe.uri} -> HTTP ${probe.statusCode}'
            '${probe.errorMessage == null ? '' : ' (${probe.errorMessage})'}',
      );
      return null;
    }
    // A 200 that isn't a manifest (SPA catch-all, captive portal, WAF page)
    // is a broken delivery path, not a version-skew warning.
    if (probe.revision == null) {
      _fail(
        'delivery',
        'GET ${probe.uri} returned 200 but not a delivery manifest - '
            'check baseUrl',
      );
      return null;
    }

    _ok(
      'delivery',
      'manifest reachable - revision ${probe.revision}, '
          '${probe.locales.length} locale(s)',
    );

    // The Flutter WEB build can only fetch this cross-origin with CORS; a
    // missing header is invisible on macOS and fatal in every browser. A
    // locked-down value is graded, not just presence: only `*` provably
    // admits the customer's own app origin.
    final cors = probe.headers['access-control-allow-origin'];
    if (cors == '*') {
      _ok('delivery', 'CORS allows browser fetches');
    } else if (cors != null) {
      _warn(
        'delivery',
        'CORS is locked to $cors - your web app must be served from that '
            'origin or browser fetches will be blocked',
      );
    } else {
      _fail(
        'delivery',
        'no access-control-allow-origin header - the web app cannot fetch '
            'translations',
      );
    }

    if (!probe.tokenAlgoVersions.contains(kMessageTokenAlgoVersion)) {
      _warn(
        'delivery',
        'manifest serves token algo ${probe.tokenAlgoVersions} but this CLI '
            'speaks $kMessageTokenAlgoVersion - scan skipped, update the CLI',
      );
      return null;
    }
    return probe;
  }

  /// Grades the extracted tr() units against the published bundles:
  /// missing (not resolvable at all), untranslated (resolvable but absent in
  /// a target locale), unused (published but never called).
  Future<void> _gradeAgainstBundles(
    DeliveryClient client,
    ManifestProbe probe,
    List<ExtractedUnit> units,
  ) async {
    // Fetched concurrently (they're independent), integrity-checked against
    // their content address like the runtime SDK does.
    final bundles = <String, DeliveryBundle>{};
    final entries = probe.locales.entries.toList();
    final fetched = await Future.wait([
      for (final entry in entries)
        client
            .fetchBundle(entry.value.url, expectedHash: entry.value.bundleHash)
            .then<Object>((b) => b, onError: (Object e) => e),
    ]);
    for (var i = 0; i < entries.length; i++) {
      final result = fetched[i];
      if (result is DeliveryBundle) {
        bundles[entries[i].key] = result;
      } else {
        _warn('delivery', 'bundle ${entries[i].key}: $result - locale skipped');
      }
    }
    if (bundles.isEmpty) {
      _fail('delivery', 'no bundle could be fetched');
      return;
    }
    // The tokenIndex is locale-independent (identity, not translation) - any
    // one bundle carries the full map.
    final tokenIndex = bundles.values.first.tokenIndex;

    final tokenByUnit = <ExtractedUnit, String>{
      for (final u in units)
        if (_tokenOrNull(u) case final String token) u: token,
    };

    // missing: the runtime would fall back to the source string forever.
    final missing = [
      for (final e in tokenByUnit.entries)
        if (!tokenIndex.containsKey(e.value)) e.key,
    ];
    if (missing.isEmpty) {
      _ok('scan', 'every tr() string is published');
    } else {
      _warn(
        'scan',
        '${missing.length} tr() string(s) not in the published version - '
            "run 'easyi18n push', then publish",
      );
      for (final u in missing.take(_maxListed)) {
        _logger.detail('${u.file}:${u.line}  "${ellipsize(u.source)}"');
      }
      _elided(missing.length);
    }

    // untranslated: resolvable, but a locale still falls back to the source.
    final usedSlugs = {
      for (final token in tokenByUnit.values)
        if (tokenIndex[token] case final String slug) slug,
    };
    for (final bundle in bundles.values) {
      final absent = usedSlugs.difference(bundle.messages.keys.toSet());
      // The base locale always carries every live key, so it reports zero;
      // only genuine target-locale gaps surface here.
      if (absent.isNotEmpty) {
        _warn(
          'scan',
          '${absent.length} of your tr() string(s) untranslated in '
              '${bundle.locale}',
        );
      }
    }

    // unused: published + managed, but no tr() call references it. Only
    // informational - it may be live on another platform or a dynamic call.
    final extractedTokens = tokenByUnit.values.toSet();
    final unused = [
      for (final e in tokenIndex.entries)
        if (!extractedTokens.contains(e.key)) e.value,
    ];
    if (unused.isNotEmpty) {
      _skip(
        'scan',
        '${unused.length} published key(s) not referenced by any extracted '
            'tr() call (dynamic calls / other platforms?)',
      );
    }
  }

  String? _tokenOrNull(ExtractedUnit unit) {
    try {
      return messageTokenForText(unit.source, ctx: unit.ctx);
    } on ArgumentError {
      return null; // already reported by the ICU/ctx lint
    }
  }

  // ----- plumbing ------------------------------------------------------------

  void _ok(String target, String detail) =>
      _logger.info('ok    $target - $detail');

  void _skip(String target, String detail) =>
      _logger.info('info  $target - $detail');

  void _warn(String target, String detail) {
    _warnings++;
    _logger.info('warn  $target - $detail');
  }

  void _fail(String target, String detail) {
    _failures++;
    _logger.info('FAIL  $target - $detail');
  }

  void _elided(int total) {
    if (total > _maxListed) {
      _logger.detail('... and ${total - _maxListed} more');
    }
  }

  static DeliveryClient _defaultFactory({required String baseUrl}) =>
      DeliveryClient(baseUrl: baseUrl);
}

/// Verdict of the structural entitlement read.
enum _Entitlement { granted, denied, missing, unverifiable }
