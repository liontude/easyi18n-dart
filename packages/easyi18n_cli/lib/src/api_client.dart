import 'dart:convert';

import 'package:http/http.dart' as http;

import 'exceptions.dart';
import 'http_capped.dart';

/// The rendered files for one pull: a map of relative path (as the backend
/// namespaces it, e.g. `arb/app_en.arb`) to file content.
class PulledTranslations {
  PulledTranslations({
    required this.project,
    required this.version,
    required this.baseCode,
    required this.formats,
    required this.files,
  });

  final String project;
  final String version;
  final String baseCode;
  final List<String> formats;
  final Map<String, String> files;
}

/// One source unit pushed to the translate endpoint. The CLI sends raw source
/// strings; the backend tokenizes them (the CLI never computes tokens).
class TranslateUnit {
  TranslateUnit({
    required this.source,
    this.ctx,
    this.previousSource,
    this.previousCtx,
  });

  final String source;
  final String? ctx;

  /// For a detected copy-edit (rename): the previous source + ctx, so the
  /// backend carries the existing key over (cheap `outdated` cascade) instead
  /// of orphaning it and minting a fresh key. The CLI doesn't tokenize, so it
  /// sends the raw previous value and the backend computes the token.
  final String? previousSource;
  final String? previousCtx;

  Map<String, Object?> toJson() => {
    'source': source,
    if (ctx != null && ctx!.isNotEmpty) 'ctx': ctx,
    if (previousSource != null && previousSource!.isNotEmpty)
      'previousSource': previousSource,
    if (previousCtx != null && previousCtx!.isNotEmpty)
      'previousCtx': previousCtx,
  };
}

/// The per-unit view the translate endpoint echoes back.
class TranslateUnitResult {
  TranslateUnitResult({
    required this.outcome,
    this.key,
    this.pending = const [],
    this.translated = const [],
  });

  final String outcome; // created | matched | carriedOver
  final String? key;
  final List<String> pending;
  final List<String> translated;

  /// True when this push would (or did) queue at least one lang for fill.
  bool get needsTranslation => pending.isNotEmpty;
}

/// The result of one translate call (real or `dryRun`).
class TranslateResult {
  TranslateResult({
    required this.trackingToken,
    required this.estimatedCredits,
    required this.balance,
    required this.accepted,
    required this.wouldExceedKeyCap,
    required this.units,
  });

  /// The job id for a real push (null on a dry run or a no-op accept).
  final String? trackingToken;
  final int estimatedCredits;
  final int balance;

  /// Whether the balance covers the estimate (always true for an accepted real
  /// push; reported explicitly by a dry run).
  final bool accepted;

  /// Dry-run only: whether the push would be rejected because it exceeds the
  /// project's plan key cap (the real push enforces this with a 402). Lets the
  /// preview warn before an affordable-looking estimate that would still fail.
  final bool wouldExceedKeyCap;
  final List<TranslateUnitResult> units;

  int get unitsNeedingTranslation =>
      units.where((u) => u.needsTranslation).length;
}

/// The result of a publish or rollback (`201 {versionId, keyCount}`).
class PublishOutcome {
  PublishOutcome({
    required this.versionId,
    required this.keyCount,
    this.restoredFrom,
    this.icuRejected = const [],
  });

  final String versionId;
  final int keyCount;

  /// Rollback only: the version id whose snapshot was restored.
  final String? restoredFrom;

  /// `key [lang]: problem` per target cell the backend's ICU gate refused to
  /// bake (it fell back to the incomplete mode instead). Surfaced so a CI log
  /// names the offending cells.
  final List<String> icuRejected;
}

/// The slice of `GET /v1/projects/{id}/meta` that `status` needs.
class ProjectMeta {
  ProjectMeta({required this.currentVersionId, required this.baseCode});

  final String currentVersionId;
  final String baseCode;
}

/// The opaque ids a `workspace` + `project` handle ref resolves to, via
/// `GET /v1/projects/resolve`.
class ResolvedProjectRef {
  ResolvedProjectRef({required this.projectId, required this.workspaceId});

  final String projectId;
  final String workspaceId;
}

/// Thin client over the authenticated public read endpoint
/// `GET /v1/projects/{id}/translations`, which renders files per format/locale
/// from the project's currently published version.
class TranslationsApiClient {
  TranslationsApiClient({
    required this.baseUrl,
    required this.token,
    http.Client? httpClient,
  }) : _client = httpClient ?? http.Client();

  final String baseUrl;
  final String token;
  final http.Client _client;

