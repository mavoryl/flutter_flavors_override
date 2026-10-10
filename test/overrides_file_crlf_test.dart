import 'package:flutter_flavor_overrides/src/overrides_file.dart';
import 'package:test/test.dart';

String crlf(String text) => text.replaceAll('\n', '\r\n');

void main() {
  group('a file saved with CRLF line endings', () {
    final melos = crlf('# melos_managed_dependency_overrides: core\n'
        'dependency_overrides:\n'
        '  core:\n'
        '    path: ../core\n');
    const desired = <String, Object?>{
      'ffo_probe': {'path': '../stubs/ffo_probe'},
    };

    String? merge(String? existing, Map<String, Object?> want) =>
        mergeOverrides(
          existing: existing,
          desired: want,
          pubspecOverrides: const {},
          filePath: '/app/pubspec_overrides.yaml',
        );

    test('gets our entries with CRLF too', () {
      final out = merge(melos, desired)!;
      expect(out, contains('# flutter_flavor_overrides: ffo_probe\r\n'));
      expect(out, contains('  ffo_probe:\r\n    path: ../stubs/ffo_probe\r\n'));
      expect(out, contains('  core:\r\n    path: ../core\r\n'));
      expect(out.replaceAll('\r\n', ''), isNot(contains('\n')));
      expect(
          out.startsWith('# melos_managed_dependency_overrides: core'), isTrue);
    });

    test('is restored byte for byte when our entries are removed', () {
      final prod = merge(melos, desired);
      expect(merge(prod, const {}), melos);
    });

    test('is stable on a re-run', () {
      final prod = merge(melos, desired);
      expect(merge(prod, desired), prod);
    });

    test('a melos entry for a desired package is taken over', () {
      final linked =
          crlf('# melos_managed_dependency_overrides: core,ffo_probe\n'
              'dependency_overrides:\n'
              '  core:\n'
              '    path: ../core\n'
              '  ffo_probe:\n'
              '    path: ../packages/ffo_probe\n');

      final out = merge(linked, desired);

      expect(
        out,
        crlf('# melos_managed_dependency_overrides: core\n'
            '# flutter_flavor_overrides: ffo_probe\n'
            'dependency_overrides:\n'
            '  core:\n'
            '    path: ../core\n'
            '  ffo_probe:\n'
            '    path: ../stubs/ffo_probe\n'),
      );
      expect(merge(out, desired), out);
      expect(merge(out, const {}), melos);
    });
  });
}
