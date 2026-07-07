import 'dart:convert';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../contract/models/bundle.dart';
import '../delivery/bundle_store.dart';
import '../delivery/capture_reporter.dart';
import '../delivery/cdn_client.dart';
import '../delivery/default_store.dart';
import '../delivery/delivery_service.dart';
import 'controller.dart';
import 'extensions.dart';

/// Default delivery origin (overridable via [Easyi18nScope.baseUrl]).
const String kDefaultBaseUrl = 'https://api.easyi18n.com';

/// Wrap your app's `MaterialApp` with this to enable `context.tr(...)`. The only
/// required argument is [projectId]; everything else has a sensible default:
/// the production origin, the `production` channel, an `en` floor, and baked
/// assets at `assets/easyi18n/{locale}.json`.
///
/// On `initState` it builds the controller synchronously (so `context.tr`
/// resolves from the first frame) and kicks the offline-floor → persisted →
/// hot-update load. Hot-update is automatic: a manifest swap notifies the
/// controller, the [InheritedNotifier] rebuilds dependents, and `tr()` values
/// refresh in place — no dev code.
class Easyi18nScope extends StatefulWidget {
  const Easyi18nScope({
    super.key,
    required this.projectId,
    required this.child,
    this.baseUrl,
    this.channel = 'production',
    this.supportedLocales = const ['en'],
    this.bakedAssetPathBuilder,
    this.captureToken,
    this.captureInDebug = true,
    this.controller,
    this.httpClient,
    this.store,
  });

  final String projectId;
  final Widget child;
  final Uri? baseUrl;
  final String channel;

  /// Locale codes the project ships (the floor + the locales fetched at start).
  final List<String> supportedLocales;

  /// Asset path for a locale's baked floor bundle. Defaults to
  /// `assets/easyi18n/{locale}.json`; the dev lists that folder in their own
  /// `pubspec.yaml` assets.
  final String Function(String locale)? bakedAssetPathBuilder;

  /// A `capture`-scope dev token that turns on auto-capture: in debug builds,
  /// sources rendered raw (unknown to the project) are registered as draft keys.
  /// Read it from your dev environment (`--dart-define` / `.env`) — it must NOT
  /// ship in release. Null (the default) disables capture entirely.
  final String? captureToken;

  /// Master switch for auto-capture in debug builds (default on). The reporter
  /// is never built in release, nor without a [captureToken].
  final bool captureInDebug;

  /// Pre-built controller (tests / advanced wiring). When set, the network
  /// arguments are ignored.
  final Easyi18nController? controller;

  final http.Client? httpClient;
  final BundleStore? store;

  /// The nearest controller, or null if no scope is mounted yet. Registers the
  /// caller as a dependency of the hot-swap notifier.
  static Easyi18nController? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_Easyi18nInherited>()
      ?.notifier;

  @override
  State<Easyi18nScope> createState() => _Easyi18nScopeState();
}

class _Easyi18nScopeState extends State<Easyi18nScope> {
  late final Easyi18nController _controller;
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? _build();
    setAmbientController(_controller);
    if (_ownsController) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _controller.init());
    }
  }

  Easyi18nController _build() {
    final base = widget.baseUrl ?? Uri.parse(kDefaultBaseUrl);
    final client = widget.httpClient ?? http.Client();
    final storeFuture = widget.store != null
        ? Future<BundleStore>.value(widget.store!)
        : createBundleStore();
    final delivery = DeliveryService(
      client: CdnClient(client),
      store: LazyBundleStore(storeFuture),
      manifestUrl: buildManifestUrl(base, widget.projectId, widget.channel),
      channel: widget.channel,
    );
    final pathBuilder = widget.bakedAssetPathBuilder ??
        (String locale) => 'assets/easyi18n/$locale.json';
    final captureToken = widget.captureToken;
    final capture =
        widget.captureInDebug && kDebugMode && captureToken != null
            ? CaptureReporter(
                endpoint: buildCaptureUrl(base, widget.projectId),
                token: captureToken,
                client: client,
              )
            : null;
    return Easyi18nController(
      supportedLocales: widget.supportedLocales,
      delivery: delivery,
      capture: capture,
      bakedLoader: (locale) => _loadBakedAsset(pathBuilder(locale)),
    );
  }

  Future<Bundle?> _loadBakedAsset(String assetPath) async {
    try {
      final raw = await rootBundle.loadString(assetPath);
      return Bundle.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null; // no floor baked for this locale — fine.
    }
  }

  @override
  void dispose() {
    clearAmbientController(_controller);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _Easyi18nInherited(notifier: _controller, child: widget.child);
}

class _Easyi18nInherited extends InheritedNotifier<Easyi18nController> {
  const _Easyi18nInherited({
    required Easyi18nController super.notifier,
    required super.child,
  });
}
