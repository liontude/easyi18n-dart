import 'exceptions.dart';

/// The project a CLI invocation addresses: exactly one of an opaque [IdRef]
/// (legacy `projectId`) or a [HandleRef] (`@handle/slug` pair).
///
/// The sealed hierarchy makes the exactly-one rule irrepresentable to
/// violate: [parse] is the single validator, and consumers `switch`
/// exhaustively instead of null-checking. It mirrors — but deliberately does
/// NOT share — the runtime SDK's `Easyi18nScope` assert: that one is laxer on
/// purpose (widget ergonomics tolerate a dangling `workspace` next to a
/// `projectId`), so don't unify them.
sealed class ProjectRef {
  const ProjectRef();

  /// The single ref validator: strips a leading `@` from [workspace], treats
  /// empty strings as absent, then enforces the strict XOR. [source] labels
  /// the error (the config file path, or `'flags'` from `init`).
  static ProjectRef parse({
    String? projectId,
    String? workspace,
    String? project,
    required String source,
  }) {
    final id = _emptyToNull(projectId);
    // Accept a pasted `@handle` (the dashboard URL form / prompt hint) but
    // store the bare handle: the server matches it without `@` and an
    // unquoted `@` is an invalid-YAML indicator in the written config.
    final handle = _emptyToNull(_stripLeadingAt(workspace));
    final slug = _emptyToNull(project);

    if (id != null && (handle != null || slug != null)) {
      throw CliException(
        "$source sets both 'projectId' and 'workspace'/'project'. "
        'Provide either projectId, or workspace + project (not both).',
      );
    }
    if (id == null && (handle != null) != (slug != null)) {
      throw CliException(
        "$source sets '${handle != null ? 'workspace' : 'project'}' without "
        "'${handle != null ? 'project' : 'workspace'}' — the @handle/slug ref "
        'needs both.',
      );
    }
    if (id != null) return IdRef(id);
    if (handle != null) return HandleRef(handle, slug!);
    throw CliException(
      "$source is missing the project ref: set 'workspace' + 'project' "
      "(the @handle/slug pair from your dashboard URL), or a 'projectId'.",
    );
  }

  /// A human-readable label for diagnostics/logs.
  String get describe;

  /// The `project` seed for `Lockfile.loadOrEmpty`: the id when known, ''
  /// for a handle ref. Deliberately inert — the diff ignores it and the
  /// lockfile writer stamps the resolved id — so a handle ref never forces
  /// a resolve on offline paths.
  String get lockSeed;

  static String? _emptyToNull(String? value) =>
      (value == null || value.isEmpty) ? null : value;

  static String? _stripLeadingAt(String? value) =>
      value != null && value.startsWith('@') ? value.substring(1) : value;
}

/// The opaque project doc-id (legacy ref form), used directly by the
/// `/v1/projects/{id}/...` routes.
final class IdRef extends ProjectRef {
  const IdRef(this.id);

  final String id;

  @override
  String get describe => id;

  @override
  String get lockSeed => id;

  @override
  bool operator ==(Object other) => other is IdRef && other.id == id;

  @override
  int get hashCode => Object.hash(IdRef, id);
}

/// The legible `@handle/slug` ref, resolved to an id once per invocation.
final class HandleRef extends ProjectRef {
  const HandleRef(this.workspace, this.slug);

  /// The bare workspace handle (no leading `@`).
  final String workspace;

  /// The project slug, unique within [workspace]. This is the `project` key
  /// in `easyi18n.yaml` and the `slug` param of the SDK's `Easyi18nScope`.
  final String slug;

  @override
  String get describe => '@$workspace/$slug';

  @override
  String get lockSeed => '';

  @override
  bool operator ==(Object other) =>
      other is HandleRef && other.workspace == workspace && other.slug == slug;

  @override
  int get hashCode => Object.hash(HandleRef, workspace, slug);
}
