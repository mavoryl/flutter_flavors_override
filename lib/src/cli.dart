import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'config.dart';
import 'declarations.dart';
import 'errors.dart';
import 'flavor_hint.dart';
import 'local_package.dart' show canonicalDir, readYamlFile, toPlain;
import 'overrides_file.dart';
import 'paths.dart';
import 'project.dart';
import 'usage.dart';

const _name = 'flutter_flavor_overrides';

final _parser = ArgParser(usageLineLength: 80)
  ..addOption(
    'flavor',
    abbr: 'f',
    valueHelp: 'name',
    help: 'Write the overrides flavor_overrides.yaml gives for flavor <name>.',
  )
  ..addFlag(
    'clean',
    negatable: false,
    help: 'Remove the entries this tool wrote, in every file.',
  )
  ..addFlag(
    'dry-run',
    negatable: false,
    help: 'Print what would be written or removed; change nothing.',
  )
  ..addFlag(
    'list-dependents',
    negatable: false,
    help: 'Print the local packages that depend on a package overridden in '
        'this flavor, one path per line; change nothing.',
  )
  ..addOption(
    'directory',
    abbr: 'C',
    valueHelp: 'dir',
    help: 'Run in <dir> instead of the current directory.',
  )
  ..addFlag(
    'help',
    abbr: 'h',
    negatable: false,
    help: 'Print this usage.',
  );

String get _usage => 'Generates pubspec_overrides.yaml from the per-flavor '
    'overrides in\nflavor_overrides.yaml, next to the root pubspec.yaml of '
    'the project, for\nevery package that uses an overridden package.\n\n'
    'Usage: $_name --flavor <name> [--dry-run]\n'
    '       $_name --flavor <name> --list-dependents\n'
    '       $_name --clean [--dry-run]\n\n'
    '${_parser.usage}';

/// Runs the CLI with command-line [arguments] and returns the process exit
/// code: 0 on success, 64 on a usage error, 1 on a project error.
Future<int> run(
  List<String> arguments, {
  String? workingDirectory,
  StringSink? out,
  StringSink? err,
}) async {
  final output = out ?? stdout;
  final errors = err ?? stderr;

  int usageError(String message) {
    errors
      ..writeln('$_name: $message')
      ..writeln()
      ..writeln(_usage);
    return 64;
  }

  final ArgResults options;
  try {
    options = _parser.parse(arguments);
  } on FormatException catch (e) {
    return usageError(e.message);
  }
  if (options.flag('help')) {
    output.writeln(_usage);
    return 0;
  }
  if (options.rest.isNotEmpty) {
    return usageError('unexpected arguments: ${options.rest.join(' ')}');
  }
  final flavor = options.option('flavor');
  final clean = options.flag('clean');
  final listDependents = options.flag('list-dependents');
  if (clean && (flavor != null || listDependents)) {
    return usageError('--clean takes neither --flavor nor --list-dependents.');
  }
  if (!clean && flavor == null) {
    return usageError('--flavor is required, unless --clean is given.');
  }
  if (flavor != null && flavor.isEmpty) {
    return usageError('--flavor must not be empty.');
  }

  // Found while planning; printed before the result, or before the error.
  final warnings = <String>[];
  void printWarnings() {
    for (final warning in {...warnings}) {
      errors.writeln('$_name: warning: $warning');
    }
    warnings.clear();
  }

  try {
    final base = workingDirectory ?? Directory.current.path;
    final directory = options.option('directory');
    // Where the tool runs, after -C: printed paths are relative to it.
    final start = canonicalDir(
      directory == null ? base : p.join(base, directory),
    );
    final configPath = OverridesConfig.find(start);
    final config = configPath == null ? null : OverridesConfig.load(configPath);
    if (config == null && !clean && !_hasPubspec(start)) {
      throw _noConfig(start);
    }
    if (config != null && !_hasPubspec(config.dir)) {
      throw FlavorOverridesException(
        '${config.path}: no pubspec.yaml next to it; $configFileName goes '
        'next to the root pubspec.yaml of the project.',
      );
    }
    // The project is what its root sees, the root being the directory of
    // the file; without one (--clean only), as found from where it runs.
    final project = Project.discover(config?.dir ?? start);
    for (final warning in project.warnings) {
      errors.writeln('$_name: warning: $warning');
    }
    _checkProject(project, config);
    if (config == null && !clean) throw _noConfig(start);

    // Most likely a typo in --flavor; still a valid run, which removes ours.
    if (flavor != null && !config!.flavors.contains(flavor)) {
      errors.writeln('$_name: ${missingFlavorNote(flavor, config.flavors)}');
    }
    String relative(String path) => _relative(path, from: start);

    if (listDependents) {
      final overridden = config!.forFlavor(flavor!).keys.toSet();
      _dependents(project, overridden, relative).forEach(output.writeln);
      return 0;
    }

    // Plan every file first: an error leaves the project untouched.
    final changes = _plan(project, config, clean ? null : flavor, warnings);
    printWarnings();

    if (changes.isEmpty) {
      output.writeln('up to date');
      return 0;
    }
    final dryRun = options.flag('dry-run');
    for (final change in changes) {
      final rel = relative(change.path);
      final text = change.text;
      if (dryRun) {
        output.write('--- $rel (would ${text == null ? 'remove' : 'write'})\n'
            '${text ?? ''}');
      } else if (text == null) {
        File(change.path).deleteSync();
        output.writeln('removed $rel');
      } else {
        File(change.path).writeAsStringSync(text);
        final names = change.packages;
        output.writeln(
          names.isEmpty ? 'wrote $rel' : 'wrote $rel (${names.join(', ')})',
        );
      }
    }
    return 0;
  } on FlavorOverridesException catch (e) {
    printWarnings();
    errors.writeln('$_name: error: ${e.message}');
    return 1;
  } on FileSystemException catch (e) {
    printWarnings();
    final reason = e.osError?.message ?? e.message;
    errors.writeln('$_name: error: ${e.path}: $reason');
    return 1;
  }
}

