import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'declarations.dart';
import 'errors.dart';
import 'local_package.dart' show canonicalDir, toPlain;
import 'overrides_file.dart';
import 'project.dart';

const _name = 'flutter_flavor_overrides';

final _parser = ArgParser(usageLineLength: 80)
  ..addOption(
    'flavor',
    abbr: 'f',
    valueHelp: 'name',
    help: 'Write the overrides declared under flavor_overrides.<name>.',
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
    'flavor_overrides\ndeclarations in pubspec files.\n\n'
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

  try {
    final base = workingDirectory ?? Directory.current.path;
    final directory = options.option('directory');
    // Where the tool runs, after -C: printed paths are relative to it.
    final start = canonicalDir(
      directory == null ? base : p.join(base, directory),
    );
    final project = Project.discover(start);
    for (final warning in project.warnings) {
      errors.writeln('$_name: warning: $warning');
    }
    // Most likely a typo in --flavor; still a valid run, which removes ours.
    if (flavor != null &&
        !project.packages.values
            .any((package) => package.flavorOverrides.containsKey(flavor))) {
      errors.writeln(
        '$_name: no flavor_overrides for flavor `$flavor` in this project',
      );
    }
    String relative(String path) => _relative(path, from: start);

    if (listDependents) {
      _dependents(project, flavor!, relative).forEach(output.writeln);
      return 0;
    }

    // Plan every file first: an error leaves the project untouched.
    final changes = _plan(project, clean ? null : flavor);

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
    errors.writeln('$_name: error: ${e.message}');
    return 1;
  } on FileSystemException catch (e) {
    final reason = e.osError?.message ?? e.message;
    errors.writeln('$_name: error: ${e.path}: $reason');
    return 1;
  }
}

/// A pubspec_overrides.yaml to write ([text]) or remove (null text).
typedef _Change = ({String path, String? text, List<String> packages});

/// Every file change for [flavor] (null: clean), in output order.
List<_Change> _plan(Project project, String? flavor) {
  // Workspace members never hold our entries: drop any left over, e.g. from
  // before the project became a workspace. What remains must not override
  // what the root file does (T5).
  final members = <String, String?>{
    for (final dir in project.members.toList()..sort())
      if (dir != project.root.dir) dir: null,
  };
  final memberChanges = <_Change>[];
  for (final dir in members.keys) {
    final (:change, :text) = _planFile(project, dir, const []);
    members[dir] = text;
    if (change != null) memberChanges.add(change);
  }

  final changes = <_Change>[];
  for (final dir in project.resolvingDirs) {
    final declarations = flavor == null
        ? const <Declaration>[]
        : declarationsFor(project, dir, flavor);
    _checkMembers(
      project,
      members,
      {for (final d in declarations) d.package},
      _overridesPath(dir),
    );
    final (:change, text: _) = _planFile(project, dir, declarations);
    if (change != null) changes.add(change);
  }
  return [...changes, ...memberChanges];
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
/// dev_dependencies include a package overridden in [flavor] anywhere.
List<String> _dependents(
  Project project,
  String flavor,
  String Function(String path) relative,
) {
  final overridden = {
    for (final package in project.packages.values)
      ...?package.flavorOverrides[flavor]?.keys,
  };
  return [
    for (final package in project.packages.values)
      if (package.dependencies.keys.any(overridden.contains) ||
          package.devDependencies.keys.any(overridden.contains))
        relative(package.dir),
  ]..sort();
}

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
    p.posix.joinAll(p.split(p.relative(path, from: from)));
