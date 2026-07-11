import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../config.dart';
import '../exceptions.dart';
import '../logger.dart';
import '../project_ref.dart';
import '../scaffold.dart';

/// Asks the user for one value, returning null when there's no way to ask
/// (e.g. non-interactive). Injectable so tests never touch the real terminal.
typedef Prompt = String? Function(String label);

/// `easyi18n init` — one-command project setup (flutter-integration §4).
///
/// Owns every integration step a Flutter app needs before the first `push`:
/// `easyi18n.yaml` · the `easyi18n:` pubspec dependency · the
/// `assets/easyi18n/` offline floor (dir + pubspec entry) · `.gitignore` for
/// the derived `.easyi18n/` state · `network.client` in BOTH macOS
/// `.entitlements` (friction F3 — the sandbox failure is silent) · the
/// `Easyi18nScope` wiring in `main.dart` (patched only for the trivial
/// `runApp(<expr>)` shape, printed otherwise).
///
/// Idempotent: every step reports `ok` on a re-run instead of stacking edits.
/// `--dry-run` reports what would change without touching the tree.
class InitCommand extends Command<int> {
  InitCommand({required CliLogger logger, Prompt? prompt})
    : _logger = logger,
      _prompt = prompt ?? _terminalPrompt {
    argParser
      ..addOption(
        'workspace',
        help:
            'The workspace handle (the @handle segment of your project '
            'URL). Use with --project.',
      )
      ..addOption(
        'project',
        help:
            'The project slug (unique within the workspace). Use with '
            '--workspace.',
      )
      ..addOption(
        'project-id',
        help:
            'The opaque easyi18n project id (legacy; prefer '
            '--workspace/--project).',
      )
      ..addOption(
        'base-url',
        help: 'Backend origin.',
        defaultsTo: Easyi18nConfig.defaultBaseUrl,
      )
      ..addOption(
        'format',
        help: 'Output format (arb, json, po, ...).',
        defaultsTo: Easyi18nConfig.defaultFormat,
      )
      ..addOption(
        'output',
        help: 'Directory to write files into.',
        defaultsTo: Easyi18nConfig.defaultOutput,
      )
      ..addFlag(
        'force',
        abbr: 'f',
        negatable: false,
        help: 'Rewrite an existing easyi18n.yaml from the flags.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Report what would change without writing anything.',
      );
  }

  final CliLogger _logger;
  final Prompt _prompt;

  @override
  String get name => 'init';

  @override
  String get description =>
      'Set up this Flutter project for easyi18n (config, pubspec, assets '
      'floor, macOS entitlements, scope wiring).';

  late bool _dryRun;

  @override
  Future<int> run() async {
    final results = argResults!;
    _dryRun = results['dry-run'] as bool;
    final configPath =
        globalResults?['config'] as String? ?? Easyi18nConfig.fileName;
    final configFile = File(configPath);
    // Every scaffold target is resolved against the config file's directory —
    // the app root by convention (tests point --config at a fixture dir).
    final root = configFile.parent.path;

    final config = _ensureConfig(configFile, results);
    _patchPubspec(File(p.join(root, 'pubspec.yaml')));
    _ensureFloorDir(Directory(p.join(root, 'assets', 'easyi18n')));
    _patchGitignore(File(p.join(root, '.gitignore')));
    for (final name in const [
      'DebugProfile.entitlements',
      'Release.entitlements',
    ]) {
      _patchEntitlements(File(p.join(root, 'macos', 'Runner', name)));
    }
    _wireScope(File(p.join(root, 'lib', 'main.dart')), config);

    _logger.info(
      _dryRun
          ? 'Dry run - nothing written.'
          : "Done. Set EASYI18N_TOKEN, then run 'easyi18n push'.",
    );
    return 0;
  }

  // ----- steps ------------------------------------------------------------

  /// Writes (or keeps) `easyi18n.yaml` and returns the effective config.
  Easyi18nConfig _ensureConfig(File file, ArgResults results) {
    final flagId = (results['project-id'] as String?)?.trim();
    final flagWorkspace = (results['workspace'] as String?)?.trim();
    final flagProject = (results['project'] as String?)?.trim();
    final force = results['force'] as bool;

    final hasId = flagId != null && flagId.isNotEmpty;
    final hasWorkspace = flagWorkspace != null && flagWorkspace.isNotEmpty;
    final hasProject = flagProject != null && flagProject.isNotEmpty;
    if (hasId && (hasWorkspace || hasProject)) {
      throw CliException(
        'Pass either --project-id, or --workspace + --project (not both).',
      );
    }
    if (hasWorkspace != hasProject) {
      throw CliException(
        '--workspace and --project must be used together (the @handle/slug '
        'pair needs both).',
      );
    }

    if (file.existsSync() && !force) {
      final config = Easyi18nConfig.load(file);
      ProjectRef? flagRef;
      if (hasId || hasWorkspace) {
        try {
          flagRef = ProjectRef.parse(
            projectId: flagId,
            workspace: flagWorkspace,
            project: flagProject,
            source: 'flags',
          );
        } on CliException catch (e) {
          // A degenerate flag ref (e.g. a lone '@' handle). The config on
          // disk wins on this path anyway, so warn-and-keep instead of
          // failing the otherwise idempotent re-run.
          _logger.warn('Ignoring the ref flags: ${e.message}');
        }
      }
      if (flagRef != null && flagRef != config.ref) {
        _logger.warn(
          '${file.path} already points at ${config.describeRef}; ignoring '
          '${flagRef.describe} (use --force to rewrite).',
        );
      }
      _report('ok', file.path, 'kept existing config');
      return config;
    }

    final config = _buildConfig(
      results,
      flagId: flagId,
      flagWorkspace: flagWorkspace,
      flagProject: flagProject,
    );
    final existed = file.existsSync();
    _write(file, config.toYaml());
    _report(
      existed ? 'rewrote' : 'created',
      file.path,
      'project ${config.describeRef}',
    );
    return config;
  }

