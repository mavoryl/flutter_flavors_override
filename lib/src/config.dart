import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'errors.dart';
import 'local_package.dart' show canonicalDir, describeYamlException, toPlain;

/// The file that declares the overrides of a project, next to its root
/// pubspec.yaml.
const configFileName = 'flavor_overrides.yaml';

/// A pub package name: lowercase letters, digits and underscores, not
/// starting with a digit.
final _packageName = RegExp(r'^[a-z_][a-z0-9_]*$');

/// The overrides a project declares in its [configFileName]: package →
/// flavor → pub dependency spec.
class OverridesConfig {
  OverridesConfig._(this.path, this.packages);

  /// Absolute path of the file; its directory is the project root.
  final String path;

  String get dir => p.dirname(path);

  /// package → flavor → spec (plain Dart; paths relative to [dir]).
  final Map<String, Map<String, Object?>> packages;

  /// Every flavor named under any package, sorted.
  List<String> get flavors =>
      {for (final flavors in packages.values) ...flavors.keys}.toList()..sort();

  /// package → spec for [flavor], packages sorted; empty when none.
  Map<String, Object?> forFlavor(String flavor) => {
        for (final name in packages.keys.toList()..sort())
          if (packages[name]!.containsKey(flavor))
            name: packages[name]![flavor],
      };

  /// Parses and validates the whole file, every package and every flavor.
  /// Throws [FlavorOverridesException] naming the file, and the place in it
  /// such as `some_plugin.prod`, when it cannot be read or is not valid
  /// YAML; when its root is not a map (an empty file is an empty config);
  /// when a package key is not a pub package name; when a package declares
  /// no flavors; when a flavor key is not a non-empty string; or when a spec
  /// is not a map, a version string or empty.
  static OverridesConfig load(String path) {
    final file = p.join(canonicalDir(p.dirname(path)), p.basename(path));
    Never fail(String problem) =>
        throw FlavorOverridesException('$file: $problem');

    final String text;
    try {
      text = File(file).readAsStringSync();
    } on FileSystemException catch (e) {
      fail('cannot be read: ${e.osError?.message ?? e.message}');
    }
    final YamlNode root;
    try {
      root = loadYamlNode(text, sourceUrl: Uri.file(file));
    } on YamlException catch (e) {
      fail('not valid YAML: ${describeYamlException(e)}');
    }

    if (root is YamlScalar && root.value == null) {
      return OverridesConfig._(file, const {});
    }
    if (root is! YamlMap) {
      fail('must be a map of package names to flavors, as in\n'
          '  some_plugin:\n'
          '    prod:\n'
          '      path: stubs/some_plugin');
    }

    final packages = <String, Map<String, Object?>>{};
    for (final MapEntry(key: keyNode, value: flavorsNode)
        in root.nodes.entries) {
      final name = (keyNode as YamlNode).value;
      if (name is! String || !_packageName.hasMatch(name)) {
        fail('`${_source(keyNode)}` is not a valid package name: lowercase '
            'letters, digits and underscores, not starting with a digit.');
      }
      if ((flavorsNode is YamlScalar && flavorsNode.value == null) ||
          (flavorsNode is YamlMap && flavorsNode.isEmpty)) {
        fail('`$name` declares no flavors: give it at least one flavor and '
            'its dependency spec, or remove it.');
      }
      if (flavorsNode is! YamlMap) {
        fail('`$name` must be a map of flavors to dependency specs.');
      }

      final flavors = <String, Object?>{};
      for (final MapEntry(key: flavorNode, value: specNode)
          in flavorsNode.nodes.entries) {
        final flavor = (flavorNode as YamlNode).value;
        final place = '$name.${_source(flavorNode)}';
        if (flavor is! String || flavor.isEmpty) {
          fail('`$place`: a flavor must be a non-empty string.');
        }
        _checkSpec(specNode, place, name, fail);
        flavors[flavor] = toPlain(specNode);
      }
      packages[name] = flavors;
    }
    return OverridesConfig._(file, packages);
  }

  /// Nearest [configFileName] in [startDir] or its ancestors, or null.
  static String? find(String startDir) {
    for (var dir = p.normalize(p.absolute(startDir));; dir = p.dirname(dir)) {
      final path = p.join(dir, configFileName);
      if (File(path).existsSync()) return path;
      if (p.dirname(dir) == dir) return null;
    }
  }
}