FlavorOverridesException _noConfig(String start) => FlavorOverridesException(
      'no $configFileName in $start or above: create it next to the root '
      'pubspec.yaml of the project.',
    );

bool _hasPubspec(String dir) => File(p.join(dir, 'pubspec.yaml')).existsSync();

/// One flavor_overrides.yaml per project, next to the root pubspec.yaml
/// ([config] or none), and no `flavor_overrides` left in a pubspec of the
/// project: the same errors whichever directory the tool runs from.
void _checkProject(Project project, OverridesConfig? config) {
  final root = project.root;
  final expected = p.join(root.dir, configFileName);
  final misplaced = [
    if (config != null && config.dir != root.dir) config.path,
    for (final dir in project.packages.keys.toList()..sort())
      if (dir != root.dir &&
          dir != config?.dir &&
          File(p.join(dir, configFileName)).existsSync())
        p.join(dir, configFileName),
  ];
  if (misplaced.isNotEmpty) {
    throw FlavorOverridesException(
      '${misplaced.first}: a project has one $configFileName, next to its '
      'root pubspec.yaml (${root.pubspecPath}): move its overrides to '
      '$expected.',
    );
  }
  for (final dir in project.packages.keys.toList()..sort()) {
    final package = project.packages[dir]!;
    if (package.hasFlavorOverridesSection) {
      throw FlavorOverridesException(
        '${package.pubspecPath}: `flavor_overrides` in a pubspec is not '
        'read: move it to $expected (package, then flavor, then dependency '
        'spec).',
      );
    }
  }
}

/// A pubspec_overrides.yaml to write ([text]) or remove (null text).
typedef _Change = ({String path, String? text, List<String> packages});

/// Every file change for [flavor] (null: clean), in output order. Problems
/// that do not stop the run go to [warnings].
List<_Change> _plan(
  Project project,
  OverridesConfig? config,
  String? flavor,
  List<String> warnings,
) {
  if (flavor != null) _checkFlavor(project, config!, flavor, warnings);

  // In a workspace only the root holds our entries: drop any left over in
  // the other local packages, members or not, e.g. from before the project
  // became a workspace. What remains in members must not override what the
  // root file does (T5).
  final others = [
    if (project.mode == ProjectMode.workspace)
      for (final dir in project.packages.keys.toList()..sort())
        if (dir != project.root.dir) dir,
  ];
  final members = <String, String?>{};
  final otherChanges = <_Change>[];
  for (final dir in others) {
    final (:change, :text) = _planFile(project, dir, const []);
    if (project.members.contains(dir)) members[dir] = text;
    if (change != null) otherChanges.add(change);
  }

  final changes = <_Change>[];
  for (final dir in project.resolvingDirs) {
    final declarations = flavor == null
        ? const <Declaration>[]
        : declarationsFor(project, config!, dir, flavor, warnings: warnings);
    _checkMembers(
      project,
      members,
      {for (final d in declarations) d.package},
      _overridesPath(dir),
    );
    final (:change, text: _) = _planFile(project, dir, declarations);
    if (change != null) changes.add(change);
  }
  return [...changes, ...otherChanges];
}

/// The pubspec_overrides.yaml of [dir] with [declarations] as our entries:
/// its new text, and the change, null when the file stays as it is.
({_Change? change, String? text}) _planFile(
  Project project,
  String dir,
  List<Declaration> declarations,
) {
  final path = _overridesPath(dir);
  final existing = _read(path);
  final text = mergeOverrides(
    existing: existing,
    desired: {for (final d in declarations) d.package: d.spec},
    pubspecOverrides: project.packages[dir]!.dependencyOverrides,
    filePath: path,
  );
  if (text == existing) return (change: null, text: text);
  return (
    change: (
      path: path,
      text: text,
      packages: [for (final d in declarations) d.package],
    ),
    text: text,
  );
}

