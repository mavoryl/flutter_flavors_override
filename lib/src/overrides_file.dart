import 'dart:math';

import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import 'errors.dart';
import 'local_package.dart' show describeYamlException;

/// Starts the comment line that lists the entries this tool owns.
const markerPrefix = '# flutter_flavor_overrides:';

/// Returns the new file text, or null when the file must not exist. Pure.
///
/// Our entries are those listed in the marker comment line. They are replaced
/// by [desired]; foreign entries, comments and other keys are kept. A foreign
/// entry for a [desired] package is an error naming [filePath]. When nothing
/// foreign is left in the YAML, [pubspecOverrides] are copied in as ours: the
/// file replaces the pubspec's `dependency_overrides` as a whole (T4).
String? mergeOverrides({
  required String? existing,
  required Map<String, Object?> desired,
  required Map<String, Object?> pubspecOverrides,
  required String filePath,
}) {
  var text = existing ?? '';
  _validate(text, filePath);
  final marker = _Marker.find(text);

  // 1. Remove our entries, each with its own lines only: yaml_edit would also
  // drop the comments that follow an entry.
  var emptiedSection = false;
  for (final name in marker?.names ?? const <String>{}) {
    final section = _section(text);
    if (section is! YamlMap || !section.containsKey(name)) continue;
    text = section.style == CollectionStyle.FLOW
        ? (YamlEditor(text)..remove(['dependency_overrides', name])).toString()
        : _cutEntry(text, section, name).text;
    emptiedSection = true;
  }

  // 2. What is left in the YAML is foreign.
  final root = loadYamlNode(text);
  final section = _section(text);
  final Set<Object?> foreign =
      section is YamlMap ? section.keys.toSet() : const {};
  final List<Object?> otherKeys = [
    if (root is YamlMap)
      for (final key in root.keys)
        if (key != 'dependency_overrides') key,
  ];
  for (final name in desired.keys) {
    if (foreign.contains(name)) {
      throw FlavorOverridesException(
        '$filePath: `$name` is already overridden there, but not by '
        'flutter_flavor_overrides. Remove that entry or the flavor_overrides '
        'declaration of `$name`.',
      );
    }
  }

  // 5. Nothing of ours to write.
  if (desired.isEmpty) {
    if (marker == null) return existing;
    if (emptiedSection && foreign.isEmpty) {
      text = _cutEmptySection(text)?.text ?? text;
    }
    text = _setMarker(text, null);
    return text.trim().isEmpty ? null : text;
  }

  // 3. No foreign entries and no other keys: this file replaces the pubspec's
  // dependency_overrides as a whole, so copy them in, as ours.
  final hasContent = foreign.isNotEmpty || otherKeys.isNotEmpty;
  final entries = _sorted({
    if (!hasContent) ...pubspecOverrides,
    ...desired,
  });

  // 4. Add ours and list them in the marker.
  if (foreign.isNotEmpty) {
    final editor = YamlEditor(text);
    for (final MapEntry(:key, :value) in entries.entries) {
      editor.update(['dependency_overrides', key], value);
    }
    text = editor.toString();
  } else {
    final cut = _cutEmptySection(text);
    final block = '${_render(entries)}\n';
    if (cut != null && cut.offset != null) {
      text = cut.text.replaceRange(cut.offset!, cut.offset, block);
    } else {
      text = cut?.text ?? text;
      if (otherKeys.isNotEmpty) {
        text = (YamlEditor(text)..update(['dependency_overrides'], entries))
            .toString();
      } else {
        text = _withoutEmptyRoot(text);
        if (text.isNotEmpty && !text.endsWith('\n')) text = '$text\n';
        text = '$text$block';
      }
    }
  }
  return _setMarker(text, '$markerPrefix ${entries.keys.join(',')}');
}

/// The marker comment line of a file.
class _Marker {
  _Marker(this.start, this.end, this.names);

  /// Offsets of the line, its line break included.
  final int start;
  final int end;

  /// Our package names listed in the marker.
  final Set<String> names;

  /// The first comment line of [text] that starts with [markerPrefix]. A line
  /// inside a scalar, such as a block scalar, is not a comment.
  static _Marker? find(String text) {
    // An empty document is a null scalar spanning its comments: skip it.
    final root = loadYamlNode(text);
    final scalars = root is YamlMap ? _scalarSpans(root).toList() : const [];
    var offset = 0;
    for (final line in text.split('\n')) {
      final trimmed = line.trimLeft();
      final hash = offset + line.length - trimmed.length;
      if (trimmed.startsWith(markerPrefix) &&
          !scalars.any((s) => s.start <= hash && hash < s.end)) {
        return _Marker(
          offset,
          min(offset + line.length + 1, text.length),
          {
            for (final name
                in trimmed.substring(markerPrefix.length).split(','))
              if (name.trim().isNotEmpty) name.trim(),
          },
        );
      }
      offset += line.length + 1;
    }
    return null;
  }
}

