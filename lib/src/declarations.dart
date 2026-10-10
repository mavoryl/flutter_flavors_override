import 'package:path/path.dart' as p;

import 'errors.dart';
import 'local_package.dart' show canonicalDir;
import 'paths.dart';
import 'project.dart';

/// One package to override in a pubspec_overrides.yaml.
class Declaration {
  const Declaration({
    required this.package,
    required this.spec,
    required this.sources,
  });

  final String package;

  /// Spec rebased to the target dir (plain Dart).
  final Object? spec;

  /// pubspec paths that declare it (several when deduplicated).
  final List<String> sources;
}

/// Declarations for [flavor] that apply to the pubspec_overrides.yaml in
/// [targetDir]: from every package in `project.reachableFrom(targetDir)`
/// (workspace mode: from every local package). Sorted by package name.
/// Identical rebased specs collapse; different specs for one package throw,
/// naming every source.
List<Declaration> declarationsFor(
  Project project,
  String targetDir,
  String flavor,
) {
  final target = canonicalDir(targetDir);
  final sourceDirs = switch (project.mode) {
    ProjectMode.workspace => project.packages.keys,
    ProjectMode.packages => project.reachableFrom(target),
  };

  final found = <String, List<_Found>>{};
  for (final dir in sourceDirs.toList()..sort()) {
    final package = project.packages[dir]!;
    final entries = package.flavorOverrides[flavor] ?? const {};
    for (final MapEntry(key: name, value: written) in entries.entries) {
      found.putIfAbsent(name, () => []).add((
        source: package.pubspecPath,
        written: written,
        spec: rebaseSpec(written, fromDir: dir, toDir: target),
      ));
    }
  }

  return [
    for (final name in found.keys.toList()..sort())
      _collapse(name, flavor, found[name]!),
  ];
}

typedef _Found = ({String source, Object? written, Object? spec});

Declaration _collapse(String name, String flavor, List<_Found> found) {
  final spec = found.first.spec;
  if (found.any((f) => !_deepEquals(f.spec, spec))) {
    throw FlavorOverridesException(
      'Different flavor_overrides for `$name` in flavor `$flavor`:\n'
      '${found.map((f) => '  ${f.source}: ${f.written}').join('\n')}',
    );
  }
  return Declaration(
    package: name,
    spec: spec,
    sources: [for (final f in found) f.source],
  );
}

bool _deepEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && _deepEquals(a[k], b[k]));
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// Rebases `path:` (and a relative filesystem `git:` url / `git: {url:}`) from
/// [fromDir] to [toDir]; `/` separators; normalized; absolute paths
/// untouched; hosted/sdk specs returned as is.
Object? rebaseSpec(
  Object? spec, {
  required String fromDir,
  required String toDir,
}) {
  if (spec is! Map<String, Object?>) return spec;
  String rebase(String path) =>
      rebasePath(path, fromDir: fromDir, toDir: toDir);

  final path = spec['path'];
  if (path is String && !p.isAbsolute(path)) {
    return {...spec, 'path': rebase(path)};
  }

  final git = spec['git'];
  if (git is String && _isRelativeGitUrl(git)) {
    return {...spec, 'git': rebase(git)};
  }
  if (git is Map<String, Object?>) {
    final url = git['url'];
    if (url is String && _isRelativeGitUrl(url)) {
      return {
        ...spec,
        'git': {...git, 'url': rebase(url)},
      };
    }
  }
  return spec;
}

/// Like pub: a url with `@` is ssh, a url with a scheme is remote; anything
/// else that is not absolute is a path relative to the pubspec.
bool _isRelativeGitUrl(String url) {
  if (url.contains('@') || p.isAbsolute(url)) return false;
  final uri = Uri.tryParse(url);
  return uri != null && uri.scheme.isEmpty;
}