  /// Fetches the rendered files for [projectId] in [format]. [version] defaults
  /// to the published `latest`; [lang] optionally narrows to one locale.
  Future<PulledTranslations> fetchTranslations({
    required String projectId,
    required String format,
    String? version,
    String? lang,
  }) async {
    final uri = Uri.parse('$baseUrl/v1/projects/$projectId/translations')
        .replace(
          queryParameters: {
            'format': format,
            if (version != null && version.isNotEmpty) 'version': version,
            if (lang != null && lang.isNotEmpty) 'lang': lang,
          },
        );

    final http.Response response;
    try {
      response = await _sendCapped(
        http.Request('GET', uri)
          ..headers.addAll({
            'authorization': 'Bearer $token',
            'accept': 'application/json',
          }),
      );
    } on http.ClientException catch (e) {
      throw CliException('Could not reach $baseUrl: ${e.message}');
    }

    if (response.statusCode != 200) {
      throw CliException(_describeError(response));
    }

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } on FormatException {
      throw CliException('Unexpected response from $baseUrl (not JSON).');
    }

    final files =
        (body['files'] as Map?)?.map(
          (key, value) => MapEntry(key as String, value as String),
        ) ??
        const {};

    return PulledTranslations(
      project: body['project'] as String? ?? projectId,
      version: body['version'] as String? ?? '',
      baseCode: body['baseCode'] as String? ?? '',
      formats: (body['formats'] as List?)?.cast<String>() ?? const [],
      files: files,
    );
  }

  /// `GET /v1/projects/{id}/meta` - the project's currently published version
  /// (what `easyi18n status` compares the local state against).
  Future<ProjectMeta> fetchMeta({required String projectId}) async {
    final uri = Uri.parse('$baseUrl/v1/projects/$projectId/meta');
    final http.Response response;
    try {
      response = await _sendCapped(
        http.Request('GET', uri)
          ..headers.addAll({
            'authorization': 'Bearer $token',
            'accept': 'application/json',
          }),
      );
    } on http.ClientException catch (e) {
      throw CliException('Could not reach $baseUrl: ${e.message}');
    }
    if (response.statusCode != 200) {
      throw CliException(_describeError(response, action: 'Status'));
    }
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } on FormatException {
      throw CliException('Unexpected response from $baseUrl (not JSON).');
    }
    return ProjectMeta(
      currentVersionId: body['currentVersionId'] as String? ?? '',
      baseCode: body['baseCode'] as String? ?? '',
    );
  }

  /// `GET /v1/projects/resolve?workspace=&project=` - maps the config's
  /// `@handle/slug` ref to the opaque ids the id-bound write routes need. Any
  /// valid key for the project is accepted (resolve underlies read, translate
  /// and publish alike); a key bound to another project 401s, which surfaces
  /// config<->key drift early.
  Future<ResolvedProjectRef> resolveProjectRef({
    required String workspace,
    required String project,
  }) async {
    final uri = Uri.parse(
      '$baseUrl/v1/projects/resolve',
    ).replace(queryParameters: {'workspace': workspace, 'project': project});
    final http.Response response;
    try {
      response = await _sendCapped(
        http.Request('GET', uri)
          ..headers.addAll({
            'authorization': 'Bearer $token',
            'accept': 'application/json',
          }),
      );
    } on http.ClientException catch (e) {
      throw CliException('Could not reach $baseUrl: ${e.message}');
    }
    if (response.statusCode != 200) {
      throw CliException(_describeError(response, action: 'Resolve'));
    }
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } on FormatException {
      throw CliException('Unexpected response from $baseUrl (not JSON).');
    }
    final projectId = body['projectId'] as String? ?? '';
    if (projectId.isEmpty) {
      throw CliException('Unexpected response from $baseUrl (no projectId).');
    }
    return ResolvedProjectRef(
      projectId: projectId,
      workspaceId: body['workspaceId'] as String? ?? '',
    );
  }

  /// `POST /v1/projects/{id}/translate` - register source units and (unless
  /// [dryRun]) trigger their translation. [dryRun] runs an estimate-only pass:
  /// no key is written, no job enqueued, nothing charged. [langs] optionally
  /// narrows to a subset of the project's target languages.
  Future<TranslateResult> translate({
    required String projectId,
    required List<TranslateUnit> units,
    List<String>? langs,
    bool dryRun = false,
  }) async {
    final uri = Uri.parse(
      '$baseUrl/v1/projects/$projectId/translate',
    ).replace(queryParameters: {if (dryRun) 'dryRun': 'true'});

    final http.Response response;
    try {
      response = await _sendCapped(
        http.Request('POST', uri)
          ..headers.addAll({
            'authorization': 'Bearer $token',
            'content-type': 'application/json',
          })
          ..body = jsonEncode({
            'units': [for (final u in units) u.toJson()],
            if (langs != null && langs.isNotEmpty) 'langs': langs,
          }),
      );
    } on http.ClientException catch (e) {
      throw CliException('Could not reach $baseUrl: ${e.message}');
    }

    if (response.statusCode != 200) {
      throw CliException(_describeError(response, action: 'Push'));
    }

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } on FormatException {
      throw CliException('Unexpected response from $baseUrl (not JSON).');
    }

    return TranslateResult(
      trackingToken: body['trackingToken'] as String?,
      estimatedCredits: (body['estimatedCredits'] as num?)?.toInt() ?? 0,
      balance: (body['balance'] as num?)?.toInt() ?? 0,
      // A real push that returns 200 was accepted; a dry run says so explicitly.
      accepted: body['accepted'] as bool? ?? true,
      wouldExceedKeyCap: body['wouldExceedKeyCap'] as bool? ?? false,
      units: [
        for (final raw in (body['units'] as List? ?? const []))
          if (raw is Map<String, dynamic>)
            TranslateUnitResult(
              outcome: raw['outcome'] as String? ?? 'matched',
              key: raw['key'] as String?,
              pending: (raw['pending'] as List?)?.cast<String>() ?? const [],
              translated:
                  (raw['translated'] as List?)?.cast<String>() ?? const [],
            ),
      ],
    );
  }

  /// `POST /v1/projects/{id}/publish` - freeze the live state into a new
  /// immutable version (needs the `publish` scope).
  Future<PublishOutcome> publish({
    required String projectId,
    String? label,
    bool approvedOnly = false,
  }) => _post(
    'projects/$projectId/publish',
    action: 'Publish',
    body: {
      if (label != null && label.isNotEmpty) 'label': label,
      if (approvedOnly) 'approvedOnly': true,
    },
  );

  /// `POST /v1/projects/{id}/versions/{vid}/restore` - roll back by restoring
  /// [versionId] (or the literal `previous`) as a new version.
  Future<PublishOutcome> restoreVersion({
    required String projectId,
    required String versionId,
  }) => _post(
    'projects/$projectId/versions/$versionId/restore',
    action: 'Rollback',
  );

  Future<PublishOutcome> _post(
    String path, {
    required String action,
    Map<String, Object?>? body,
  }) async {
    final http.Response response;
    try {
      response = await _sendCapped(
        http.Request('POST', Uri.parse('$baseUrl/v1/$path'))
          ..headers.addAll({
            'authorization': 'Bearer $token',
            'content-type': 'application/json',
          })
          ..body = jsonEncode(body ?? const {}),
      );
    } on http.ClientException catch (e) {
      throw CliException('Could not reach $baseUrl: ${e.message}');
    }
    if (response.statusCode != 201) {
      throw CliException(_describeError(response, action: action));
    }
    final Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(response.body) as Map<String, dynamic>;
    } on FormatException {
      throw CliException('Unexpected response from $baseUrl (not JSON).');
    }
    return PublishOutcome(
      versionId: decoded['versionId'] as String? ?? '',
      keyCount: (decoded['keyCount'] as num?)?.toInt() ?? 0,
      restoredFrom: decoded['restoredFrom'] as String?,
      icuRejected: [
        for (final e in decoded['icuRejected'] as List? ?? const [])
          if (e is String) e,
      ],
    );
  }

  void close() => _client.close();

  Future<http.Response> _sendCapped(http.BaseRequest request) =>
      sendCapped(_client, request);

  String _describeError(http.Response response, {String action = 'Pull'}) {
    String? message;
    String? code;
    try {
      final body = jsonDecode(response.body);
      if (body is Map) {
        if (body['message'] is String) message = body['message'] as String;
        if (body['error'] is String) code = body['error'] as String;
      }
    } on FormatException {
      // Non-JSON error body; fall back to the status line.
    }

    final hint = switch (response.statusCode) {
      401 => '\nCheck your token (EASYI18N_TOKEN) - it needs the right scope.',
      // 402 covers both out-of-credits and plan caps (e.g. the free-tier key
      // limit). Only the credits case warrants the top-up hint; for a plan
      // limit the server message already says what to do.
      402 when code != 'plan_limit' =>
        '\nNot enough credits to translate. Top up, or narrow the push '
            '(--max-credits / fewer langs).',
      403 =>
        '\nThe token is valid but lacks the required scope for this '
            'project.',
      404 when action == 'Resolve' =>
        '\nCheck the workspace/project in easyi18n.yaml - is the handle '
            'claimed and the slug correct?',
      // The version_not_found message already says exactly what's missing
      // (e.g. rollback with nothing older) - don't muddy it.
      404 when code != 'version_not_found' =>
        '\nThe project may not exist or have no published version yet.',
      409 when code == 'export_collision' =>
        '\nTwo keys collapse to the same name in a lossy format. Rename one '
            'and re-publish, or pull a path-preserving format (e.g. json).',
      _ => '',
    };
    final detail = message ?? 'HTTP ${response.statusCode}';
    return '$action failed: $detail$hint';
  }
}