/// [node] as written in the file.
String _source(YamlNode node) => node.span.text;

/// The sources of a dependency spec map.
const _sources = {'path', 'git', 'hosted', 'sdk'};

/// The keys of a `git:` map and of a `hosted:` map.
const _gitKeys = {'url', 'ref', 'path', 'tag_pattern'};
const _hostedKeys = {'name', 'url'};

/// Checks the shape of the dependency spec [node] of package [name] at
/// [place] (such as `some_plugin.prod`), on the YAML nodes, calling [fail]
/// with the problem. Allowed: empty (any version from pub.dev); a non-empty
/// string (a version constraint); a map with exactly one source among
/// `path` (a string), `git` (a string, or a map with a string `url` and
/// optional string `ref`, `path`, `tag_pattern`), `hosted` (a string, or a
/// map with optional string `name`, `url`) and `sdk` (a string), plus an
/// optional string `version` beside `git`, `hosted` or `sdk`. Every key, at
/// every level, is a string. What the strings say (version syntax, URLs,
/// paths) is pub's to check.
void _checkSpec(
  YamlNode node,
  String place,
  String name,
  Never Function(String problem) fail,
) {
  _checkKeys(node, place, fail);
  if (node is YamlScalar) {
    final value = node.value;
    if (value == null || (value is String && value.isNotEmpty)) return;
  }
  if (node is! YamlMap) {
    fail('`$place` must be a dependency spec: a map such as '
        '`path: stubs/$name`, a version string, or empty.');
  }

  final keys = [for (final key in node.keys) key as String];
  for (final key in keys) {
    if (!_sources.contains(key) && key != 'version') {
      fail('`$place.$key` is not a key of a dependency spec: one of '
          '${_sources.join(', ')}, and `version` beside git, hosted or sdk.');
    }
  }
  final sources = keys.where(_sources.contains).toList();
  if (sources.length != 1) {
    fail('`$place` must name exactly one source, one of '
        '${_sources.join(', ')}${sources.isEmpty ? '' : ', not '
            '${sources.join(' and ')}'}; a version from pub.dev is a plain '
        'string.');
  }
  final source = sources.single;

  void string(YamlNode value, String at) {
    if (value.value is! String) fail('`$at` must be a string.');
  }

  /// A string, or a map of string values under the keys in [allowed].
  void stringOrMap(YamlNode value, String at, Set<String> allowed) {
    if (value is YamlScalar && value.value is String) return;
    if (value is! YamlMap) fail('`$at` must be a string or a map.');
    for (final MapEntry(:key, value: item) in value.nodes.entries) {
      final itemKey = (key as YamlNode).value as String;
      if (!allowed.contains(itemKey)) {
        fail('`$at.$itemKey` is not a key of `$source`: one of '
            '${allowed.join(', ')}.');
      }
      string(item, '$at.$itemKey');
    }
  }

  final version = node.nodes['version'];
  if (version != null) {
    if (source == 'path') {
      fail('`$place.version`: a path dependency takes no version.');
    }
    string(version, '$place.version');
  }
  final value = node.nodes[source]!;
  final at = '$place.$source';
  switch (source) {
    case 'path' || 'sdk':
      string(value, at);
    case 'git':
      stringOrMap(value, at, _gitKeys);
      if (value is YamlMap && !value.containsKey('url')) {
        fail('`$at.url` is missing: a git map needs the url of the '
            'repository.');
      }
    case 'hosted':
      stringOrMap(value, at, _hostedKeys);
  }
}

/// Every map key under [node] (at [place]) is a string, at every level.
void _checkKeys(YamlNode node, String place, Never Function(String) fail) {
  if (node is YamlMap) {
    for (final MapEntry(:key, :value) in node.nodes.entries) {
      final keyNode = key as YamlNode;
      final at = '$place.${_source(keyNode)}';
      if (keyNode.value is! String) fail('`$at`: a key must be a string.');
      _checkKeys(value, at, fail);
    }
  } else if (node is YamlList) {
    for (final (i, item) in node.nodes.indexed) {
      _checkKeys(item, '$place[$i]', fail);
    }
  }
}
