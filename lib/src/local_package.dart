import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'errors.dart';

/// A package on the local file system, read from its `pubspec.yaml`.
class LocalPackage {
  LocalPackage({
    required String dir,
    required this.name,
    this.dependencies = const {},
    this.devDependencies = const {},
    this.dependencyOverrides = const {},
    this.workspace,
    this.inWorkspace = false,
    this.hasFlavorOverridesSection = false,
  }) : dir = p.normalize(p.absolute(dir));

  /// Absolute, normalized directory of the package; [load] also resolves
  /// symbolic links.
  final String dir;

  final String name;

  /// Values are plain Dart (`String`, `num`, `bool`, `null`, `List`,
  /// `Map<String, Object?>`), not YamlNodes.
  final Map<String, Object?> dependencies;
  final Map<String, Object?> devDependencies;
  final Map<String, Object?> dependencyOverrides;

  /// Raw `workspace:` entries, or null when the pubspec has none.
  final List<String>? workspace;

  /// `resolution: workspace`.
  final bool inWorkspace;

  /// The pubspec has a top-level `flavor_overrides` key, of any shape: where
  /// overrides were declared before flavor_overrides.yaml.
  final bool hasFlavorOverridesSection;

  String get pubspecPath => p.join(dir, 'pubspec.yaml');

  /// Reads `<dir>/pubspec.yaml`. Throws [FlavorOverridesException] naming the
  /// file when it is missing, is not valid YAML, has no string `name`, or when
  /// a dependency section is not a map.
  static LocalPackage load(String dir) {
    final normalized = canonicalDir(dir);
    final pubspecPath = p.join(normalized, 'pubspec.yaml');
    if (!File(pubspecPath).existsSync()) {
      throw FlavorOverridesException('$pubspecPath: not found.');
    }
    final document = readYamlFile(pubspecPath);
    if (document is! Map<String, Object?>) {
      throw FlavorOverridesException('$pubspecPath: must be a map.');
    }
    Never fail(String problem) =>
        throw FlavorOverridesException('$pubspecPath: $problem');

    Map<String, Object?> section(Object? value, String key) => switch (value) {
          // A section without a value is empty, as pub reads it.
          null => <String, Object?>{},
          Map<String, Object?>() => value,
          _ => fail('`$key` must be a map.'),
        };

    final name = document['name'];
    if (name is! String) fail('`name` must be a string.');

    final workspace = document['workspace'];
    if (workspace != null &&
        (workspace is! List<Object?> || workspace.any((e) => e is! String))) {
      fail('`workspace` must be a list of paths.');
    }

    return LocalPackage(
      dir: normalized,
      name: name,
      dependencies: section(document['dependencies'], 'dependencies'),
      devDependencies:
          section(document['dev_dependencies'], 'dev_dependencies'),
      dependencyOverrides: section(
        document['dependency_overrides'],
        'dependency_overrides',
      ),
      workspace: (workspace as List<Object?>?)?.cast<String>(),
      inWorkspace: document['resolution'] == 'workspace',
      hasFlavorOverridesSection: document.containsKey('flavor_overrides'),
    );
  }
}

/// [dir] absolute and normalized, symbolic links resolved when it exists: one
/// package reached through two paths has one canonical dir.
String canonicalDir(String dir) {
  final normalized = p.normalize(p.absolute(dir));
  final directory = Directory(normalized);
  if (!directory.existsSync()) return normalized;
  return p.normalize(directory.resolveSymbolicLinksSync());
}

/// Reads the YAML file at [path] as plain Dart values. Throws
/// [FlavorOverridesException] naming the file when it is not valid YAML.
Object? readYamlFile(String path) {
  try {
    return toPlain(loadYaml(File(path).readAsStringSync()));
  } on YamlException catch (e) {
    throw FlavorOverridesException(
      '$path: not valid YAML: ${describeYamlException(e)}',
    );
  }
}

/// The message of [e] with its line and column, 1-based.
String describeYamlException(YamlException e) {
  final start = e.span?.start;
  if (start == null) return e.message;
  return '${e.message} (line ${start.line + 1}, column ${start.column + 1})';
}

/// Converts a parsed YAML value to plain Dart values.
Object? toPlain(Object? yaml) {
  if (yaml is YamlScalar) return yaml.value;
  if (yaml is Map) {
    return <String, Object?>{
      for (final MapEntry(:key, :value) in yaml.entries)
        '${toPlain(key)}': toPlain(value),
    };
  }
  if (yaml is List) return <Object?>[for (final item in yaml) toPlain(item)];
  return yaml;
}
