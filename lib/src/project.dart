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
    required this.warnings,
    required Map<String, String> linkedByName,
    required Map<String, String> workspaceOverrides,
  })  : _linkedByName = linkedByName,
        _workspaceOverrides = workspaceOverrides;

  /// Workspace root; without a workspace, the root of the melos repository
  /// the start package belongs to, else the start package.
  final LocalPackage root;

  final ProjectMode mode;

  /// Every local package found, keyed by absolute dir: root, workspace members,
  /// melos packages, everything reachable through local edges, `path:`
  /// overrides of a package that resolves included.
  final Map<String, LocalPackage> packages;

  /// Workspace mode: dirs of the root and every workspace member, nested
  /// workspaces included. Packages mode: empty.
  final Set<String> members;

  /// Problems found that do not stop a run, such as a `path:` dependency on
  /// a directory that does not exist (yet), whose edge is skipped.
  final List<String> warnings;

  /// Package name → dir of the local packages a dependency reaches by name,
  /// without `path:`: workspace members, melos packages.
  final Map<String, String> _linkedByName;

  /// Workspace mode: package name → dir of the `path:` overrides of every
  /// member, which pub applies to the whole workspace. Packages mode: empty.
  final Map<String, String> _workspaceOverrides;

  /// Dirs of packages that resolve on their own: workspace → [root]; packages
  /// mode → every local package. Sorted.
  List<String> get resolvingDirs => switch (mode) {
        ProjectMode.workspace => [root.dir],
        ProjectMode.packages => packages.keys.toList()..sort(),
      };

  /// Dirs of local packages [dir] depends on in the resolution of
  /// [resolution], one of [resolvingDirs], sorted. A package that resolves
  /// ([resolution] itself; workspace mode: every member) adds its
  /// dev_dependencies.
  List<String> localDependencies(String dir, {required String resolution}) {
    final package = _package(dir);
    final dirs = {
      for (final edge in _edges(
        package,
        resolving: switch (mode) {
          ProjectMode.workspace => members.contains(package.dir),
          ProjectMode.packages => package.dir == _package(resolution).dir,
        },
        linkedByName: _linkedByName,
        overrides: switch (mode) {
          ProjectMode.workspace => _workspaceOverrides,
          ProjectMode.packages => _pathOverrides(_package(resolution)),
        },
      ))
        if (packages.containsKey(edge.dir)) edge.dir,
    };
    return dirs.toList()..sort();
  }

  /// [dir] plus everything reachable from it in its resolution: its own
  /// (packages mode) or the workspace's.
  Set<String> reachableFrom(String dir) {
    final start = _package(dir).dir;
    final resolution = mode == ProjectMode.workspace ? root.dir : start;
    final result = {start};
    final queue = [start];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      for (final next in localDependencies(current, resolution: resolution)) {
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
      final warnings = <String>{};
      // Every local package resolves on its own, with its own overrides.
      final pending = [...packages.keys];
      final resolved = <String>{};
      while (pending.isNotEmpty) {
        final dir = pending.removeLast();
        if (!resolved.add(dir)) continue;
        pending.addAll(_addResolution(
          packages,
          from: [dir],
          linkedByName: linkedByName,
          overrides: _pathOverrides(packages[dir]!),
          isResolving: (other) => other == dir,
          warnings: warnings,
        ));
      }
      return Project._(
        root: root,
        mode: ProjectMode.packages,
        packages: packages,
        members: const {},
        warnings: warnings.toList(),
        linkedByName: linkedByName,
        workspaceOverrides: const {},
      );
    }

    final members = _workspaceMembers(root);
    // pub resolves a dependency on a member's name to the member.
    final linkedByName = _byName(members.values);
    final overrides = {
      for (final dir in members.keys.toList()..sort())
        ..._pathOverrides(members[dir]!),
    };
    final packages = {...members};
    final warnings = <String>{};
    _addResolution(
      packages,
      from: members.keys,
      linkedByName: linkedByName,
      overrides: overrides,
      isResolving: members.containsKey,
      warnings: warnings,
    );
    return Project._(
      root: root,
      mode: ProjectMode.workspace,
      packages: packages,
      members: members.keys.toSet(),
      warnings: warnings.toList(),
      linkedByName: linkedByName,
      workspaceOverrides: overrides,
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

  /// What melos 6.3.3 leaves out of every package list, whatever melos.yaml
  /// says: `PackageMap._commonIgnorePatterns` in its lib/src/package.dart.
  /// Flutter's plugin links (iOS/macOS `.symlinks/plugins`, Linux/Windows
  /// `.plugin_symlinks`) point into the pub cache.
  static const _melosDefaultIgnore = [
    '**/.dart_tool/**',
    '**/.symlinks/plugins/**',
    '**/.fvm/**',
    '**/.plugin_symlinks/**',
  ];

  /// The packages of the melos.yaml at [path], found as melos 6.3.3 finds
  /// them (`PackageMap.resolvePackages`): every `<glob>/pubspec.yaml` of its
  /// `packages:`, links followed, except those that match `<glob>/pubspec.yaml`
  /// of its `ignore:` or of [_melosDefaultIgnore]. Globs are relative to the
  /// melos.yaml.
  static Map<String, LocalPackage> _melosPackages(String path) {
    final rootDir = p.dirname(path);
    final config = readYamlFile(path);
    List<String> globs(String key, {required bool required}) {
      final value = config is Map<String, Object?> ? config[key] : null;
      if (value == null && !required) return const [];
      if (value is! List<Object?> || value.any((e) => e is! String)) {
        throw FlavorOverridesException(
          '$path: `$key` must be a list of globs.',
        );
      }
      return value.cast<String>();
    }

    final patterns = globs('packages', required: true);
    final ignore = [
      for (final pattern in [
        ...globs('ignore', required: false),
        ..._melosDefaultIgnore,
      ])
        _melosPubspecGlob(pattern, rootDir, path),
    ];
    final packages = <String, LocalPackage>{};
    for (final pattern in patterns) {
      final glob = _melosPubspecGlob(pattern, rootDir, path);
      for (final entity in glob.listSync(root: rootDir)) {
        if (entity is! File || ignore.any((i) => i.matches(entity.path))) {
          continue;
        }
        final dir = canonicalDir(entity.parent.path);
        packages[dir] ??= LocalPackage.load(dir);
      }
    }
    return packages;
  }

  /// `<pattern>/pubspec.yaml`, relative to [rootDir], as melos 6.3.3 builds
  /// it (`PackageMap._createPubspecGlob`).
  static Glob _melosPubspecGlob(String pattern, String rootDir, String source) {
    _parseGlob(pattern, source);
    return Glob(
      p.posix.normalize('$pattern/pubspec.yaml'),
      context: p.Context(current: rootDir),
    );
  }

  static bool _isGlob(String entry) => entry.contains(RegExp(r'[*?[{]'));

  /// [pattern] as a glob; [source] is the file it comes from, for errors.
  static Glob _parseGlob(String pattern, String source) {
    try {
      return Glob(pattern);
    } on FormatException catch (e) {
      throw FlavorOverridesException(
        '$source: `$pattern` is not a valid glob: ${e.message}',
      );
    }
  }

  /// Directories under [rootDir] that match [pattern] and have pubspec.yaml.
  /// Links are not followed into, so a link cycle cannot loop; a matching
  /// link to a directory counts.
  /// [source] is the file the pattern comes from, for errors.
  static List<String> _globPackageDirs(
    String pattern,
    String rootDir,
    String source,
  ) {
    final glob = _parseGlob(pattern, source);
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

  /// Adds to [packages] every package of one resolution: those reachable
  /// from the packages [from] through local edges, where [isResolving]
  /// packages add their dev_dependencies and [overrides] apply. Returns the
  /// dirs reached. An edge to a directory that does not exist is skipped,
  /// with a message added to [warnings].
  static Set<String> _addResolution(
    Map<String, LocalPackage> packages, {
    required Iterable<String> from,
    required Map<String, String> linkedByName,
    required Map<String, String> overrides,
    required bool Function(String dir) isResolving,
    required Set<String> warnings,
  }) {
    final reached = {...from};
    final queue = [...from];
    while (queue.isNotEmpty) {
      final package = packages[queue.removeLast()]!;
      for (final edge in _edges(
        package,
        resolving: isResolving(package.dir),
        linkedByName: linkedByName,
        overrides: overrides,
      )) {
        if (reached.contains(edge.dir)) continue;
        if (!packages.containsKey(edge.dir)) {
          if (FileSystemEntity.typeSync(edge.dir) ==
              FileSystemEntityType.notFound) {
            warnings.add(
              '${package.pubspecPath}: dependency `${edge.name}` points to '
              '${edge.dir}, which does not exist; skipped.',
            );
            continue;
          }
          if (!_hasPubspec(edge.dir)) {
            throw FlavorOverridesException(
              '${package.pubspecPath}: dependency `${edge.name}` points to '
              '${edge.dir}, which has no pubspec.yaml.',
            );
          }
          packages[edge.dir] = LocalPackage.load(edge.dir);
        }
        reached.add(edge.dir);
        queue.add(edge.dir);
      }
    }
    return reached;
  }

  /// Local dependencies of [package] in a resolution whose `path:` overrides
  /// are [overrides] (package name → dir). A dependency on an overridden
  /// name is on the override's dir, whatever its spec; otherwise one given
  /// by `path:` is local, and one given otherwise is local if its name is in
  /// [linkedByName]. A [resolving] package adds its dev_dependencies, and
  /// the dirs of its own `path:` overrides: it may reach those through
  /// packages that are not local.
  static List<({String name, String dir})> _edges(
    LocalPackage package, {
    required bool resolving,
    required Map<String, String> linkedByName,
    required Map<String, String> overrides,
  }) {
    final edges = <({String name, String dir})>[
      if (resolving)
        for (final MapEntry(key: name, value: dir)
            in _pathOverrides(package).entries)
          (name: name, dir: dir),
    ];
    void add(String name, Object? spec) {
      final overridden = overrides[name];
      if (overridden != null) {
        edges.add((name: name, dir: overridden));
        return;
      }
      if (spec is Map<String, Object?> && spec.containsKey('path')) {
        final dir = _pathDir(package, spec);
        if (dir != null) edges.add((name: name, dir: dir));
        return;
      }
      final linked = linkedByName[name];
      if (linked != null) edges.add((name: name, dir: linked));
    }

    package.dependencies.forEach(add);
    if (resolving) package.devDependencies.forEach(add);
    return edges;
  }

  /// Package name → dir of the `dependency_overrides` of [package] given by
  /// `path:`.
  static Map<String, String> _pathOverrides(LocalPackage package) => {
        for (final MapEntry(key: name, value: spec)
            in package.dependencyOverrides.entries)
          if (_pathDir(package, spec) case final dir?) name: dir,
      };

  /// The dir of the `path:` of [spec], a dependency of [package]; null when
  /// it has none.
  static String? _pathDir(LocalPackage package, Object? spec) {
    if (spec is! Map<String, Object?>) return null;
    final path = spec['path'];
    return path is String ? canonicalDir(p.join(package.dir, path)) : null;
  }
}
