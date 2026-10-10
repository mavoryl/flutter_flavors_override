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
/// entry for a [desired] package is an error naming [filePath], unless melos 6
/// owns it: listed in the melos marker line, it is taken over. Its name
/// leaves that marker and the entry becomes ours, so removing ours removes it
/// too, and the next `melos bootstrap` links the package again. With
/// [desired] entries, [pubspecOverrides] are copied in as ours, but for
/// packages a foreign entry overrides: pub ignores the pubspec's
/// `dependency_overrides` once the file has the key (T4).
/// A file without a final line break keeps having none, so that removing our
/// entries gives back its text byte for byte.
///
/// A file saved with CRLF line endings (Windows editors) is merged as LF and
/// handed back with CRLF.
String? mergeOverrides({
  required String? existing,
  required Map<String, Object?> desired,
  required Map<String, Object?> pubspecOverrides,
  required String filePath,
}) {
  final crlf = existing != null && existing.contains('\r\n');
  final merged = _mergeLf(
    existing: crlf ? existing.replaceAll('\r\n', '\n') : existing,
    desired: desired,
    pubspecOverrides: pubspecOverrides,
    filePath: filePath,
  );
  return crlf ? merged?.replaceAll('\n', '\r\n') : merged;
}

String? _mergeLf({
  required String? existing,
  required Map<String, Object?> desired,
  required Map<String, Object?> pubspecOverrides,
  required String filePath,
}) {
  if (existing != null) _validate(existing, filePath);
  var text = existing ?? '';
  final marker = _Marker.find(text);
  final melosNames = _melosNames(text);
  final takenOver = desired.keys.where(melosNames.contains).toSet();

  // 1. Remove our entries and the melos entries we take over, each with its
  // own lines only: yaml_edit would also drop the comments that follow an
  // entry. Our marker in those lines goes with them and is written anew; the
  // melos marker moves out first.
  final cut = {...?marker?.names, ...takenOver};
  text = _melosMarkerOutside(text, cut);
  var emptiedSection = false;
  for (final name in cut) {
    final section = _section(text);
    if (section is! YamlMap || !section.containsKey(name)) continue;
    text = section.style == CollectionStyle.FLOW
        ? (YamlEditor(text)..remove(['dependency_overrides', name])).toString()
        : _cutEntry(text, section, name).text;
    emptiedSection = true;
  }
  if (takenOver.isNotEmpty) {
    text = _setMelosNames(text, [
      for (final name in melosNames)
        if (!takenOver.contains(name)) name,
    ]);
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
        'flutter_flavor_overrides. Remove that entry, or `$name` from '
        'flavor_overrides.yaml.',
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
    return text.trim().isEmpty ? null : _endLike(existing, text);
  }

  // 3. With our entries, this file has `dependency_overrides`, so pub ignores
  // the pubspec's: copy them in, as ours, except those it overrides itself.
  final entries = _sorted({
    for (final MapEntry(:key, :value) in pubspecOverrides.entries)
      if (!foreign.contains(key)) key: value,
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
  return _endLike(
    existing,
    _setMarker(text, '$markerPrefix ${entries.keys.join(',')}'),
  );
}

/// [text] without its final line break when [existing] has text but no final
/// line break. Ours then end the file without one, and cutting them leaves
/// the line break before them, which this takes away again.
String _endLike(String? existing, String text) {
  if (existing == null ||
      existing.isEmpty ||
      existing.endsWith('\n') ||
      !text.endsWith('\n')) {
    return text;
  }
  return text.substring(0, text.length - 1);
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

/// The marker line of melos 6, which lists the entries `melos bootstrap`
/// owns. Read and rewritten like melos 6.3.3 does
/// (`lib/src/commands/bootstrap.dart`, `mergeMelosPubspecOverrides`): any line
/// at column 0, the first one counts.
final _melosMarker = RegExp(
  '^# melos_managed_dependency_overrides: (.*)\n',
  multiLine: true,
);

/// The package names the melos marker of [text] lists, in order. Like melos,
/// split at commas, not trimmed: ` b` in `a, b` is not `b`.
Set<String> _melosNames(String text) =>
    _melosMarker.firstMatch(text)?.group(1)!.split(',').toSet() ?? {};

/// [text] with the melos marker moved to the first line, where melos writes
/// it, when it lies in the lines of an entry of [names], which are to be cut.
String _melosMarkerOutside(String text, Set<String> names) {
  final marker = _melosMarker.firstMatch(text);
  final section = _section(text);
  if (marker == null || section is! YamlMap) return text;
  final inside = names.any((name) {
    if (!section.containsKey(name)) return false;
    final (:start, :end) = _entryLines(text, section, name);
    return start <= marker.start && marker.start < end;
  });
  if (!inside) return text;
  return '${marker[0]}${text.replaceRange(marker.start, marker.end, '')}';
}

/// [text] with the melos marker listing [names], like melos rewrites it:
/// without names, every marker line goes.
String _setMelosNames(String text, List<String> names) => names.isEmpty
    ? text.replaceAll(_melosMarker, '')
    : text.replaceFirstMapped(
        _melosMarker,
        (_) => '# melos_managed_dependency_overrides: ${names.join(',')}\n',
      );

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
/// any, is a map. Also throws on YAML that is valid but that the line-based
/// editing here would corrupt.
void _validate(String text, String filePath) {
  final List<YamlDocument> documents;
  try {
    documents = loadYamlDocuments(text);
  } on YamlException catch (e) {
    throw FlavorOverridesException(
      '$filePath: not valid YAML: ${describeYamlException(e)}',
    );
  }
  if (documents.length > 1) {
    throw FlavorOverridesException(
      '$filePath: more than one YAML document is not supported. Keep a single '
      'document.',
    );
  }
  if (_documentEnd.hasMatch(text)) {
    throw FlavorOverridesException(
      '$filePath: the document end marker `...` is not supported. Remove it.',
    );
  }
  final root = documents.firstOrNull?.contents;
  if (root == null || root.value == null) return;
  if (root is! YamlMap) {
    throw FlavorOverridesException('$filePath: must be a map.');
  }
  if (_hasAnchorOrAlias(root)) {
    throw FlavorOverridesException(
      '$filePath: YAML anchors and aliases (`&name`, `*name`) are not '
      'supported. Write the values out instead.',
    );
  }
  if (_isIndented(text, root)) {
    throw FlavorOverridesException(
      '$filePath: an indented top-level map is not supported. Start its keys '
      'at column 0.',
    );
  }
  final section = root.nodes['dependency_overrides'];
  if (section != null && section.value != null && section is! YamlMap) {
    throw FlavorOverridesException(
      '$filePath: `dependency_overrides` must be a map.',
    );
  }
}

/// A document end marker line. At column 0 and followed by a blank, `...`
/// ends the document in any context, so in YAML that loads it is nothing
/// else. Matched in the text: comments and `...` alone load as no document.
final _documentEnd = RegExp(r'^\.\.\.(?=[ \t\r]|$)', multiLine: true);

/// Whether a node of [root] has an anchor or is an alias. An anchor is a node
/// property, so the node's span starts with it, after a tag if any: no scalar
/// starts with `&` or `!`. An alias is the anchored node itself, met again.
bool _hasAnchorOrAlias(YamlNode root) {
  final seen = Set<YamlNode>.identity();
  bool visit(YamlNode node) =>
      !seen.add(node) ||
      _anchorProperty.hasMatch(node.span.text) ||
      switch (node) {
        YamlMap() => node.nodes.entries
            .any((entry) => visit(entry.key as YamlNode) || visit(entry.value)),
        YamlList() => node.nodes.any(visit),
        _ => false,
      };
  return visit(root);
}

/// An anchor at the start of a node, after an optional tag.
final _anchorProperty = RegExp(r'^(!\S*\s+)?&');

/// Whether the keys of the block map [root] are indented. They share the
/// indentation of the line of the first key, where a `?` may precede it.
bool _isIndented(String text, YamlMap root) {
  if (root.style != CollectionStyle.BLOCK || root.isEmpty) return false;
  final key = (root.nodes.keys.first as YamlNode).span.start;
  return text.startsWith(' ', key.offset - key.column);
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

/// Cuts the entry [key] of the block map [map] out of [text]: its
/// [_entryLines]. Comments after them stay.
({String text, int offset}) _cutEntry(String text, YamlMap map, String key) {
  final (:start, :end) = _entryLines(text, map, key);
  return (text: text.replaceRange(start, end, ''), offset: start);
}

/// Offsets of the lines of the entry [key] of [map] in [text]: from its key
/// through the line where its value's content ends, line break included.
({int start, int end}) _entryLines(String text, YamlMap map, String key) {
  final keyNode = map.nodes.keys.cast<YamlNode>().firstWhere(
        (node) => node.value == key,
      );
  final keyOffset = keyNode.span.start.offset;
  final start = keyOffset == 0 ? 0 : text.lastIndexOf('\n', keyOffset - 1) + 1;
  final contentEnd = max(keyNode.span.end.offset, _contentEnd(map.nodes[key]!));
  final lineEnd = text.indexOf('\n', max(contentEnd - 1, start));
  return (start: start, end: lineEnd == -1 ? text.length : lineEnd + 1);
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
