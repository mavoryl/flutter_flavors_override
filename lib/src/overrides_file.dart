import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import 'errors.dart';
import 'local_package.dart' show describeYamlException;

/// Starts the comment line that lists the entries this tool owns.
const markerPrefix = '# flutter_flavor_overrides:';

/// Returns the new file text, or null when the file must not exist. Pure.
///
/// Our entries are those listed in the marker line. They are replaced by
/// [desired]; foreign entries, comments and other keys are kept. A foreign
/// entry for a [desired] package is an error naming [filePath]. When no YAML
/// content is left besides ours, [pubspecOverrides] are copied in as ours: the
/// file replaces the pubspec's `dependency_overrides` as a whole.
String? mergeOverrides({
  required String? existing,
  required Map<String, Object?> desired,
  required Map<String, Object?> pubspecOverrides,
  required String filePath,
}) {
  final text = existing ?? '';
  // The marker line is cut out before editing: yaml_edit drops comments that
  // trail a removed entry. It goes back where it was, see [_Marker.shift].
  final marker = _Marker.find(text);
  final editor = _parse(marker?.textWithout ?? text, filePath);

  // 1. Remove our entries; an emptied `dependency_overrides` goes too.
  var removed = marker != null;
  final own = marker?.names ?? const <String>{};
  final overrides = _overrides(editor);
  if (overrides != null) {
    final ours = [
      for (final name in overrides.keys)
        if (own.contains(name)) name as String,
    ];
    if (ours.isNotEmpty) {
      removed = true;
      if (ours.length == overrides.length) {
        editor.remove(['dependency_overrides']);
      } else {
        for (final name in ours) {
          editor.remove(['dependency_overrides', name]);
        }
      }
    }
  }
  final root = editor.parseAt([]);
  final hasContent = root is YamlMap && root.isNotEmpty;

  // 2. Whatever is left is foreign: it must not override what we override.
  final foreign = _overrides(editor);
  for (final name in desired.keys) {
    if (foreign != null && foreign.containsKey(name)) {
      throw FlavorOverridesException(
        '$filePath: `$name` is already overridden there, but not by '
        'flutter_flavor_overrides. Remove that entry or the flavor_overrides '
        'declaration of `$name`.',
      );
    }
  }

  // 5. Nothing of ours to write.
  if (desired.isEmpty) {
    if (!removed) return existing;
    if (!hasContent) return null;
    return editor.toString();
  }

  // 3. With no content left, this file replaces the pubspec's
  // dependency_overrides as a whole (T4): copy them in, as ours.
  final entries = _sorted({
    if (!hasContent) ...pubspecOverrides,
    ...desired,
  });
  final markerLine = '$markerPrefix ${entries.keys.join(',')}';

  // 4. Add ours and list them in the marker.
  if (!hasContent) {
    // Nothing but comments is left: rebuild the file around them.
    final comments = [
      for (final line in text.split('\n'))
        if (_isComment(line) && !_isMarker(line)) line,
    ];
    comments.insert(marker?.commentIndex ?? comments.length, markerLine);
    return '${[...comments, _render(entries)].join('\n')}\n';
  }
  if (_overrides(editor) == null) {
    editor.update(['dependency_overrides'], entries);
  } else {
    for (final MapEntry(:key, :value) in entries.entries) {
      editor.update(['dependency_overrides', key], value);
    }
  }
  final result = editor.toString();
  final offset = marker?.shift(editor.edits) ?? _afterLeadingComments(result);
  return result.replaceRange(offset, offset, '$markerLine\n');
}

/// The marker line of a file and where it was.
class _Marker {
  _Marker._(this.names, this.textWithout, this.offset, this.commentIndex,
      {required this.trailsContent});

  /// Our package names listed in the marker.
  final Set<String> names;

  /// The file text with the marker line cut out.
  final String textWithout;

  /// Offset in [textWithout] where the marker line was.
  final int offset;

  /// How many comment lines precede the marker.
  final int commentIndex;

  /// Whether YAML content precedes the marker; it then stays after content
  /// inserted at its offset, otherwise before.
  final bool trailsContent;

  static _Marker? find(String text) {
    final lines = text.split('\n');
    final index = lines.indexWhere(_isMarker);
    if (index == -1) return null;
    final before = lines.take(index);
    final offset = before.fold(0, (sum, line) => sum + line.length + 1);
    final end = offset + lines[index].length + 1;
    return _Marker._(
      {
        for (final name in lines[index]
            .trimLeft()
            .substring(markerPrefix.length)
            .split(','))
          if (name.trim().isNotEmpty) name.trim(),
      },
      text.replaceRange(offset, end > text.length ? text.length : end, ''),
      offset,
      before.where(_isComment).length,
      trailsContent:
          before.any((line) => line.trim().isNotEmpty && !_isComment(line)),
    );
  }

  /// [offset] carried through [edits] applied one after another to
  /// [textWithout].
  int shift(List<SourceEdit> edits) {
    var position = offset;
    for (final edit in edits) {
      final end = edit.offset + edit.length;
      final delta = edit.replacement.length - edit.length;
      if (edit.offset == position) {
        if (edit.length == 0 && trailsContent) position += delta;
      } else if (end <= position) {
        position += delta;
      } else if (edit.offset < position) {
        position = edit.offset + edit.replacement.length;
      }
    }
    return position;
  }
}

/// An editor for [text], which must be empty or a map whose
/// `dependency_overrides`, if any, is a map.
YamlEditor _parse(String text, String filePath) {
  final YamlEditor editor;
  try {
    editor = YamlEditor(text);
  } on YamlException catch (e) {
    throw FlavorOverridesException(
      '$filePath: not valid YAML: ${describeYamlException(e)}',
    );
  }
  final root = editor.parseAt([]);
  if (root.value == null) return editor;
  if (root is! YamlMap) {
    throw FlavorOverridesException('$filePath: must be a map.');
  }
  final overrides = root.nodes['dependency_overrides'];
  if (overrides != null && overrides.value != null && overrides is! YamlMap) {
    throw FlavorOverridesException(
      '$filePath: `dependency_overrides` must be a map.',
    );
  }
  return editor;
}

bool _isComment(String line) => line.trimLeft().startsWith('#');

bool _isMarker(String line) => line.trimLeft().startsWith(markerPrefix);

/// Offset of the first line of [text] after its leading comment lines.
int _afterLeadingComments(String text) {
  var offset = 0;
  while (offset < text.length) {
    final end = text.indexOf('\n', offset);
    final line = text.substring(offset, end == -1 ? text.length : end);
    if (!_isComment(line)) break;
    offset = end == -1 ? text.length : end + 1;
  }
  return offset;
}

/// The `dependency_overrides` map, or null when there is none.
YamlMap? _overrides(YamlEditor editor) {
  final root = editor.parseAt([]);
  if (root is! YamlMap) return null;
  final overrides = root.nodes['dependency_overrides'];
  return overrides is YamlMap ? overrides : null;
}

Map<String, Object?> _sorted(Map<String, Object?> entries) =>
    {for (final name in entries.keys.toList()..sort()) name: entries[name]};

/// `dependency_overrides:` with [entries] in block style, no final newline.
String _render(Map<String, Object?> entries) =>
    (YamlEditor('')..update([], {'dependency_overrides': entries})).toString();
