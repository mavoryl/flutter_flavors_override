import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'declarations.dart';
import 'errors.dart';
import 'local_package.dart' show readYamlFile;
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
    final project = Project.discover(
      directory == null ? base : p.join(base, directory),
    );

    if (listDependents) {
      _dependents(project, flavor!).forEach(output.writeln);
      return 0;
    }

    // Plan every file first: an error leaves the project untouched.
    final changes = [
      for (final dir in project.resolvingDirs)
        if (_change(project, dir, clean ? null : flavor) case final change?)
          change,
    ];

    if (changes.isEmpty) {
      output.writeln('up to date');
      return 0;
    }
    final dryRun = options.flag('dry-run');
    for (final change in changes) {
      final rel = _relative(project, change.path);
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

/// The change of the pubspec_overrides.yaml in [dir] for [flavor] (null:
/// clean), or null when the file stays as it is.
_Change? _change(Project project, String dir, String? flavor) {
  final declarations = flavor == null
      ? const <Declaration>[]
      : declarationsFor(project, dir, flavor);
  final path = _overridesPath(dir);
  if (project.mode == ProjectMode.workspace) {
    _checkMembers(project, {for (final d in declarations) d.package}, path);
  }
  final existing = _read(path);
  final text = mergeOverrides(
    existing: existing,
    desired: {for (final d in declarations) d.package: d.spec},
    pubspecOverrides: project.packages[dir]!.dependencyOverrides,
    filePath: path,
  );
  if (text == existing) return null;
  return (
    path: path,
    text: text,
    packages: [for (final d in declarations) d.package],
  );
}

/// pub fails when a workspace overrides a package in two files (T5): no member
/// but the root may override what [rootFile] is about to.
void _checkMembers(Project project, Set<String> packages, String rootFile) {
  if (packages.isEmpty) return;
  for (final dir in project.members.toList()..sort()) {
    if (dir == project.root.dir) continue;
    final member = project.packages[dir]!;
    final overridesPath = _overridesPath(dir);
    final overridesFile =
        _read(overridesPath) == null ? null : readYamlFile(overridesPath);
    final sources = [
      (member.pubspecPath, member.dependencyOverrides),
      if (overridesFile is Map<String, Object?>)
        (overridesPath, overridesFile['dependency_overrides']),
    ];
    for (final (source, overrides) in sources) {
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
}

/// Local packages, relative to the root and sorted, whose dependencies or
/// dev_dependencies include a package overridden in [flavor] anywhere.
List<String> _dependents(Project project, String flavor) {
  final overridden = {
    for (final package in project.packages.values)
      ...?package.flavorOverrides[flavor]?.keys,
  };
  return [
    for (final package in project.packages.values)
      if (package.dependencies.keys.any(overridden.contains) ||
          package.devDependencies.keys.any(overridden.contains))
        _relative(project, package.dir),
  ]..sort();
}

String _overridesPath(String dir) => p.join(dir, 'pubspec_overrides.yaml');

/// Content of the file at [path], or null when there is none.
String? _read(String path) {
  final file = File(path);
  return file.existsSync() ? file.readAsStringSync() : null;
}

/// [path] relative to the project root, with `/`.
String _relative(Project project, String path) =>
    p.posix.joinAll(p.split(p.relative(path, from: project.root.dir)));
