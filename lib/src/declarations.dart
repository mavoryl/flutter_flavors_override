import 'package:path/path.dart' as p;

import 'config.dart';
import 'local_package.dart' show canonicalDir;
import 'paths.dart';
import 'project.dart';
import 'usage.dart';

/// One package to override in a pubspec_overrides.yaml.
class Declaration {
  const Declaration({required this.package, required this.spec});

  final String package;

  /// Spec rebased to the target dir (plain Dart).
  final Object? spec;
}

/// The overrides of [flavor] for the pubspec_overrides.yaml in [targetDir],
/// one of `project.resolvingDirs`: every package of `config.forFlavor(flavor)`
/// that the resolution of [targetDir] uses (see [usedPackages]), its spec
/// rebased from `config.dir` to [targetDir]. Sorted by package name. A
/// pubspec.lock that cannot be read adds a warning to [warnings].
List<Declaration> declarationsFor(
  Project project,
  OverridesConfig config,
  String targetDir,
  String flavor, {
  List<String>? warnings,
}) {
  final target = canonicalDir(targetDir);
  final used = usedPackages(project, target, warnings: warnings);
  return [
    for (final MapEntry(key: name, value: spec)
        in config.forFlavor(flavor).entries)
      if (used.contains(name))
        Declaration(
          package: name,
          spec: rebaseSpec(spec, fromDir: config.dir, toDir: target),
        ),
  ];
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
