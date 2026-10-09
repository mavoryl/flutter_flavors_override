import 'dart:io';

import 'package:glob/glob.dart';
import 'package:glob/list_local_fs.dart';
import 'package:path/path.dart' as p;

import 'errors.dart';
import 'local_package.dart';

/// How the packages of a project resolve.
enum ProjectMode {
  /// A pub workspace: one resolution for the root and every member.
  workspace,

  /// No workspace: every local package resolves on its own.
  packages,
}

/// The local packages of a project and the edges between them.
class Project {
  Project._({
    required this.root,
    required this.mode,
    required this.packages,
    required this.members,
    required Map<String, String> linkedByName,
  }) : _linkedByName = linkedByName;

  /// Workspace root; without a workspace, the root of the melos repository
  /// the start package belongs to, else the start package.
  final LocalPackage root;

  final ProjectMode mode;

  /// Every local package found, keyed by absolute dir: root, workspace members,
  /// melos packages, everything reachable through local edges.
  final Map<String, LocalPackage> packages;

  /// Workspace mode: dirs of the root and every workspace member, nested
  /// workspaces included. Packages mode: empty.
  final Set<String> members;

  /// Package name → dir of the local packages a dependency reaches by name,
  /// without `path:`: workspace members, melos packages.
  final Map<String, String> _linkedByName;

  /// Dirs of packages that resolve on their own: workspace → [root]; packages
  /// mode → every local package. Sorted.
  List<String> get resolvingDirs => switch (mode) {
        ProjectMode.workspace => [root.dir],
        ProjectMode.packages => packages.keys.toList()..sort(),
      };

  /// Dirs of local packages [dir] depends on, sorted. [resolving] adds
  /// dev_dependencies.
  List<String> localDependencies(String dir, {required bool resolving}) {
    final dirs = {
      for (final edge in _edges(
        _package(dir),
        resolving: resolving,
        linkedByName: _linkedByName,
      ))
        if (packages.containsKey(edge.dir)) edge.dir,
    };
    return dirs.toList()..sort();
  }