/// Spans of every scalar in [node], keys included.
Iterable<({int start, int end})> _scalarSpans(YamlNode node) sync* {
  if (node is YamlMap) {
    for (final MapEntry(:key, :value) in node.nodes.entries) {
      yield* _scalarSpans(key as YamlNode);
      yield* _scalarSpans(value);
    }
  } else if (node is YamlList) {
    for (final item in node.nodes) {
      yield* _scalarSpans(item);
    }
  } else {
    yield (start: node.span.start.offset, end: node.span.end.offset);
  }
}

/// Rewrites the marker line of [text] in place, removes it when [line] is
/// null, or inserts it after the leading comment lines.
String _setMarker(String text, String? line) {
  final marker = _Marker.find(text);
  final replacement = line == null ? '' : '$line\n';
  if (marker != null) {
    return text.replaceRange(marker.start, marker.end, replacement);
  }
  final offset = _afterLeadingComments(text);
  return text.replaceRange(offset, offset, replacement);
}

/// Throws unless [text] is empty or a map whose `dependency_overrides`, if
/// any, is a map.
void _validate(String text, String filePath) {
  final YamlNode root;
  try {
    root = loadYamlNode(text);
  } on YamlException catch (e) {
    throw FlavorOverridesException(
      '$filePath: not valid YAML: ${describeYamlException(e)}',
    );
  }
  if (root.value == null) return;
  if (root is! YamlMap) {
    throw FlavorOverridesException('$filePath: must be a map.');
  }
  final section = root.nodes['dependency_overrides'];
  if (section != null && section.value != null && section is! YamlMap) {
    throw FlavorOverridesException(
      '$filePath: `dependency_overrides` must be a map.',
    );
  }
}

/// The `dependency_overrides` node of [text], or null when there is none.
YamlNode? _section(String text) {
  final root = loadYamlNode(text);
  return root is YamlMap ? root.nodes['dependency_overrides'] : null;
}

/// Cuts a `dependency_overrides` section without entries out of [text].
/// Returns null when there is no such section; the offset is where it was,
/// null when the root is a flow map.
({String text, int? offset})? _cutEmptySection(String text) {
  final root = loadYamlNode(text);
  if (root is! YamlMap) return null;
  final section = root.nodes['dependency_overrides'];
  if (section == null || (section is YamlMap && section.isNotEmpty)) {
    return null;
  }
  if (root.style == CollectionStyle.FLOW) {
    final editor = YamlEditor(text)..remove(['dependency_overrides']);
    return (text: editor.toString(), offset: null);
  }
  return _cutEntry(text, root, 'dependency_overrides');
}

/// [text] without an empty flow root map, such as the `{}` yaml_edit leaves.
String _withoutEmptyRoot(String text) {
  final root = loadYamlNode(text);
  if (root is! YamlMap || root.isNotEmpty) return text;
  return text.replaceRange(root.span.start.offset, root.span.end.offset, '');
}

/// Cuts the entry [key] of the block map [map] out of [text]: the lines from
/// its key through the line where its value's content ends. Comments after
/// that line stay.
({String text, int offset}) _cutEntry(String text, YamlMap map, String key) {
  final keyNode = map.nodes.keys.cast<YamlNode>().firstWhere(
        (node) => node.value == key,
      );
  final keyOffset = keyNode.span.start.offset;
  final start = keyOffset == 0 ? 0 : text.lastIndexOf('\n', keyOffset - 1) + 1;
  final contentEnd = max(keyNode.span.end.offset, _contentEnd(map.nodes[key]!));
  final lineEnd = text.indexOf('\n', max(contentEnd - 1, start));
  final end = lineEnd == -1 ? text.length : lineEnd + 1;
  return (text: text.replaceRange(start, end, ''), offset: start);
}

/// Where the content of [node] ends. The span of a block collection runs on
/// over the comments after it; its last scalar does not.
int _contentEnd(YamlNode node) {
  final children = switch (node) {
    YamlMap(style: CollectionStyle.BLOCK) => [
        for (final MapEntry(:key, :value) in node.nodes.entries) ...[
          key as YamlNode,
          value,
        ],
      ],
    YamlList(style: CollectionStyle.BLOCK) => node.nodes,
    _ => const <YamlNode>[],
  };
  return children.fold(
    children.isEmpty ? node.span.end.offset : node.span.start.offset,
    (end, child) => max(end, _contentEnd(child)),
  );
}

/// Offset of the first line of [text] after its leading comment lines.
int _afterLeadingComments(String text) {
  var offset = 0;
  while (offset < text.length) {
    final end = text.indexOf('\n', offset);
    final line = text.substring(offset, end == -1 ? text.length : end);
    if (!line.trimLeft().startsWith('#')) break;
    offset = end == -1 ? text.length : end + 1;
  }
  return offset;
}

Map<String, Object?> _sorted(Map<String, Object?> entries) =>
    {for (final name in entries.keys.toList()..sort()) name: entries[name]};

/// `dependency_overrides:` with [entries] in block style, no final newline.
String _render(Map<String, Object?> entries) =>
    (YamlEditor('')..update([], {'dependency_overrides': entries})).toString();