  /// Builds the config from the flags, prompting on a terminal when no ref
  /// flag is set (handle pair first, falling back to a legacy project id).
  Easyi18nConfig _buildConfig(
    ArgResults results, {
    required String? flagId,
    required String? flagWorkspace,
    required String? flagProject,
  }) {
    String? workspace = flagWorkspace;
    String? project = flagProject;
    String? projectId = flagId;

    final prompted =
        (workspace == null || workspace.isEmpty) &&
        (projectId == null || projectId.isEmpty);
    if (prompted) {
      workspace = _prompt('Workspace handle (@handle)')?.trim();
      if (workspace != null && workspace.isNotEmpty) {
        project = _prompt('Project slug')?.trim();
        if (project == null || project.isEmpty) {
          throw CliException('A workspace handle needs a project slug.');
        }
      } else {
        // No handle given — fall back to the legacy opaque id.
        workspace = null;
        projectId = _prompt('Project id')?.trim();
      }
    }

    final hasId = projectId != null && projectId.isNotEmpty;
    final hasWorkspace = workspace != null && workspace.isNotEmpty;
    if (!hasId && !hasWorkspace) {
      throw CliException(
        'Missing project ref. Pass --workspace + --project (or --project-id), '
        "or run 'easyi18n init' in a terminal.",
      );
    }

    return Easyi18nConfig(
      ref: ProjectRef.parse(
        projectId: projectId,
        workspace: workspace,
        project: project,
        // Label the parse error with the surface the values came from.
        source: prompted ? 'easyi18n init' : 'flags',
      ),
      baseUrl: results['base-url'] as String?,
      format: results['format'] as String?,
      output: results['output'] as String?,
    );
  }

  void _patchPubspec(File pubspec) {
    if (!pubspec.existsSync()) {
      _report('skipped', pubspec.path, 'not found - not a package root?');
      return;
    }
    var content = pubspec.readAsStringSync();
    var changed = false;

    final withDep = addRuntimeDependency(content);
    if (withDep != null) {
      content = withDep;
      changed = true;
      _report('patched', pubspec.path, 'added easyi18n dependency');
    } else {
      _report('ok', pubspec.path, 'easyi18n already a dependency');
    }

    final withAssets = addAssetsFloor(content);
    if (withAssets != null) {
      content = withAssets;
      changed = true;
      _report('patched', pubspec.path, 'registered $kAssetsFloorDir assets');
    } else {
      _report('ok', pubspec.path, 'assets floor already registered');
    }

    if (changed) _write(pubspec, content);
  }

  void _ensureFloorDir(Directory dir) {
    final keep = File(p.join(dir.path, '.gitkeep'));
    if (dir.existsSync() && (keep.existsSync() || dir.listSync().isNotEmpty)) {
      _report('ok', '${dir.path}/', 'floor dir present');
      return;
    }
    if (!_dryRun) {
      dir.createSync(recursive: true);
      keep.writeAsStringSync('');
    }
    _report('created', '${dir.path}/', 'offline floor dir');
  }

  void _patchGitignore(File gitignore) {
    final content = gitignore.existsSync() ? gitignore.readAsStringSync() : '';
    final patched = addGitignoreEntry(content);
    if (patched == null) {
      _report('ok', gitignore.path, '$kStateIgnoreEntry already ignored');
      return;
    }
    _write(gitignore, patched);
    _report('patched', gitignore.path, 'ignored $kStateIgnoreEntry');
  }

  void _patchEntitlements(File plist) {
    if (!plist.existsSync()) {
      _report('skipped', plist.path, 'no macOS target');
      return;
    }
    final patched = patchEntitlements(plist.readAsStringSync());
    if (patched == null) {
      _report('ok', plist.path, '$kNetworkClientKey already set');
      return;
    }
    _write(plist, patched);
    _report('patched', plist.path, 'granted $kNetworkClientKey');
  }

  void _wireScope(File main, Easyi18nConfig config) {
    if (!main.existsSync()) {
      _report('skipped', main.path, 'not found - wire the scope manually:');
      _logger.info(scopeSnippet(config.ref));
      return;
    }
    final source = main.readAsStringSync();
    final String? patched;
    try {
      patched = wrapRunApp(source, config.ref);
    } on ScaffoldUnpatchable catch (e) {
      _report('skipped', main.path, '${e.reason} - wire the scope manually:');
      _logger.info(scopeSnippet(config.ref));
      return;
    }
    if (patched == null) {
      _report('ok', main.path, 'Easyi18nScope already mounted');
      return;
    }
    _write(main, patched);
    _report('patched', main.path, 'wrapped runApp in Easyi18nScope');
  }

  // ----- plumbing -----------------------------------------------------------

  void _write(File file, String content) {
    if (_dryRun) return;
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  void _report(String verb, String target, String detail) {
    const wouldForms = {
      'created': 'would create',
      'patched': 'would patch',
      'rewrote': 'would rewrite',
    };
    final prefix = _dryRun ? (wouldForms[verb] ?? verb) : verb;
    _logger.detail('$prefix  $target - $detail');
  }

  /// Asks for a value on the terminal. Returns null when stdin is not a TTY so
  /// the caller can fail (required) instead of blocking on `readLineSync`.
  static String? _terminalPrompt(String label) {
    if (!stdin.hasTerminal) return null;
    stdout.write('$label: ');
    return stdin.readLineSync();
  }
}
