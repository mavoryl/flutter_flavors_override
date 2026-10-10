import 'dart:io';

import 'package:flutter_flavor_overrides/flutter_flavor_overrides.dart';
import 'package:test/test.dart';

import 'support/project_builder.dart';

void main() {
  late ProjectBuilder project;

  setUp(() {
    project = ProjectBuilder();
    // The no-op stub every test swaps ffo_probe for.
    project.pubspec('stubs/ffo_probe', 'name: ffo_probe\n');
  });
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

  /// flavor_overrides.yaml in [dir] with the prod override of ffo_probe to
  /// [path], relative to [dir].
  String probeConfig(String dir, String path) => project.config(dir, '''
ffo_probe:
  prod:
    path: $path
''');

  /// A single package `app` that uses ffo_probe, with its config.
  void singlePackage() {
    project.pubspec('app', 'name: app\ndependencies:\n  ffo_probe: 1.0.0\n');
    probeConfig('app', '../stubs/ffo_probe');
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
  });

  group('flavor_overrides.yaml', () {
    String noConfig(String dir) => 'flutter_flavor_overrides: error: no '
        'flavor_overrides.yaml in ${project.path(dir)} or above: create it '
        'next to the root pubspec.yaml of the project.\n';

    test('missing: --flavor is an error naming where it looked', () async {
      project.pubspec('app', 'name: app\ndependencies:\n  ffo_probe: 1.0.0\n');

      final result = await cli(['--flavor', 'prod'], dir: 'app');

      expect(result.code, 1);
      expect(result.out, isEmpty);
      expect(result.err, noConfig('app'));
    });

    test('missing: --list-dependents is an error too', () async {
      project.pubspec('app', 'name: app\n');

      final result = await cli(
        ['--flavor', 'prod', '--list-dependents'],
        dir: 'app',
      );

      expect(result.code, 1);
      expect(result.err, noConfig('app'));
    });

    test('missing, in a directory without pubspec.yaml', () async {
      final result = await cli(['--flavor', 'prod']);

      expect(result.code, 1);
      expect(result.err, noConfig('.'));
    });

    test('missing: --clean still removes our entries', () async {
      project.pubspec('app', 'name: app\ndependencies:\n  ffo_probe: 1.0.0\n');
      project.file('app/pubspec_overrides.yaml', probeFile);

      final result = await cli(['--clean'], dir: 'app');

      expect(result.err, isEmpty);
      expect(result.code, 0);
      expect(result.out, 'removed pubspec_overrides.yaml\n');
    });

    test('not valid: an error naming it and the place, nothing written',
        () async {
      project.pubspec('app', 'name: app\ndependencies:\n  ffo_probe: 1.0.0\n');
      final config = project.config('app', 'ffo_probe:\n  prod: true\n');

      final result = await cli(['--flavor', 'prod'], dir: 'app');

      expect(result.code, 1);
      expect(result.err, startsWith('flutter_flavor_overrides: error: '));
      expect(result.err, contains(config));
      expect(result.err, contains('`ffo_probe.prod`'));
      expect(read('app/pubspec_overrides.yaml'), isNull);
    });

    test('without a pubspec.yaml next to it: an error', () async {
      project.pubspec('app', 'name: app\ndependencies:\n  ffo_probe: 1.0.0\n');
      final config = probeConfig('.', 'stubs/ffo_probe');

      final result = await cli(['--flavor', 'prod'], dir: 'app');

      expect(result.code, 1);
      expect(
        result.err,
        'flutter_flavor_overrides: error: $config: no pubspec.yaml next to '
        'it; flavor_overrides.yaml goes next to the root pubspec.yaml of the '
        'project.\n',
      );
      expect(read('app/pubspec_overrides.yaml'), isNull);
    });

    group('next to a workspace member', () {
      late String config;

      setUp(() {
        project.pubspec('.', 'name: root\nworkspace:\n  - packages/*\n');
        project.pubspec('packages/feature', '''
name: feature
resolution: workspace
dependencies:
  ffo_probe: 1.0.0
''');
        config = probeConfig('packages/feature', '../../stubs/ffo_probe');
      });

      test('the same error from the root and from the member', () async {
        final fromRoot = await cli(['--flavor', 'prod']);
        final fromMember = await cli(
          ['--flavor', 'prod'],
          dir: 'packages/feature',
        );

        expect(fromRoot.code, 1);
        expect(fromMember.code, 1);
        expect(
          fromRoot.err,
          'flutter_flavor_overrides: error: $config: a project has one '
          'flavor_overrides.yaml, next to its root pubspec.yaml '
          '(${project.path('pubspec.yaml')}): move its overrides to '
          '${project.path('flavor_overrides.yaml')}.\n',
        );
        expect(fromMember.err, fromRoot.err);
        expect(read('pubspec_overrides.yaml'), isNull);
        expect(read('packages/feature/pubspec_overrides.yaml'), isNull);
      });

      test('--clean fails the same way', () async {
        final result = await cli(['--clean'], dir: 'packages/feature');

        expect(result.code, 1);
        expect(result.err, contains(config));
      });
    });

    test('in a module as well as next to the root: an error naming both',
        () async {
      project.pubspec('app', '''
name: app
dependencies:
  feature:
    path: ../packages/feature
''');
      project.pubspec('packages/feature', '''
name: feature
dependencies:
  ffo_probe: 1.0.0
''');
      final root = probeConfig('app', '../stubs/ffo_probe');
      final nested = probeConfig('packages/feature', '../../stubs/ffo_probe');

      final result = await cli(['--flavor', 'prod'], dir: 'app');

      expect(result.code, 1);
      expect(result.err, contains(nested));
      expect(result.err, contains(root));
      expect(read('app/pubspec_overrides.yaml'), isNull);
    });

    group('a flavor_overrides section in a pubspec', () {
      setUp(() {
        project.pubspec('app', '''
name: app
dependencies:
  feature:
    path: ../packages/feature
''');
        project.pubspec('packages/feature', '''
name: feature
dependencies:
  ffo_probe: 1.0.0
flavor_overrides:
  prod:
    ffo_probe:
      path: ../../stubs/ffo_probe
''');
      });

      test('is an error pointing to the file, nothing written', () async {
        final config = probeConfig('app', '../stubs/ffo_probe');

        final result = await cli(['--flavor', 'prod'], dir: 'app');

        expect(result.code, 1);
        expect(
          result.err,
          'flutter_flavor_overrides: error: '
          '${project.path('packages/feature/pubspec.yaml')}: '
          '`flavor_overrides` in a pubspec is not read: move it to $config '
          '(package, then flavor, then dependency spec).\n',
        );
        expect(read('app/pubspec_overrides.yaml'), isNull);
        expect(read('packages/feature/pubspec_overrides.yaml'), isNull);
      });

      test('is an error without flavor_overrides.yaml too', () async {
        final result = await cli(['--clean'], dir: 'app');

        expect(result.code, 1);
        expect(
          result.err,
          contains(project.path('packages/feature/pubspec.yaml')),
        );
        expect(
          result.err,
          contains(project.path('app/flavor_overrides.yaml')),
        );
      });
    });

    group('a path: that is not the package', () {
      setUp(() {
        project.pubspec(
          'app',
          'name: app\ndependencies:\n  ffo_probe: 1.0.0\n',
        );
      });

      test('a directory without pubspec.yaml is an error', () async {
        final config = probeConfig('app', '../stubs/missing');

        final result = await cli(['--flavor', 'prod'], dir: 'app');

        expect(result.code, 1);
        expect(
          result.err,
          'flutter_flavor_overrides: error: $config: `ffo_probe.prod` points '
          'to ${project.path('stubs/missing')}, which has no pubspec.yaml.\n',
        );
        expect(read('app/pubspec_overrides.yaml'), isNull);
      });

      test('a package of another name is an error', () async {
        project.pubspec('stubs/other', 'name: other\n');
        final config = probeConfig('app', '../stubs/other');

        final result = await cli(['--flavor', 'prod', '--dry-run'], dir: 'app');

        expect(result.code, 1);
        expect(result.out, isEmpty);
        expect(
          result.err,
          'flutter_flavor_overrides: error: $config: `ffo_probe.prod` points '
          'to ${project.path('stubs/other')}, the package `other`, not '
          '`ffo_probe`; pub would refuse it.\n',
        );
      });

      test('in another flavor, it does not stop this one', () async {
        project.config('app', '''
ffo_probe:
  prod:
    path: ../stubs/ffo_probe
  qa:
    path: ../stubs/missing
''');

        final result = await cli(['--flavor', 'prod'], dir: 'app');

        expect(result.err, isEmpty);
        expect(result.code, 0);
      });
    });
  });

  test('workspace: one file in the root, run from a member', () async {
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
''');
    probeConfig('.', 'stubs/ffo_probe');

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

  group('an override of a workspace member', () {
    late String config;

    /// prod overrides my_library, a member that app uses.
    setUp(() {
      project.pubspec('.', '''
name: root
workspace:
  - app
  - packages/*
''');
      project.pubspec('app', '''
name: app
resolution: workspace
dependencies:
  my_library: 1.0.0
  other_plugin: 1.0.0
''');
      project.pubspec(
        'packages/my_library',
        'name: my_library\nversion: 1.0.0\nresolution: workspace\n',
      );
      project.pubspec('stubs/my_library', 'name: my_library\n');
      config = project.config('.', '''
my_library:
  prod:
    path: stubs/my_library
other_plugin:
  dev: 2.0.0
''');
    });

    test('fails before any write, naming the files and the fix', () async {
      final result = await cli(['--flavor', 'prod']);

      expect(result.code, 1);
      expect(result.out, isEmpty);
      expect(
        result.err,
        'flutter_flavor_overrides: error: $config: flavor `prod` overrides '
        '`my_library`, a member of the pub workspace '
        '(${project.path('packages/my_library/pubspec.yaml')}); pub does not '
        'override workspace members. To swap it, take it out of '
        '`workspace:` and depend on it through `path:`.\n',
      );
      expect(read('pubspec_overrides.yaml'), isNull);
    });

    test('fails with --dry-run too', () async {
      final result = await cli(['--flavor', 'prod', '--dry-run']);

      expect(result.code, 1);
      expect(result.out, isEmpty);
      expect(result.err, contains('`my_library`'));
    });

    test('does not stop another flavor', () async {
      final result = await cli(['--flavor', 'dev']);

      expect(result.err, isEmpty);
      expect(result.code, 0);
      expect(result.out, 'wrote pubspec_overrides.yaml (other_plugin)\n');
    });

    test('does not stop --clean', () async {
      final result = await cli(['--clean']);

      expect(result.code, 0);
      expect(result.out, 'up to date\n');
    });
  });

  test('workspace: a package taken out of it, through path:, is overridden',
      () async {
    project.pubspec('.', 'name: root\nworkspace:\n  - app\n');
    project.pubspec('app', '''
name: app
resolution: workspace
dependencies:
  my_library:
    path: ../packages/my_library
''');
    project.pubspec('packages/my_library', 'name: my_library\n');
    project.pubspec('stubs/my_library', 'name: my_library\n');
    project.config('.', '''
my_library:
  prod:
    path: stubs/my_library
''');

    final result = await cli(['--flavor', 'prod']);

    expect(result.err, isEmpty);
    expect(result.code, 0);
    expect(read('pubspec_overrides.yaml'), contains('path: stubs/my_library'));
  });

  group('paths are printed relative to where the tool runs', () {
    setUp(() {
      // ws/ with members a and b, both use the plugin.
      project.pubspec('ws', 'name: ws\nworkspace:\n  - a\n  - b\n');
      for (final member in ['a', 'b']) {
        project.pubspec('ws/$member', '''
name: $member
resolution: workspace
dependencies:
  ffo_probe: 1.0.0
''');
      }
      probeConfig('ws', '../stubs/ffo_probe');
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
    /// app → packages/feature → packages/core; feature uses the plugin; the
    /// config is next to app.
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
''');
      project.pubspec('packages/core', 'name: core\n');
      probeConfig('app', '../stubs/ffo_probe');
    }

    const featureFile = '# flutter_flavor_overrides: ffo_probe\n'
        'dependency_overrides:\n'
        '  ffo_probe:\n'
        '    path: ../../stubs/ffo_probe\n';

    test('every package that uses the plugin gets a file', () async {
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
      expect(read('packages/feature/pubspec_overrides.yaml'), featureFile);
      expect(read('packages/core/pubspec_overrides.yaml'), isNull);
    });

    test('a module gets it without depending on another module that uses it',
        () async {
      // a and g both use ffo_probe; neither depends on the other.
      project.pubspec('app', '''
name: app
dependencies:
  a:
    path: ../modules/a
  g:
    path: ../modules/g
''');
      for (final module in ['a', 'g']) {
        project.pubspec(
          'modules/$module',
          'name: $module\ndependencies:\n  ffo_probe: 1.0.0\n',
        );
      }
      probeConfig('app', '../stubs/ffo_probe');

      final result = await cli(['--flavor', 'prod'], dir: 'app');

      expect(result.err, isEmpty);
      expect(result.code, 0);
      expect(
        result.out,
        'wrote pubspec_overrides.yaml (ffo_probe)\n'
        'wrote ../modules/a/pubspec_overrides.yaml (ffo_probe)\n'
        'wrote ../modules/g/pubspec_overrides.yaml (ffo_probe)\n',
      );
      expect(read('modules/g/pubspec_overrides.yaml'), featureFile);
    });

    test('a package linked by a path: override uses it too', () async {
      modules();
      project.pubspec('app', '''
name: app
dependencies:
  feature: any
dependency_overrides:
  feature:
    path: ../packages/feature
''');

      final result = await cli(['--flavor', 'prod'], dir: 'app');

      expect(result.err, isEmpty);
      expect(result.code, 0);
      expect(
        result.out,
        'wrote pubspec_overrides.yaml (ffo_probe)\n'
        'wrote ../packages/feature/pubspec_overrides.yaml (ffo_probe)\n',
      );
      expect(
        read('app/pubspec_overrides.yaml'),
        '# flutter_flavor_overrides: feature,ffo_probe\n'
        'dependency_overrides:\n'
        '  feature:\n'
        '    path: ../packages/feature\n'
        '  ffo_probe:\n'
        '    path: ../stubs/ffo_probe\n',
      );
    });

    test('a module is never overridden in its own file', () async {
      modules();
      project.pubspec('stubs/feature', 'name: feature\n');
      project.config('app', '''
feature:
  prod:
    path: ../stubs/feature
''');

      final result = await cli(['--flavor', 'prod'], dir: 'app');

      expect(result.err, isEmpty);
      expect(result.code, 0);
      expect(result.out, 'wrote pubspec_overrides.yaml (feature)\n');
      expect(
        read('app/pubspec_overrides.yaml'),
        '# flutter_flavor_overrides: feature\n'
        'dependency_overrides:\n'
        '  feature:\n'
        '    path: ../stubs/feature\n',
      );
      expect(read('packages/feature/pubspec_overrides.yaml'), isNull);
    });

    test('a package no module uses: a warning, nothing written for it',
        () async {
      modules();
      final config = project.config('app', '''
ffo_probe:
  prod:
    path: ../stubs/ffo_probe
unused_plugin:
  prod: 1.0.0
''');

      final result = await cli(['--flavor', 'prod'], dir: 'app');

      expect(result.code, 0);
      expect(
        result.err,
        'flutter_flavor_overrides: warning: $config: no package of the '
        'project uses `unused_plugin`; its override for flavor `prod` is '
        'left out.\n',
      );
      expect(read('app/pubspec_overrides.yaml'), probeFile);
      expect(read('packages/feature/pubspec_overrides.yaml'), featureFile);
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
  });

  group('a package used through another one, not local', () {
    /// app uses ffo_probe only through third_party, from pub.dev.
    setUp(() {
      project.pubspec(
        'app',
        'name: app\ndependencies:\n  third_party: 1.0.0\n',
      );
      probeConfig('app', '../stubs/ffo_probe');
    });

    test('is overridden when pubspec.lock lists it', () async {
      project.file('app/pubspec.lock', '''
packages:
  ffo_probe:
    dependency: transitive
    source: hosted
    version: "1.0.0"
  third_party:
    dependency: "direct main"
    source: hosted
    version: "1.0.0"
''');

      final result = await cli(['--flavor', 'prod'], dir: 'app');

      expect(result.err, isEmpty);
      expect(result.code, 0);
      expect(read('app/pubspec_overrides.yaml'), probeFile);
    });

    test('is a warning without pubspec.lock', () async {
      final result = await cli(['--flavor', 'prod'], dir: 'app');

      expect(result.code, 0);
      expect(result.err, contains('`ffo_probe`'));
      expect(result.out, 'up to date\n');
    });

    test('a pubspec.lock that cannot be read is a warning, once', () async {
      final lock = project.file('app/pubspec.lock', '- ffo_probe\n');

      final result = await cli(['--flavor', 'prod'], dir: 'app');

      expect(result.code, 0);
      expect(
        result.err,
        startsWith(
          'flutter_flavor_overrides: warning: $lock: not a pubspec.lock, '
          'which is a map; ignored.\n'
          'flutter_flavor_overrides: warning: ',
        ),
      );
      expect(result.err.split('\n'), hasLength(3));
    });
  });

  group('melos packages without a workspace', () {
    /// The e2e melos6 layout: app depends on feature by version, melos links
    /// it; feature uses the plugin; the config is next to the melos root.
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
''');
      probeConfig('.', 'stubs/ffo_probe');
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

    test('a config next to a melos package is an error naming the root',
        () async {
      melos();
      File(project.path('flavor_overrides.yaml')).deleteSync();
      final config = probeConfig('app', '../stubs/ffo_probe');

      final result = await cli(['--flavor', 'prod'], dir: 'app');

      expect(result.code, 1);
      expect(result.err, contains(config));
      expect(result.err, contains(project.path('pubspec.yaml')));
      expect(read('app/pubspec_overrides.yaml'), isNull);
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
''');
      probeConfig('app', '../stubs/ffo_probe');
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

  group('a flavor flavor_overrides.yaml does not name', () {
    const note = 'flutter_flavor_overrides: no flavor_overrides for flavor '
        '`prdo` in this project. Did you mean `prod`? '
        'Declared flavors: prod.\n';

    test('is noted on stderr; our entries still go', () async {
      singlePackage();
      await cli(['--flavor', 'prod'], dir: 'app');

      final result = await cli(['--flavor', 'prdo'], dir: 'app');

      expect(result.code, 0);
      expect(result.err, note);
      expect(result.out, 'removed pubspec_overrides.yaml\n');
      expect(read('app/pubspec_overrides.yaml'), isNull);
    });

    test('is noted with --dry-run and --list-dependents too', () async {
      singlePackage();

      final dryRun = await cli(['--flavor', 'prdo', '--dry-run'], dir: 'app');
      expect(dryRun.code, 0);
      expect(dryRun.err, note);
      expect(dryRun.out, 'up to date\n');

      final listed = await cli(
        ['--flavor', 'prdo', '--list-dependents'],
        dir: 'app',
      );
      expect(listed.code, 0);
      expect(listed.err, note);
      expect(listed.out, isEmpty);
    });

    test('an empty flavor_overrides.yaml says so', () async {
      project.pubspec('app', 'name: app\n');
      project.config('app', '# nothing to swap yet\n');

      final result = await cli(['--flavor', 'prod'], dir: 'app');

      expect(result.code, 0);
      expect(
        result.err,
        'flutter_flavor_overrides: no flavor_overrides for flavor `prod` in '
        'this project: flavor_overrides.yaml declares no overrides.\n',
      );
      expect(result.out, 'up to date\n');
    });

    test('a flavor named under any package is not noted', () async {
      project.pubspec('.', 'name: root\nworkspace:\n  - a\n  - b\n');
      project.pubspec('a', 'name: a\nresolution: workspace\n');
      project.pubspec(
        'b',
        'name: b\nresolution: workspace\ndependencies:\n  ffo_probe: any\n',
      );
      project.config('.', '''
ffo_probe:
  prdo: 1.0.0
other_plugin:
  prod: 1.0.0
''');

      final result = await cli(['--flavor', 'prdo'], dir: 'a');

      expect(result.err, isEmpty);
      expect(result.code, 0);
      expect(result.out, 'wrote ../pubspec_overrides.yaml (ffo_probe)\n');
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
''');
      project.pubspec('packages/core', '''
name: core
dev_dependencies:
  ffo_probe: 1.0.0
''');
      project.pubspec('packages/unrelated', 'name: unrelated\n');
      probeConfig('app', '../stubs/ffo_probe');
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
dependencies:
  ffo_probe: 1.0.0
''');
      probeConfig('.', 'stubs/ffo_probe');
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

    test('may override it in a pubspec their own file replaces', () async {
      project.pubspec('packages/other', '''
name: other
resolution: workspace
dependency_overrides:
  ffo_probe: 1.0.0
''');
      // With the key, pub ignores the pubspec's dependency_overrides.
      project.file(
        'packages/other/pubspec_overrides.yaml',
        'dependency_overrides:\n  core:\n    path: ../core\n',
      );

      final result = await cli(['--flavor', 'prod']);

      expect(result.err, isEmpty);
      expect(result.code, 0);
      expect(read('pubspec_overrides.yaml'), contains('stubs/ffo_probe'));
    });

    test('may not override it in a pubspec their own file leaves in force',
        () async {
      project.pubspec('packages/other', '''
name: other
resolution: workspace
dependency_overrides:
  ffo_probe: 1.0.0
''');
      project.file('packages/other/pubspec_overrides.yaml', '# notes\n');

      final result = await cli(['--flavor', 'prod']);

      expect(result.code, 1);
      expect(result.err, contains(project.path('packages/other/pubspec.yaml')));
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

    group('a local package outside the workspace loses our entries', () {
      setUp(() {
        project.pubspec('packages/other', '''
name: other
resolution: workspace
dependencies:
  vendor:
    path: ../../vendor
''');
        project.pubspec('vendor', 'name: vendor\n');
        // Left by a run before the project became a workspace.
        project.file(
          'vendor/pubspec_overrides.yaml',
          '# flutter_flavor_overrides: ffo_probe\n'
              'dependency_overrides:\n'
              '  ffo_probe:\n'
              '    path: ../stubs/ffo_probe\n',
        );
      });

      test('on a run', () async {
        final result = await cli(['--flavor', 'prod']);

        expect(result.err, isEmpty);
        expect(result.code, 0);
        expect(
          result.out,
          'wrote pubspec_overrides.yaml (ffo_probe)\n'
          'removed vendor/pubspec_overrides.yaml\n',
        );
        expect(read('vendor/pubspec_overrides.yaml'), isNull);
      });

      test('on --clean', () async {
        final result = await cli(['--clean']);

        expect(result.code, 0);
        expect(result.out, 'removed vendor/pubspec_overrides.yaml\n');
        expect(read('vendor/pubspec_overrides.yaml'), isNull);
      });
    });

    test("the root's own dependency_overrides give way", () async {
      final result = await cli(['--flavor', 'prod']);

      expect(result.code, 0);
      expect(read('pubspec_overrides.yaml'), contains('stubs/ffo_probe'));
    });
  });
}
