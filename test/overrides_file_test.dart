import 'package:flutter_flavor_overrides/src/errors.dart';
import 'package:flutter_flavor_overrides/src/overrides_file.dart';
import 'package:test/test.dart';

const filePath = '/project/app/pubspec_overrides.yaml';

const probe = {
  'ffo_probe': {'path': '../stubs/ffo_probe'},
};

/// The plan's reference output for [probe].
const probeFile = '# flutter_flavor_overrides: ffo_probe\n'
    'dependency_overrides:\n'
    '  ffo_probe:\n'
    '    path: ../stubs/ffo_probe\n';

String? merge(
  String? existing,
  Map<String, Object?> desired, {
  Map<String, Object?> pubspecOverrides = const {},
}) =>
    mergeOverrides(
      existing: existing,
      desired: desired,
      pubspecOverrides: pubspecOverrides,
      filePath: filePath,
    );

void main() {
  group('a new file', () {
    test('is exactly the reference file', () {
      expect(merge(null, probe), probeFile);
    });

    test('lists several packages sorted by name, any spec', () {
      expect(
        merge(null, {
          'zeta': '^1.0.0',
          'alpha': {
            'git': {'url': 'https://example.com/alpha.git', 'ref': 'main'},
          },
          'mid': null,
        }),
        '# flutter_flavor_overrides: alpha,mid,zeta\n'
        'dependency_overrides:\n'
        '  alpha:\n'
        '    git:\n'
        '      url: https://example.com/alpha.git\n'
        '      ref: main\n'
        '  mid: null\n'
        '  zeta: ^1.0.0\n',
      );
    });

    test('is not created without desired entries', () {
      expect(merge(null, {}), isNull);
    });
  });

  group('our own file', () {
    test('a re-run with the same entries changes nothing', () {
      expect(merge(probeFile, probe), probeFile);
    });

    test('another flavor replaces our entries', () {
      expect(
        merge(probeFile, {'other': '2.0.0'}),
        '# flutter_flavor_overrides: other\n'
        'dependency_overrides:\n'
        '  other: 2.0.0\n',
      );
    });

    test('is deleted when nothing is desired', () {
      expect(merge(probeFile, {}), isNull);
    });
  });

  group('without our entries and nothing desired', () {
    test('a foreign file is returned as is', () {
      const foreign = '# hand-written\n'
          'dependency_overrides:\n'
          '  other: {path: ../other}\n';
      expect(merge(foreign, {}), same(foreign));
    });

    test('an empty file is returned as is', () {
      expect(merge('', {}), '');
    });
  });

  group('a melos 6 file', () {
    const melosFile = '# melos_managed_dependency_overrides: core,feature\n'
        '# linked by melos bootstrap\n'
        'dependency_overrides:\n'
        '  core:\n'
        '    path: ../core\n'
        '  # the feature module\n'
        '  feature:\n'
        '    path: ../packages/feature\n';

    const withProbe = '# melos_managed_dependency_overrides: core,feature\n'
        '# linked by melos bootstrap\n'
        '# flutter_flavor_overrides: ffo_probe\n'
        'dependency_overrides:\n'
        '  core:\n'
        '    path: ../core\n'
        '  # the feature module\n'
        '  feature:\n'
        '    path: ../packages/feature\n'
        '  ffo_probe:\n'
        '    path: ../stubs/ffo_probe\n';

    test('gets our entry and our marker after its leading comments', () {
      expect(merge(melosFile, probe), withProbe);
    });

    test('a re-run changes nothing', () {
      expect(merge(withProbe, probe), withProbe);
    });

    test('another flavor rewrites our marker in place', () {
      expect(
        merge(withProbe, {'a_plugin': '1.0.0'}),
        '# melos_managed_dependency_overrides: core,feature\n'
        '# linked by melos bootstrap\n'
        '# flutter_flavor_overrides: a_plugin\n'
        'dependency_overrides:\n'
        '  a_plugin: 1.0.0\n'
        '  core:\n'
        '    path: ../core\n'
        '  # the feature module\n'
        '  feature:\n'
        '    path: ../packages/feature\n',
      );
    });

    test('removing ours restores the melos file byte for byte', () {
      expect(merge(withProbe, {}), melosFile);
      expect(merge(merge(withProbe, {'a_plugin': '1.0.0'}), {}), melosFile);
    });

    test('melos merged into our file: removing ours keeps melos entries', () {
      const merged = '# melos_managed_dependency_overrides: core\n'
          '# flutter_flavor_overrides: ffo_probe\n'
          'dependency_overrides:\n'
          '  core:\n'
          '    path: ../core\n'
          '  ffo_probe:\n'
          '    path: ../stubs/ffo_probe\n';

      expect(merge(merged, probe), merged);
      expect(
        merge(merged, {}),
        '# melos_managed_dependency_overrides: core\n'
        'dependency_overrides:\n'
        '  core:\n'
        '    path: ../core\n',
      );
    });
  });

  group("the pubspec's dependency_overrides", () {
    const pubspecOverrides = {
      'other': {'path': '../vendor/other'},
    };
    const probeWithOther = '# flutter_flavor_overrides: ffo_probe,other\n'
        'dependency_overrides:\n'
        '  ffo_probe:\n'
        '    path: ../stubs/ffo_probe\n'
        '  other:\n'
        '    path: ../vendor/other\n';

    test('are copied into a new file and marked as ours', () {
      expect(
        merge(null, probe, pubspecOverrides: pubspecOverrides),
        probeWithOther,
      );
    });

    test('are copied again on a re-run over our own file', () {
      expect(
        merge(probeWithOther, probe, pubspecOverrides: pubspecOverrides),
        probeWithOther,
      );
      expect(
        merge(probeFile, probe, pubspecOverrides: pubspecOverrides),
        probeWithOther,
      );
    });

    test('are copied into a file with only comments, which stay', () {
      expect(
        merge('# local notes\n', probe, pubspecOverrides: pubspecOverrides),
        '# local notes\n$probeWithOther',
      );
    });

    test('lose to a desired entry for the same package', () {
      expect(
        merge(null, probe, pubspecOverrides: {
          'ffo_probe': '1.0.0',
          ...pubspecOverrides,
        }),
        probeWithOther,
      );
    });

    test('are not copied next to foreign entries', () {
      const foreign = 'dependency_overrides:\n'
          '  core:\n'
          '    path: ../core\n';

      expect(
        merge(foreign, probe, pubspecOverrides: pubspecOverrides),
        '# flutter_flavor_overrides: ffo_probe\n'
        'dependency_overrides:\n'
        '  core:\n'
        '    path: ../core\n'
        '  ffo_probe:\n'
        '    path: ../stubs/ffo_probe\n',
      );
    });

    test('are not copied when nothing is desired', () {
      expect(merge(null, {}, pubspecOverrides: pubspecOverrides), isNull);
      expect(merge(probeWithOther, {}, pubspecOverrides: pubspecOverrides),
          isNull);
    });
  });

  group('foreign content', () {
    test('other top-level keys and comments are kept', () {
      const foreign = '# keep me\n'
          'dependency_overrides:\n'
          '  core:\n'
          '    path: ../core\n'
          'other_key: 1\n';
      const withProbe = '# keep me\n'
          '# flutter_flavor_overrides: ffo_probe\n'
          'dependency_overrides:\n'
          '  core:\n'
          '    path: ../core\n'
          '  ffo_probe:\n'
          '    path: ../stubs/ffo_probe\n'
          'other_key: 1\n';

      expect(merge(foreign, probe), withProbe);
      expect(merge(withProbe, probe), withProbe);
      expect(merge(withProbe, {}), foreign);
    });

    test('a file without dependency_overrides gets the section', () {
      const foreign = 'other_key: 1\n';
      const withProbe = '# flutter_flavor_overrides: ffo_probe\n'
          'dependency_overrides:\n'
          '  ffo_probe:\n'
          '    path: ../stubs/ffo_probe\n'
          'other_key: 1\n';

      expect(merge(foreign, probe), withProbe);
      expect(merge(withProbe, probe), withProbe);
      expect(merge(withProbe, {}), foreign);
    });

    test('the marker is found on any line and rewritten there', () {
      const markerLast = 'dependency_overrides:\n'
          '  core:\n'
          '    path: ../core\n'
          '  ffo_probe:\n'
          '    path: ../stubs/ffo_probe\n'
          '# flutter_flavor_overrides: ffo_probe\n';

      expect(merge(markerLast, probe), markerLast);
      expect(
        merge(markerLast, {'a_plugin': '1.0.0'}),
        'dependency_overrides:\n'
        '  a_plugin: 1.0.0\n'
        '  core:\n'
        '    path: ../core\n'
        '# flutter_flavor_overrides: a_plugin\n',
      );
      expect(
        merge(markerLast, {}),
        'dependency_overrides:\n'
        '  core:\n'
        '    path: ../core\n',
      );
    });

    test('a leading document start marker stays where it is', () {
      const otherKey = '---\n'
          'other_key: 1\n';
      const otherKeyWithProbe = '# flutter_flavor_overrides: ffo_probe\n'
          '---\n'
          'dependency_overrides:\n'
          '  ffo_probe:\n'
          '    path: ../stubs/ffo_probe\n'
          'other_key: 1\n';
      const foreignEntry = '---\n'
          'dependency_overrides:\n'
          '  core: 1.0.0\n';
      const foreignEntryWithProbe = '# flutter_flavor_overrides: ffo_probe\n'
          '---\n'
          'dependency_overrides:\n'
          '  core: 1.0.0\n'
          '  ffo_probe:\n'
          '    path: ../stubs/ffo_probe\n';

      expect(merge(otherKey, probe), otherKeyWithProbe);
      expect(merge(otherKeyWithProbe, probe), otherKeyWithProbe);
      expect(merge(otherKeyWithProbe, {}), otherKey);
      expect(merge(foreignEntry, probe), foreignEntryWithProbe);
      expect(merge(foreignEntryWithProbe, probe), foreignEntryWithProbe);
      expect(merge(foreignEntryWithProbe, {}), foreignEntry);
    });

    test('& and * in a quoted string or a plain scalar are no anchors', () {
      const foreign = 'notes: "&x *y"\n'
          'other_key: a*b\n';
      const withProbe = '# flutter_flavor_overrides: ffo_probe\n'
          'dependency_overrides:\n'
          '  ffo_probe:\n'
          '    path: ../stubs/ffo_probe\n'
          'notes: "&x *y"\n'
          'other_key: a*b\n';

      expect(merge(foreign, probe), withProbe);
      expect(merge(withProbe, probe), withProbe);
      expect(merge(withProbe, {}), foreign);
    });

    test('a marker with spaces after commas is read', () {
      const spaced = '# flutter_flavor_overrides: ffo_probe, other\n'
          'dependency_overrides:\n'
          '  core: 1.0.0\n'
          '  ffo_probe:\n'
          '    path: ../stubs/ffo_probe\n'
          '  other: 2.0.0\n';

      expect(
        merge(spaced, probe),
        '# flutter_flavor_overrides: ffo_probe\n'
        'dependency_overrides:\n'
        '  core: 1.0.0\n'
        '  ffo_probe:\n'
        '    path: ../stubs/ffo_probe\n',
      );
    });
  });

  group('only a comment line is a marker', () {
    const scalarMarker = 'notes: |\n'
        '  # flutter_flavor_overrides: core\n'
        'dependency_overrides:\n'
        '  core:\n'
        '    path: ../core\n';

    test('a marker-like line in a block scalar owns nothing', () {
      expect(merge(scalarMarker, {}), same(scalarMarker));
    });

    test('so a desired package there is a foreign conflict', () {
      expect(
        () => merge(scalarMarker, {'core': '1.0.0'}),
        throwsA(isA<FlavorOverridesException>()),
      );
    });
  });

  group('foreign comments survive', () {
    test('a comment-only file comes back byte for byte', () {
      const commented = '# dependency_overrides:\n'
          '#   foo:\n'
          '#     path: ../foo\n';
      const withProbe = '$commented$probeFile';

      expect(merge(commented, probe), withProbe);
      expect(merge(withProbe, probe), withProbe);
      expect(merge(withProbe, {}), commented);
    });

    test('a comment after the foreign entries, ours inserted before it', () {
      const foreign = 'dependency_overrides:\n'
          '  core:\n'
          '    path: ../core\n'
          '# trailing note\n';
      const withProbe = '# flutter_flavor_overrides: ffo_probe\n'
          'dependency_overrides:\n'
          '  core:\n'
          '    path: ../core\n'
          '  ffo_probe:\n'
          '    path: ../stubs/ffo_probe\n'
          '# trailing note\n';

      expect(merge(foreign, probe), withProbe);
      expect(merge(withProbe, probe), withProbe);
      expect(merge(withProbe, {}), foreign);
    });

    test('a comment added after our entries in our file', () {
      const annotated = '$probeFile# my note\n';

      expect(merge(annotated, probe), annotated);
      expect(merge(annotated, {}), '# my note\n');
    });

    test('a comment between foreign entries and ours', () {
      const foreign = 'dependency_overrides:\n'
          '  core:\n'
          '    path: ../core\n'
          '  # zz: commented out\n'
          '  zz: 1.0.0\n';

      final added = merge(foreign, {'other': '2.0.0'});
      expect(added, contains('  # zz: commented out\n'));
      expect(merge(added, {'other': '2.0.0'}), added);
      expect(merge(added, {}), foreign);
    });
  });

  group('a file without a final newline', () {
    const files = {
      'foreign entries': 'dependency_overrides:\n'
          '  core:\n'
          '    path: ../core',
      'a melos 6 file': '# melos_managed_dependency_overrides: core\n'
          'dependency_overrides:\n'
          '  core:\n'
          '    path: ../core',
      'a comment only': '# dependency_overrides:',
      'another top-level key': 'other_key: 1',
      'a trailing comment': 'dependency_overrides:\n'
          '  core: 1.0.0\n'
          '# trailing note',
      'a flow section': 'dependency_overrides: {core: {path: ../core}}',
    };

    files.forEach((name, original) {
      test('$name: comes back byte for byte when ours are removed', () {
        final added = merge(original, probe)!;
        expect(added, contains('ffo_probe'));
        expect(merge(added, probe), added);
        expect(merge(added, {}), original);

        final replaced = merge(added, {'other': '2.0.0'})!;
        expect(replaced, isNot(contains('ffo_probe')));
        expect(merge(replaced, {}), original);
      });
    });

    test('adding ours puts a line break before them', () {
      expect(
        merge('# note', probe),
        '# note\n'
        '# flutter_flavor_overrides: ffo_probe\n'
        'dependency_overrides:\n'
        '  ffo_probe:\n'
        '    path: ../stubs/ffo_probe',
      );
    });
  });

  group('an empty dependency_overrides section', () {
    test('is no content: the pubspec overrides are copied, block style', () {
      const empty = 'dependency_overrides: {}\n';
      const expected = '# flutter_flavor_overrides: ffo_probe,other\n'
          'dependency_overrides:\n'
          '  ffo_probe:\n'
          '    path: ../stubs/ffo_probe\n'
          '  other: 1.0.0\n';

      final first = merge(empty, probe, pubspecOverrides: {'other': '1.0.0'});
      expect(first, expected);
      expect(merge(first, probe, pubspecOverrides: {'other': '1.0.0'}), first);
    });

    test('a flow section with foreign entries stays flow and comes back', () {
      const flow = 'dependency_overrides: {core: {path: ../core}}\n';

      final added = merge(flow, probe);
      expect(added, startsWith('# flutter_flavor_overrides: ffo_probe\n'));
      expect(added, contains('ffo_probe'));
      expect(merge(added, probe), added);
      expect(merge(added, {}), flow);
    });
  });

  group('errors name the file', () {
    Matcher throwsAbout(String detail) => throwsA(
          isA<FlavorOverridesException>().having(
            (e) => e.message,
            'message',
            allOf(contains(filePath), contains(detail)),
          ),
        );

    test('a foreign entry for a desired package', () {
      const foreign = '# melos_managed_dependency_overrides: ffo_probe\n'
          'dependency_overrides:\n'
          '  ffo_probe:\n'
          '    path: ../packages/ffo_probe\n';

      expect(() => merge(foreign, probe), throwsAbout('ffo_probe'));
    });

    test('invalid YAML', () {
      expect(
        () => merge('dependency_overrides: [a\n', probe),
        throwsAbout('not valid YAML'),
      );
    });

    test('not a map at the top level', () {
      expect(() => merge('- a\n', probe), throwsAbout('must be a map'));
    });

    test('dependency_overrides is not a map', () {
      expect(
        () => merge('dependency_overrides: [a]\n', probe),
        throwsAbout('`dependency_overrides`'),
      );
    });

    test('an alias, which would be cut together with its anchor', () {
      const aliased = 'base: &k foo\n'
          'dependency_overrides:\n'
          '  *k : {path: ../foo}\n';

      expect(() => merge(aliased, probe), throwsAbout('anchors and aliases'));
      expect(
        () => merge('# flutter_flavor_overrides: foo\n$aliased', {}),
        throwsAbout('anchors and aliases'),
      );
    });

    test('an anchor without an alias', () {
      expect(
        () => merge('base: !!str &k foo\n', probe),
        throwsAbout('anchors and aliases'),
      );
    });

    test('an indented top-level map, which a rewrite would re-nest', () {
      expect(() => merge('  other_key: 1\n', probe), throwsAbout('indented'));
    });

    test('a document end marker, after a document or alone', () {
      expect(() => merge('other_key: 1\n...\n', probe), throwsAbout('`...`'));
      expect(() => merge('# notes\n...\n', probe), throwsAbout('`...`'));
    });

    test('more than one document', () {
      expect(
        () => merge('other_key: 1\n---\nmore: 2\n', probe),
        throwsAbout('more than one YAML document'),
      );
    });
  });
}