/// What pub would refuse, or what would do nothing, in the overrides of
/// [flavor]: an override of a workspace member ("Cannot override workspace
/// packages", T7) and a `path:` to anything but the package are errors; a
/// package no resolution of the project uses is a warning, as pub would add
/// it to the resolution.
void _checkFlavor(
  Project project,
  OverridesConfig config,
  String flavor,
  List<String> warnings,
) {
  final overrides = config.forFlavor(flavor);
  final members = {
    for (final dir in project.members) project.packages[dir]!.name: dir,
  };
  for (final name in overrides.keys) {
    final dir = members[name];
    if (dir == null) continue;
    throw FlavorOverridesException(
      '${config.path}: flavor `$flavor` overrides `$name`, a member of the '
      'pub workspace (${project.packages[dir]!.pubspecPath}); pub does not '
      'override workspace members. To swap it, take it out of `workspace:` '
      'and depend on it through `path:`.',
    );
  }
  for (final MapEntry(key: name, value: spec) in overrides.entries) {
    _checkPath(config, '$name.$flavor', name, spec);
  }

  final used = {
    for (final dir in project.resolvingDirs)
      ...usedPackages(project, dir, warnings: warnings),
  };
  for (final name in overrides.keys) {
    if (used.contains(name)) continue;
    warnings.add(
      '${config.path}: no package of the project uses `$name`; its override '
      'for flavor `$flavor` is left out.',
    );
  }
}

/// pub fails on a `path:` override whose directory has no pubspec.yaml or
/// holds a package of another name: say so first, naming [place] in
/// [config].
void _checkPath(
  OverridesConfig config,
  String place,
  String name,
  Object? spec,
) {
  if (spec is! Map<String, Object?>) return;
  final path = spec['path'];
  if (path is! String) return;
  final dir = p.normalize(p.join(config.dir, path));
  final pubspec = p.join(dir, 'pubspec.yaml');
  final points = '${config.path}: `$place` points to $dir';
  if (!File(pubspec).existsSync()) {
    throw FlavorOverridesException('$points, which has no pubspec.yaml.');
  }
  final document = readYamlFile(pubspec);
  final found = document is Map<String, Object?> ? document['name'] : null;
  if (found == name) return;
  final what = found is String
      ? 'the package `$found`'
      : 'whose pubspec.yaml has no name';
  throw FlavorOverridesException(
    '$points, $what, not `$name`; pub would refuse it.',
  );
}

/// pub fails when a workspace overrides a package in two files (T5): no member
/// may override what [rootFile] is about to. [members] maps member dirs to
/// their planned pubspec_overrides.yaml text. Only the overrides pub applies
/// count: those of that file when it has `dependency_overrides`, else those
/// of the member's pubspec.
void _checkMembers(
  Project project,
  Map<String, String?> members,
  Set<String> packages,
  String rootFile,
) {
  if (packages.isEmpty) return;
  for (final MapEntry(key: dir, value: text) in members.entries) {
    final member = project.packages[dir]!;
    final overridesFile = text == null ? null : toPlain(loadYaml(text));
    final (source, overrides) = overridesFile is Map<String, Object?> &&
            overridesFile.containsKey('dependency_overrides')
        ? (_overridesPath(dir), overridesFile['dependency_overrides'])
        : (member.pubspecPath, member.dependencyOverrides);
    if (overrides is! Map<String, Object?>) continue;
    for (final name in overrides.keys) {
      if (packages.contains(name)) {
        throw FlavorOverridesException(
          '$source overrides `$name`, which $rootFile is to override as '
          'well; pub does not allow overriding a package in two files of a '
          'workspace. Remove the override from $source.',
        );
      }
    }
  }
}

/// Local packages, as [relative] paths, sorted, whose dependencies or
/// dev_dependencies include an [overridden] package: their code imports it.
List<String> _dependents(
  Project project,
  Set<String> overridden,
  String Function(String path) relative,
) =>
    [
      for (final package in project.packages.values)
        if (package.dependencies.keys.any(overridden.contains) ||
            package.devDependencies.keys.any(overridden.contains))
          relative(package.dir),
    ]..sort();

String _overridesPath(String dir) => p.join(dir, 'pubspec_overrides.yaml');

/// Content of the file at [path], or null when there is none.
String? _read(String path) {
  switch (FileSystemEntity.typeSync(path)) {
    case FileSystemEntityType.notFound:
      return null;
    case FileSystemEntityType.file:
      return File(path).readAsStringSync();
    default:
      throw FlavorOverridesException('$path: exists, but is not a file.');
  }
}

/// [path] relative to [from], with `/`; `.` for [from] itself.
String _relative(String path, {required String from}) =>
    portableRelative(path, from: from);
