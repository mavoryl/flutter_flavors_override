import 'dart:io';

import 'package:path/path.dart' as p;

/// A throwaway project tree in the system temp directory.
///
/// Create it in `setUp`, call [delete] in `tearDown`.
class ProjectBuilder {
  ProjectBuilder()
      : root = Directory.systemTemp
            .createTempSync('flutter_flavor_overrides_test_')
            .resolveSymbolicLinksSync();

  /// Absolute directory of the tree, with symbolic links resolved.
  final String root;

  /// Absolute, normalized path of [relative] (posix separators allowed).
  String path(String relative) => p.normalize(p.join(root, relative));

  /// Writes `<relativeDir>/pubspec.yaml` and returns the package directory.
  String pubspec(String relativeDir, String content) {
    file(p.join(relativeDir, 'pubspec.yaml'), content);
    return path(relativeDir);
  }

  /// Writes [content] to [relativePath], creating parent directories.
  String file(String relativePath, String content) {
    final target = File(path(relativePath));
    target.parent.createSync(recursive: true);
    target.writeAsStringSync(content);
    return target.path;
  }

  /// Creates an empty directory.
  String dir(String relativeDir) {
    Directory(path(relativeDir)).createSync(recursive: true);
    return path(relativeDir);
  }

  void delete() => Directory(root).deleteSync(recursive: true);
}
