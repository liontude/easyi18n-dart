import 'api_client.dart';
import 'config.dart';
import 'logger.dart';
import 'project_ref.dart';

/// Returns the opaque project id the `/v1/projects/{id}/...` routes need:
/// an [IdRef] directly, or ONE authenticated resolve of the `@handle/slug`
/// ref via `GET /v1/projects/resolve`. Called once per command invocation,
/// right after the client is built — everything downstream stays id-based.
Future<String> resolveProjectId(
  Easyi18nConfig config,
  TranslationsApiClient client, {
  CliLogger? logger,
}) async {
  switch (config.ref) {
    case IdRef(:final id):
      return id;
    case HandleRef(:final workspace, :final slug):
      final resolved = await client.resolveProjectRef(
        workspace: workspace,
        project: slug,
      );
      logger?.detail('Resolved @$workspace/$slug -> ${resolved.projectId}');
      return resolved.projectId;
  }
}
