import 'package:flutter_flavor_overrides/src/paths.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('portableRelative on Windows', () {
    final windows = p.Context(style: p.Style.windows, current: r'C:\ws');

    test('same drive gives a relative path with forward slashes', () {
      expect(
        portableRelative(r'C:\ws\stubs\x',
            from: r'C:\ws\packages\feature', context: windows),
        '../../stubs/x',
      );
    });

    test('another drive keeps the absolute path, with forward slashes', () {
      expect(
        portableRelative(r'D:\stub', from: r'C:\app', context: windows),
        'D:/stub',
      );
    });

    test('a UNC share keeps the absolute path, with forward slashes', () {
      expect(
        portableRelative(r'\\server\share\stub',
            from: r'C:\app', context: windows),
        '//server/share/stub',
      );
    });

    test('the directory itself is .', () {
      expect(portableRelative(r'C:\ws', from: r'C:\ws', context: windows), '.');
    });
  });

  group('portableRelative on POSIX', () {
    final posix = p.Context(style: p.Style.posix, current: '/ws');

    test('relative path', () {
      expect(
        portableRelative('/ws/stubs/x',
            from: '/ws/packages/feature', context: posix),
        '../../stubs/x',
      );
    });

    test('a backslash is part of a file name and stays', () {
      expect(
        portableRelative(r'/ws/a\b', from: '/ws', context: posix),
        r'a\b',
      );
    });
  });

  group('rebasePath', () {
    test('Windows: a forward-slash declaration is rebased to another drive',
        () {
      final windows = p.Context(style: p.Style.windows, current: r'C:\app');
      expect(
        rebasePath('../stub',
            fromDir: r'D:\feature', toDir: r'C:\app', context: windows),
        'D:/stub',
      );
    });

    test('Windows: backslashes in a declaration are normalized', () {
      final windows = p.Context(style: p.Style.windows, current: r'C:\ws');
      expect(
        rebasePath(r'..\..\stubs\x',
            fromDir: r'C:\ws\packages\feature',
            toDir: r'C:\ws',
            context: windows),
        'stubs/x',
      );
    });
  });
}
