import 'dart:io';

import 'package:flutter_flavor_overrides/flutter_flavor_overrides.dart';
import 'package:test/test.dart';

import 'support/project_builder.dart';

void main() {
  late ProjectBuilder project;

  setUp(() => project = ProjectBuilder());
  tearDown(() => project.delete());

  /// Runs the CLI in [dir] (relative to the project tree).
  Future<({int code, String out, String err})> cli(
    List<String> arguments, {
    String dir = '.',
  }) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await run(
      arguments,
      workingDirectory: project.path(dir),
      out: out,
      err: err,
    );
    return (code: code, out: out.toString(), err: err.toString());
  }

  /// Content of [relative], or null when it does not exist.
  String? read(String relative) {
    final file = File(project.path(relative));
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  const probeFile = '# flutter_flavor_overrides: ffo_probe\n'
      'dependency_overrides:\n'
      '  ffo_probe:\n'
      '    path: ../stubs/ffo_probe\n';

  /// A single package `app` with a prod declaration.
  void singlePackage() {
    project.pubspec('app', '''
name: app
dependencies:
  ffo_probe: 1.0.0
flavor_overrides:
  prod:
    ffo_probe:
      path: ../stubs/ffo_probe
''');
  }

  group('a single package', () {
    test('prod writes the reference file', () async {
      singlePackage();

      final result = await cli(['--flavor', 'prod'], dir: 'app');

      expect(result.err, isEmpty);
      expect(result.code, 0);
      expect(result.out, 'wrote pubspec_overrides.yaml (ffo_probe)\n');
      expect(read('app/pubspec_overrides.yaml'), probeFile);
    });

    test('a re-run is up to date and leaves the file alone', () async {
      singlePackage();
      await cli(['--flavor', 'prod'], dir: 'app');
      final file = File(project.path('app/pubspec_overrides.yaml'));
      final modified = DateTime(2000);
      file.setLastModifiedSync(modified);

      final result = await cli(['--flavor', 'prod'], dir: 'app');

      expect(result.code, 0);
      expect(result.out, 'up to date\n');
      expect(file.lastModifiedSync(), modified);
    });

    test('dev after prod removes the file', () async {
      singlePackage();
      await cli(['--flavor', 'prod'], dir: 'app');

      final result = await cli(['--flavor', 'dev'], dir: 'app');

      expect(result.code, 0);
      expect(result.out, 'removed pubspec_overrides.yaml\n');
      expect(read('app/pubspec_overrides.yaml'), isNull);
    });

    test('dev on a clean checkout writes nothing', () async {
      singlePackage();

      final result = await cli(['--flavor', 'dev'], dir: 'app');

      expect(result.code, 0);
      expect(result.out, 'up to date\n');
      expect(read('app/pubspec_overrides.yaml'), isNull);
    });

    test('-C runs in another directory', () async {
      singlePackage();

      final relative = await cli(['-C', 'app', '--flavor', 'prod']);
      expect(relative.code, 0);
      expect(read('app/pubspec_overrides.yaml'), probeFile);

      final absolute = await cli(
        ['--directory', project.path('app'), '--flavor', 'dev'],
        dir: 'stubs/..',
      );
      expect(absolute.code, 0);
      expect(absolute.out, 'removed pubspec_overrides.yaml\n');
    });

    test('a file that cannot be written is an error', () async {
      singlePackage();
      project.dir('app/pubspec_overrides.yaml');

      final result = await cli(['--flavor', 'prod'], dir: 'app');

      expect(result.code, 1);
      expect(result.err, startsWith('flutter_flavor_overrides: error: '));
      expect(result.err, contains(project.path('app/pubspec_overrides.yaml')));
    });

    test('a directory without pubspec.yaml is an error', () async {
      final result = await cli(['--flavor', 'prod']);

      expect(result.code, 1);
      expect(
        result.err,
        'flutter_flavor_overrides: error: '
        '${project.path('pubspec.yaml')}: not found.\n',
      );
    });
  });

  test('workspace: one file in the root for a member declaration', () async {
    project.pubspec('.', '''
name: root
workspace:
  - packages/*
''');
    project.pubspec('packages/feature', '''
name: feature
resolution: workspace
dependencies:
  ffo_probe: 1.0.0
flavor_overrides:
  prod:
    ffo_probe:
      path: ../../stubs/ffo_probe
''');

    final result = await cli(['--flavor', 'prod'], dir: 'packages/feature');

    expect(result.err, isEmpty);
    expect(result.code, 0);
    expect(result.out, 'wrote ../../pubspec_overrides.yaml (ffo_probe)\n');
    expect(
      read('pubspec_overrides.yaml'),
      '# flutter_flavor_overrides: ffo_probe\n'
      'dependency_overrides:\n'
      '  ffo_probe:\n'
      '    path: stubs/ffo_probe\n',
    );
    expect(read('packages/feature/pubspec_overrides.yaml'), isNull);
  });

  group('paths are printed relative to where the tool runs', () {
    setUp(() {
      // ws/ with members a and b; a declares prod, both use the plugin.
      project.pubspec('ws', 'name: ws\nworkspace:\n  - a\n  - b\n');
      project.pubspec('ws/a', '''
name: a
resolution: workspace
dependencies:
  ffo_probe: 1.0.0
flavor_overrides:
  prod:
    ffo_probe:
      path: ../../stubs/ffo_probe
''');
      project.pubspec('ws/b', '''
name: b
resolution: workspace
dependencies:
  ffo_probe: 1.0.0
''');
    });

    test('wrote and removed, run from a member', () async {
      final wrote = await cli(['--flavor', 'prod'], dir: 'ws/a');
      expect(wrote.out, 'wrote ../pubspec_overrides.yaml (ffo_probe)\n');

      final removed = await cli(['--flavor', 'dev'], dir: 'ws/a');
      expect(removed.out, 'removed ../pubspec_overrides.yaml\n');
    });

    test('a member file removed, run from another member', () async {
      project.file('ws/b/pubspec_overrides.yaml', probeFile);

      final result = await cli(['--clean'], dir: 'ws/a');

      expect(result.out, 'removed ../b/pubspec_overrides.yaml\n');
    });

    test('--dry-run headers, run from a member', () async {
      final result = await cli(['--flavor', 'prod', '--dry-run'], dir: 'ws/a');

      expect(
        result.out,
        startsWith('--- ../pubspec_overrides.yaml (would write)\n'),
      );
    });

    test('--list-dependents, run from a member, a loop over it works',
        () async {
      final result = await cli(
        ['--flavor', 'prod', '--list-dependents'],
        dir: 'ws/a',
      );

      expect(result.out, '.\n../b\n');
      for (final dir in result.out.trim().split('\n')) {
        expect(
          File(project.path('ws/a/$dir/pubspec.yaml')).existsSync(),
          isTrue,
          reason: dir,
        );
      }
    });

    test('-C sets where the tool runs, like git -C', () async {
      final listed = await cli(
        ['-C', 'ws/b', '--flavor', 'prod', '--list-dependents'],
      );
      expect(listed.err, isEmpty);
      expect(listed.out, '.\n../a\n');

      final wrote = await cli(['-C', 'ws/b', '--flavor', 'prod']);
      expect(wrote.out, 'wrote ../pubspec_overrides.yaml (ffo_probe)\n');

      final fromRoot = await cli(['--clean', '--dry-run'], dir: 'ws');
      expect(fromRoot.out, '--- pubspec_overrides.yaml (would remove)\n');
    });
  });

  group('path modules without a workspace', () {
    /// app → packages/feature → packages/core; feature declares prod.
    void modules() {
      project.pubspec('app', '''
name: app
dependencies:
  feature:
    path: ../packages/feature
''');
      project.pubspec('packages/feature', '''
name: feature
dependencies:
  core:
    path: ../core
  ffo_probe: 1.0.0
flavor_overrides:
  prod:
    ffo_probe:
      path: ../../stubs/ffo_probe
''');
      project.pubspec('packages/core', 'name: core\n');
    }

    test('every package that reaches the declaration gets a file', () async {
      modules();

      final result = await cli(['--flavor', 'prod'], dir: 'app');

      expect(result.err, isEmpty);
      expect(result.code, 0);
      expect(
        result.out,
        'wrote pubspec_overrides.yaml (ffo_probe)\n'
        'wrote ../packages/feature/pubspec_overrides.yaml (ffo_probe)\n',
      );
      expect(read('app/pubspec_overrides.yaml'), probeFile);
      expect(
        read('packages/feature/pubspec_overrides.yaml'),
        '# flutter_flavor_overrides: ffo_probe\n'
        'dependency_overrides:\n'
        '  ffo_probe:\n'
        '    path: ../../stubs/ffo_probe\n',
      );
      expect(read('packages/core/pubspec_overrides.yaml'), isNull);
    });

    test('a destination that is not a file fails before any write', () async {
      modules();
      project.dir('packages/feature/pubspec_overrides.yaml');

      final result = await cli(['--flavor', 'prod'], dir: 'app');

      expect(result.code, 1);
      expect(result.out, isEmpty);
      expect(
        result.err,
        contains(project.path('packages/feature/pubspec_overrides.yaml')),
      );
      expect(read('app/pubspec_overrides.yaml'), isNull);
    });

    test('prod then dev removes every file', () async {
      modules();
      await cli(['--flavor', 'prod'], dir: 'app');

      final result = await cli(['--flavor', 'dev'], dir: 'app');

      expect(result.code, 0);
      expect(
        result.out,
        'removed pubspec_overrides.yaml\n'
        'removed ../packages/feature/pubspec_overrides.yaml\n',
      );
      expect(read('app/pubspec_overrides.yaml'), isNull);
      expect(read('packages/feature/pubspec_overrides.yaml'), isNull);
    });

    test('different declarations fail with both paths, writing nothing',
        () async {
      modules();
      // Only feature's own resolution sees its dev dependency `tools`, so
      // app (planned first) is fine and feature conflicts.
      project.pubspec('packages/feature', '''
name: feature
dependencies:
  ffo_probe: 1.0.0
dev_dependencies:
  tools:
    path: ../tools
flavor_overrides:
  prod:
    ffo_probe:
      path: ../../stubs/ffo_probe
''');
      project.pubspec('packages/tools', '''
name: tools
flavor_overrides:
  prod:
    ffo_probe: 2.0.0
''');

      final result = await cli(['--flavor', 'prod'], dir: 'app');

      expect(result.code, 1);
      expect(result.out, isEmpty);
      expect(result.err, startsWith('flutter_flavor_overrides: error: '));
      expect(
        result.err,
        contains(project.path('packages/feature/pubspec.yaml')),
      );
      expect(result.err, contains(project.path('packages/tools/pubspec.yaml')));
      expect(read('app/pubspec_overrides.yaml'), isNull);
    });
  });

  group('melos packages without a workspace', () {
    /// The e2e melos6 layout: app depends on feature by version, melos links
    /// it; feature declares prod.
    void melos() {
      project.pubspec('.', 'name: root\ndev_dependencies:\n  melos: 6.3.3\n');
      project.file('melos.yaml', '''
name: root
packages:
  - app
  - packages/*
''');
      project.pubspec('app', 'name: app\ndependencies:\n  feature: 0.0.1\n');
      project.pubspec('packages/feature', '''
name: feature
version: 0.0.1
dependencies:
  ffo_probe: 1.0.0
flavor_overrides:
  prod:
    ffo_probe:
      path: ../../stubs/ffo_probe
''');
    }

    test('a run from a melos package writes what a run from the root does',
        () async {
      melos();

      final result = await cli(['--flavor', 'prod'], dir: 'app');

      expect(result.err, isEmpty);
      expect(result.code, 0);
      expect(
        result.out,
        'wrote pubspec_overrides.yaml (ffo_probe)\n'
        'wrote ../packages/feature/pubspec_overrides.yaml (ffo_probe)\n',
      );
      expect(read('app/pubspec_overrides.yaml'), probeFile);
      expect(
        read('packages/feature/pubspec_overrides.yaml'),
        '# flutter_flavor_overrides: ffo_probe\n'
        'dependency_overrides:\n'
        '  ffo_probe:\n'
        '    path: ../../stubs/ffo_probe\n',
      );
      expect(read('pubspec_overrides.yaml'), isNull);
      expect((await cli(['--flavor', 'prod'])).out, 'up to date\n');
    });
  });

  group('a path: dependency on a missing directory', () {
    setUp(() {
      project.pubspec('app', '''
name: app
dependencies:
  ffo_probe: 1.0.0
  generated:
    path: ../generated
flavor_overrides:
  prod:
    ffo_probe:
      path: ../stubs/ffo_probe
''');
    });

    test('is a warning naming the pubspec and the path; the run goes on',
        () async {
      final result = await cli(['--flavor', 'prod'], dir: 'app');

      expect(result.code, 0);
      expect(
        result.err,
        'flutter_flavor_overrides: warning: '
        '${project.path('app/pubspec.yaml')}: dependency `generated` points '
        'to ${project.path('generated')}, which does not exist; skipped.\n',
      );
      expect(result.out, 'wrote pubspec_overrides.yaml (ffo_probe)\n');
      expect(read('app/pubspec_overrides.yaml'), probeFile);
    });

    test('is a warning for --clean as well', () async {
      await cli(['--flavor', 'prod'], dir: 'app');

      final result = await cli(['--clean'], dir: 'app');

      expect(result.code, 0);
      expect(result.err, startsWith('flutter_flavor_overrides: warning: '));
      expect(result.out, 'removed pubspec_overrides.yaml\n');
    });

    test('a directory without pubspec.yaml stays an error', () async {
      project.dir('generated');

      final result = await cli(['--flavor', 'prod'], dir: 'app');

      expect(result.code, 1);
      expect(result.err, startsWith('flutter_flavor_overrides: error: '));
      expect(read('app/pubspec_overrides.yaml'), isNull);
    });
  });

  group('--clean', () {
    test('removes our entries and keeps what melos merged in', () async {
      singlePackage();
      await cli(['--flavor', 'prod'], dir: 'app');
      // What melos 6 bootstrap makes of our file.
      project.file(
        'app/pubspec_overrides.yaml',
        '# melos_managed_dependency_overrides: core\n'
            '$probeFile'
            '  core:\n'
            '    path: ../core\n',
      );

      final result = await cli(['--clean'], dir: 'app');

      expect(result.code, 0);
      expect(result.out, 'wrote pubspec_overrides.yaml\n');
      expect(
        read('app/pubspec_overrides.yaml'),
        '# melos_managed_dependency_overrides: core\n'
        'dependency_overrides:\n'
        '  core:\n'
        '    path: ../core\n',
      );
    });

    test('removes a file with only our entries', () async {
      singlePackage();
      await cli(['--flavor', 'prod'], dir: 'app');

      final result = await cli(['--clean'], dir: 'app');

      expect(result.out, 'removed pubspec_overrides.yaml\n');
      expect(read('app/pubspec_overrides.yaml'), isNull);
    });
  });

  group('--dry-run', () {
    test('prints the files it would write and writes nothing', () async {
      singlePackage();

      final result = await cli(['--flavor', 'prod', '--dry-run'], dir: 'app');

      expect(result.code, 0);
      expect(
        result.out,
        '--- pubspec_overrides.yaml (would write)\n$probeFile',
      );
      expect(read('app/pubspec_overrides.yaml'), isNull);
    });

    test('prints the files it would remove and removes nothing', () async {
      singlePackage();
      await cli(['--flavor', 'prod'], dir: 'app');

      final result = await cli(['--clean', '--dry-run'], dir: 'app');

      expect(result.code, 0);
      expect(result.out, '--- pubspec_overrides.yaml (would remove)\n');
      expect(read('app/pubspec_overrides.yaml'), probeFile);
    });

    test('says up to date when nothing would change', () async {
      singlePackage();

      final result = await cli(['--flavor', 'dev', '--dry-run'], dir: 'app');

      expect(result.out, 'up to date\n');
    });
  });

  group('--list-dependents', () {
    setUp(() {
      project.pubspec('app', '''
name: app
dependencies:
  ffo_probe: 1.0.0
  feature:
    path: ../packages/feature
''');
      project.pubspec('packages/feature', '''
name: feature
dependencies:
  ffo_probe: 1.0.0
  core:
    path: ../core
flavor_overrides:
  prod:
    ffo_probe:
      path: ../../stubs/ffo_probe
''');
      project.pubspec('packages/core', '''
name: core
dev_dependencies:
  ffo_probe: 1.0.0
''');
      project.pubspec('packages/unrelated', 'name: unrelated\n');
    });

    test('prints every local package depending on an overridden one', () async {
      final result = await cli(
        ['--flavor', 'prod', '--list-dependents'],
        dir: 'app',
      );

      expect(result.err, isEmpty);
      expect(result.code, 0);
      expect(result.out, '.\n../packages/core\n../packages/feature\n');
      expect(read('app/pubspec_overrides.yaml'), isNull);
      expect(read('packages/feature/pubspec_overrides.yaml'), isNull);
    });

    test('prints nothing for a flavor without overrides', () async {
      final result = await cli(
        ['--flavor', 'dev', '--list-dependents'],
        dir: 'app',
      );

      expect(result.code, 0);
      expect(result.out, isEmpty);
    });
  });

  group('workspace members', () {
    setUp(() {
      project.pubspec('.', '''
name: root
workspace:
  - packages/*
dependency_overrides:
  ffo_probe: 0.9.0
''');
      project.pubspec('packages/feature', '''
name: feature
resolution: workspace
flavor_overrides:
  prod:
    ffo_probe:
      path: ../../stubs/ffo_probe
''');
    });

    test("may not override a package we override, in their pubspec", () async {
      project.pubspec('packages/other', '''
name: other
resolution: workspace
dependency_overrides:
  ffo_probe: 1.0.0
''');

      final result = await cli(['--flavor', 'prod']);

      expect(result.code, 1);
      expect(result.err, contains(project.path('packages/other/pubspec.yaml')));
      expect(result.err, contains(project.path('pubspec_overrides.yaml')));
      expect(result.err, contains('ffo_probe'));
      expect(read('pubspec_overrides.yaml'), isNull);
    });

    test('may not override a package we override, in their own file', () async {
      project.pubspec('packages/other', 'name: other\nresolution: workspace\n');
      project.file(
        'packages/other/pubspec_overrides.yaml',
        'dependency_overrides:\n  ffo_probe: 1.0.0\n',
      );

      final result = await cli(['--flavor', 'prod']);

      expect(result.code, 1);
      expect(
        result.err,
        contains(project.path('packages/other/pubspec_overrides.yaml')),
      );
      expect(read('pubspec_overrides.yaml'), isNull);
    });

    test('lose our entries left in their own file, foreign ones stay',
        () async {
      project.pubspec('packages/other', 'name: other\nresolution: workspace\n');
      // Left by a run before the project became a workspace, then melos.
      project.file(
        'packages/other/pubspec_overrides.yaml',
        '# melos_managed_dependency_overrides: core\n'
            '# flutter_flavor_overrides: ffo_probe\n'
            'dependency_overrides:\n'
            '  core:\n'
            '    path: ../core\n'
            '  ffo_probe:\n'
            '    path: ../../stubs/ffo_probe\n',
      );
      project.file(
        'packages/feature/pubspec_overrides.yaml',
        '# flutter_flavor_overrides: ffo_probe\n'
            'dependency_overrides:\n'
            '  ffo_probe:\n'
            '    path: ../../stubs/ffo_probe\n',
      );

      final result = await cli(['--flavor', 'prod']);

      expect(result.err, isEmpty);
      expect(result.code, 0);
      expect(
        result.out,
        'wrote pubspec_overrides.yaml (ffo_probe)\n'
        'removed packages/feature/pubspec_overrides.yaml\n'
        'wrote packages/other/pubspec_overrides.yaml\n',
      );
      expect(read('packages/feature/pubspec_overrides.yaml'), isNull);
      expect(
        read('packages/other/pubspec_overrides.yaml'),
        '# melos_managed_dependency_overrides: core\n'
        'dependency_overrides:\n'
        '  core:\n'
        '    path: ../core\n',
      );
    });

    test('--clean also cleans their own files', () async {
      project.file(
        'packages/feature/pubspec_overrides.yaml',
        '# flutter_flavor_overrides: ffo_probe\n'
            'dependency_overrides:\n'
            '  ffo_probe:\n'
            '    path: ../../stubs/ffo_probe\n',
      );

      final result = await cli(['--clean']);

      expect(result.code, 0);
      expect(result.out, 'removed packages/feature/pubspec_overrides.yaml\n');
    });

    test("the root's own dependency_overrides give way", () async {
      final result = await cli(['--flavor', 'prod']);

      expect(result.code, 0);
      expect(read('pubspec_overrides.yaml'), contains('stubs/ffo_probe'));
    });
  });
}
