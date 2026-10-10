import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'local_package.dart' show canonicalDir, describeYamlException;
import 'project.dart';

/// Names of the packages the resolution of [resolvingDir] (one of
/// `project.resolvingDirs`) uses: every local package reachable in it, every
/// direct dependency of those packages (dev_dependencies only of packages
/// that resolve: the resolving package; in a workspace every member), plus
/// the keys of `packages:` in `<resolvingDir>/pubspec.lock` when that file
/// exists, which also lists what comes through packages that are not local.
/// Never includes the resolving package's own name: pub refuses a package
/// that overrides itself. A lock file that cannot be read adds a warning to
/// [warnings] and counts as absent.
Set<String> usedPackages(Project project, String resolvingDir,
    {List<String>? warnings}) {
  final dir = canonicalDir(resolvingDir);
  final self = project.packages[dir];
  if (self == null) {
    throw ArgumentError.value(resolvingDir, 'resolvingDir', 'Not a package');
  }

  final reachable = switch (project.mode) {
    ProjectMode.workspace => {
        for (final member in project.members) ...project.reachableFrom(member),
      },
    ProjectMode.packages => project.reachableFrom(dir),
  };
  final used = <String>{};
  for (final packageDir in reachable) {
    final package = project.packages[packageDir]!;
    final resolves = switch (project.mode) {
      ProjectMode.workspace => project.members.contains(packageDir),
      ProjectMode.packages => packageDir == dir,
    };
    used
      ..add(package.name)
      ..addAll(package.dependencies.keys);
    if (resolves) used.addAll(package.devDependencies.keys);
  }
  used.addAll(_lockedPackages(p.join(dir, 'pubspec.lock'), warnings));
  return used..remove(self.name);
}

/// The keys of `packages:` in the pubspec.lock at [path]; none when there is
/// no such file, or when it cannot be read, with a warning added to
/// [warnings].
Iterable<String> _lockedPackages(String path, List<String>? warnings) {
  if (!File(path).existsSync()) return const [];
  Iterable<String> ignored(String problem) {
    warnings?.add('$path: $problem; ignored.');
    return const [];
  }

  final Object? lock;
  try {
    lock = loadYaml(File(path).readAsStringSync());
  } on YamlException catch (e) {
    return ignored('not valid YAML: ${describeYamlException(e)}');
  } on FileSystemException catch (e) {
    return ignored('cannot be read: ${e.osError?.message ?? e.message}');
  }
  if (lock is! Map) return ignored('not a pubspec.lock, which is a map');
  final packages = lock['packages'];
  if (packages == null) return const [];
  if (packages is! Map) return ignored('`packages` is not a map');
  return packages.keys.whereType<String>();
}