  /// [dir] plus everything reachable from it (dev_dependencies only at the
  /// first hop from a resolving package; workspace mode: every member is
  /// resolving).
  Set<String> reachableFrom(String dir) {
    final start = _package(dir).dir;
    final result = {start};
    final queue = [start];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      final resolving = (current == start && mode == ProjectMode.packages) ||
          members.contains(current);
      for (final next in localDependencies(current, resolving: resolving)) {
        if (result.add(next)) queue.add(next);
      }
    }
    return result;
  }

  LocalPackage _package(String dir) {
    final package = packages[canonicalDir(dir)];
    if (package == null) {
      throw ArgumentError.value(dir, 'dir', 'Not a local package');
    }
    return package;
  }

  /// Start at [startDir] (must contain pubspec.yaml). If the package has
  /// `resolution: workspace`, walk up to the nearest ancestor whose expanded
  /// `workspace:` contains it; error if none. Without a workspace, the root is
  /// that of the melos repository the package belongs to, if any (see
  /// [_melosRepository]).
  static Project discover(String startDir) {
    var root = LocalPackage.load(startDir);
    // A root can itself be a member of an outer workspace.
    while (root.inWorkspace) {
      root = _workspaceRoot(root);
    }

    if (root.workspace == null) {
      final melos = _melosRepository(root);
      root = melos?.root ?? root;
      final melosPackages = melos?.packages ?? const <String, LocalPackage>{};
      // melos 6 links a dependency on a melos package's name to the package.
      final linkedByName = _byName(melosPackages.values);
      final packages = {...melosPackages, root.dir: root};
      _addReachable(
        packages,
        linkedByName: linkedByName,
        isResolving: (_) => true,
      );
      return Project._(
        root: root,
        mode: ProjectMode.packages,
        packages: packages,
        members: const {},
        linkedByName: linkedByName,
      );
    }

    final members = _workspaceMembers(root);
    // pub resolves a dependency on a member's name to the member.
    final linkedByName = _byName(members.values);
    final packages = {...members};
    _addReachable(
      packages,
      linkedByName: linkedByName,
      isResolving: members.containsKey,
    );
    return Project._(
      root: root,
      mode: ProjectMode.workspace,
      packages: packages,
      members: members.keys.toSet(),
      linkedByName: linkedByName,
    );
  }

  /// The nearest ancestor of [member] whose `workspace:` lists it.
  static LocalPackage _workspaceRoot(LocalPackage member) {
    var dir = member.dir;
    while (p.dirname(dir) != dir) {
      dir = p.dirname(dir);
      if (!_hasPubspec(dir)) continue;
      final candidate = LocalPackage.load(dir);
      if (candidate.workspace != null &&
          _workspaceDirs(candidate).contains(member.dir)) {
        return candidate;
      }
    }
    throw FlavorOverridesException(
      '${member.pubspecPath}: has `resolution: workspace`, but no parent '
      'directory has a pubspec.yaml whose `workspace:` lists it.',
    );
  }

  /// [root] and every member of its workspace, nested workspaces included.
  static Map<String, LocalPackage> _workspaceMembers(LocalPackage root) {
    final members = {root.dir: root};
    final queue = [root];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      if (current.workspace == null) continue;
      for (final dir in _workspaceDirs(current)) {
        if (members.containsKey(dir)) continue;
        final member = LocalPackage.load(dir);
        members[dir] = member;
        queue.add(member);
      }
    }
    return members;
  }

  /// Dirs listed by the `workspace:` of [root], globs expanded. Like pub, a
  /// glob skips directories without pubspec.yaml, a plain path requires one.
  static List<String> _workspaceDirs(LocalPackage root) {
    final dirs = <String>{};
    for (final entry in root.workspace!) {
      if (_isGlob(entry)) {
        dirs.addAll(_globPackageDirs(entry, root.dir, root.pubspecPath));
        continue;
      }
      final dir = canonicalDir(p.join(root.dir, entry));
      if (!_hasPubspec(dir)) {
        throw FlavorOverridesException(
          '${root.pubspecPath}: workspace entry `$entry` points to $dir, '
          'which has no pubspec.yaml.',
        );
      }
      dirs.add(dir);
    }
    return dirs.toList()..sort();
  }

  /// The melos repository [start] belongs to: the nearest melos.yaml in the
  /// dir of [start] or above, if it is next to [start] or its `packages:`
  /// match [start]; the root is the package next to it. Null when there is no
  /// melos.yaml, when the nearest one does not list [start] (no search
  /// further up), or when the root has a `workspace:` (which resolves its
  /// members only).
  static ({LocalPackage root, Map<String, LocalPackage> packages})?
      _melosRepository(LocalPackage start) {
    for (var dir = start.dir;; dir = p.dirname(dir)) {
      final path = p.join(dir, 'melos.yaml');
      if (File(path).existsSync()) {
        final packages = _melosPackages(path);
        if (dir != start.dir && !packages.containsKey(start.dir)) return null;
        if (!_hasPubspec(dir)) {
          throw FlavorOverridesException(
            '$path: lists ${start.dir}, but its directory has no '
            'pubspec.yaml.',
          );
        }
        final root = dir == start.dir ? start : LocalPackage.load(dir);
        if (root.workspace != null) return null;
        return (root: root, packages: packages);
      }
      if (p.dirname(dir) == dir) return null;
    }
  }

  /// Packages matched by the `packages:` globs of the melos.yaml at [path].
  static Map<String, LocalPackage> _melosPackages(String path) {
    final rootDir = p.dirname(path);
    final config = readYamlFile(path);
    final patterns = config is Map<String, Object?> ? config['packages'] : null;
    if (patterns is! List<Object?> || patterns.any((e) => e is! String)) {
      throw FlavorOverridesException(
        '$path: `packages` must be a list of globs.',
      );
    }
    return {
      for (final pattern in patterns.cast<String>())
        for (final dir in _globPackageDirs(pattern, rootDir, path))
          dir: LocalPackage.load(dir),
    };
  }

  static bool _isGlob(String entry) => entry.contains(RegExp(r'[*?[{]'));

  /// Directories under [rootDir] that match [pattern] and have pubspec.yaml.
  /// Links are not followed into, so a link cycle cannot loop; a matching
  /// link to a directory counts.
  /// [source] is the file the pattern comes from, for errors.
  static List<String> _globPackageDirs(
    String pattern,
    String rootDir,
    String source,
  ) {
    final Glob glob;
    try {
      glob = Glob(pattern);
    } on FormatException catch (e) {
      throw FlavorOverridesException(
        '$source: `$pattern` is not a valid glob: ${e.message}',
      );
    }
    return [
      for (final entity in glob.listSync(root: rootDir, followLinks: false))
        if ((entity is Directory ||
                (entity is Link &&
                    FileSystemEntity.isDirectorySync(entity.path))) &&
            _hasPubspec(entity.path))
          canonicalDir(entity.path),
    ];
  }

  static bool _hasPubspec(String dir) =>
      File(p.join(dir, 'pubspec.yaml')).existsSync();

  /// Package name → dir. Two packages with one name is an error.
  static Map<String, String> _byName(Iterable<LocalPackage> packages) {
    final byName = <String, LocalPackage>{};
    for (final package in packages) {
      final other = byName[package.name];
      if (other != null) {
        throw FlavorOverridesException(
          '${other.pubspecPath} and ${package.pubspecPath} both have '
          '`name: ${package.name}`.',
        );
      }
      byName[package.name] = package;
    }
    return {
      for (final MapEntry(:key, :value) in byName.entries) key: value.dir
    };
  }

  /// Adds to [packages] every package reachable from them through local
  /// edges.
  static void _addReachable(
    Map<String, LocalPackage> packages, {
    required Map<String, String> linkedByName,
    required bool Function(String dir) isResolving,
  }) {
    final queue = [...packages.values];
    while (queue.isNotEmpty) {
      final package = queue.removeLast();
      for (final edge in _edges(
        package,
        resolving: isResolving(package.dir),
        linkedByName: linkedByName,
      )) {
        if (packages.containsKey(edge.dir)) continue;
        if (!_hasPubspec(edge.dir)) {
          throw FlavorOverridesException(
            '${package.pubspecPath}: dependency `${edge.name}` points to '
            '${edge.dir}, which has no pubspec.yaml.',
          );
        }
        final dependency = LocalPackage.load(edge.dir);
        packages[dependency.dir] = dependency;
        queue.add(dependency);
      }
    }
  }

  /// Local dependencies of [package]: those given by `path:`, and those given
  /// otherwise whose name is in [linkedByName].
  static List<({String name, String dir})> _edges(
    LocalPackage package, {
    required bool resolving,
    required Map<String, String> linkedByName,
  }) {
    final edges = <({String name, String dir})>[];
    void add(String name, Object? spec) {
      if (spec is Map<String, Object?> && spec.containsKey('path')) {
        final path = spec['path'];
        if (path is String) {
          edges.add((name: name, dir: canonicalDir(p.join(package.dir, path))));
        }
        return;
      }
      final linked = linkedByName[name];
      if (linked != null) edges.add((name: name, dir: linked));
    }

    package.dependencies.forEach(add);
    if (resolving) package.devDependencies.forEach(add);
    return edges;
  }
}
