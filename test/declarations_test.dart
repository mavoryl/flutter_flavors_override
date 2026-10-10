import 'package:flutter_flavor_overrides/src/config.dart';
import 'package:flutter_flavor_overrides/src/declarations.dart';
import 'package:flutter_flavor_overrides/src/project.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/project_builder.dart';

void main() {
  group('rebaseSpec', () {
    // Pure path arithmetic: nothing below has to exist.
    final ws = p.absolute('ws');
    final feature = p.join(ws, 'packages', 'feature');
    final app = p.join(ws, 'app');

    Object? rebase(Object? spec, {String? from, String? to}) =>
        rebaseSpec(spec, fromDir: from ?? feature, toDir: to ?? ws);

    test('path: to the workspace root', () {
      expect(rebase({'path': '../../stubs/some_plugin'}), {
        'path': 'stubs/some_plugin',
      });
    });

    test('path: to a sibling package', () {
      expect(rebase({'path': '../../stubs/some_plugin'}, to: app), {
        'path': '../stubs/some_plugin',
      });
    });

    test('path: is normalized', () {
      expect(
          rebase({'path': '../feature/../../stubs/./some_plugin/'}, to: app), {
        'path': '../stubs/some_plugin',
      });
      expect(rebase({'path': './stubs/some_plugin'}, from: app, to: app), {
        'path': 'stubs/some_plugin',
      });
    });

    test('an absolute path: is kept as written', () {
      final absolute = p.join(p.absolute('opt'), '..', 'opt', 'stub');
      expect(rebase({'path': absolute}), {'path': absolute});
    });

    test('a relative git: url is rebased', () {
      expect(rebase({'git': '../repo'}), {'git': 'packages/repo'});
      expect(
        rebase({
          'git': {'url': '../repo', 'ref': 'x', 'path': 'packages/plugin'},
        }),
        {
          'git': {
            'url': 'packages/repo',
            'ref': 'x',
            'path': 'packages/plugin'
          },
        },
      );
    });

    test('a remote or absolute git: url is kept', () {
      for (final url in [
        'https://github.com/org/repo.git',
        'git@github.com:org/repo.git',
        'ssh://git@host/repo.git',
        'file:///srv/repo',
        p.absolute('repo'),
      ]) {
        expect(rebase({'git': url}), {'git': url}, reason: url);
        expect(
          rebase({
            'git': {'url': url, 'ref': 'x'},
          }),
          {
            'git': {'url': url, 'ref': 'x'},
          },
          reason: url,
        );
      }
    });

    test('hosted and sdk specs are kept', () {
      for (final spec in [
        '1.2.0',
        null,
        {'hosted': 'https://pub.example.com', 'version': '^1.0.0'},
        {'version': '1.0.0'},
        {'sdk': 'flutter'},
      ]) {
        expect(rebase(spec), spec);
      }
    });
  });

  group('declarationsFor', () {
    late ProjectBuilder project;

    setUp(() => project = ProjectBuilder());
    tearDown(() => project.delete());

    List<Map<String, Object?>> describe(List<Declaration> declarations) => [
          for (final d in declarations) {'package': d.package, 'spec': d.spec},
        ];

    /// The project of the config in [rootDir], discovered from there.
    (Project, OverridesConfig) load(String rootDir) => (
          Project.discover(project.path(rootDir)),
          OverridesConfig.load(project.path('$rootDir/$configFileName')),
        );

    /// app → path: packages/feature → some_plugin, other_plugin; the config
    /// is next to app, the root.
    void appWithFeature({String appDependencies = '', String config = ''}) {
      project.pubspec('app', '''
name: app
dependencies:
  feature:
    path: ../packages/feature
$appDependencies''');
      project.pubspec('packages/feature', '''
name: feature
dependencies:
  some_plugin: 1.0.0
  other_plugin: 1.0.0
''');
      project.config('app', '''
some_plugin:
  prod:
    path: ../stubs/some_plugin
other_plugin:
  dev:
    path: ../stubs/other_plugin
$config''');
    }

    test('a spec is rebased to each package that uses it', () {
      appWithFeature();
      final (result, config) = load('app');

      expect(
        describe(declarationsFor(result, config, project.path('app'), 'prod')),
        [
          {
            'package': 'some_plugin',
            'spec': {'path': '../stubs/some_plugin'},
          },
        ],
      );
      expect(
        describe(
          declarationsFor(
            result,
            config,
            project.path('packages/feature'),
            'prod',
          ),
        ),
        [
          {
            'package': 'some_plugin',
            'spec': {'path': '../../stubs/some_plugin'},
          },
        ],
      );
    });

    test('a flavor without overrides is empty', () {
      appWithFeature();
      final (result, config) = load('app');

      expect(
        declarationsFor(result, config, project.path('app'), 'staging'),
        isEmpty,
      );
    });

    test('overrides of another flavor are left out', () {
      appWithFeature();
      final (result, config) = load('app');

      expect(
        declarationsFor(result, config, project.path('app'), 'dev')
            .map((d) => d.package),
        ['other_plugin'],
      );
    });

    test('a package the target does not use is left out', () {
      appWithFeature(appDependencies: '  app_only: 1.0.0\n', config: '''
app_only:
  prod: 2.0.0
unused:
  prod: 2.0.0
''');
      final (result, config) = load('app');

      // feature does not depend on app, so app's own dependencies stay out.
      expect(
        declarationsFor(
          result,
          config,
          project.path('packages/feature'),
          'prod',
        ).map((d) => d.package),
        ['some_plugin'],
      );
      expect(
        declarationsFor(result, config, project.path('app'), 'prod')
            .map((d) => d.package),
        ['app_only', 'some_plugin'],
      );
    });

    test('a package used through pubspec.lock only is included', () {
      appWithFeature(config: '''
transitive_plugin:
  prod: 2.0.0
''');
      project.file('app/pubspec.lock', '''
packages:
  transitive_plugin:
    dependency: transitive
    source: hosted
    version: "1.0.0"
''');
      final (result, config) = load('app');

      expect(
        declarationsFor(result, config, project.path('app'), 'prod')
            .map((d) => d.package),
        ['some_plugin', 'transitive_plugin'],
      );
      expect(
        declarationsFor(
          result,
          config,
          project.path('packages/feature'),
          'prod',
        ).map((d) => d.package),
        ['some_plugin'],
      );
    });

    test('a pubspec.lock that cannot be read is a warning', () {
      appWithFeature();
      final lock = project.file('app/pubspec.lock', '- a\n');
      final (result, config) = load('app');
      final warnings = <String>[];

      expect(
        declarationsFor(
          result,
          config,
          project.path('app'),
          'prod',
          warnings: warnings,
        ).map((d) => d.package),
        ['some_plugin'],
      );
      expect(warnings, [startsWith('$lock: ')]);
    });

    test('a package never overrides itself', () {
      appWithFeature(config: '''
feature:
  prod:
    path: ../stubs/feature
''');
      final (result, config) = load('app');

      expect(
        describe(declarationsFor(result, config, project.path('app'), 'prod')),
        [
          {
            'package': 'feature',
            'spec': {'path': '../stubs/feature'},
          },
          {
            'package': 'some_plugin',
            'spec': {'path': '../stubs/some_plugin'},
          },
        ],
      );
      expect(
        declarationsFor(
          result,
          config,
          project.path('packages/feature'),
          'prod',
        ).map((d) => d.package),
        ['some_plugin'],
      );
    });

    test('workspace: whatever any package uses goes to the root', () {
      project.pubspec('.', '''
name: root
workspace:
  - app
  - packages/feature
''');
      project.pubspec('app', '''
name: app
resolution: workspace
dependencies:
  z_plugin: 1.0.0
''');
      project.pubspec('packages/feature', '''
name: feature
resolution: workspace
dependencies:
  vendor:
    path: ../../vendor
  some_plugin: 1.0.0
''');
      project.pubspec(
        'vendor',
        'name: vendor\ndependencies:\n  a_plugin: any\n',
      );
      project.config('.', '''
z_plugin:
  prod: 2.0.0
some_plugin:
  prod:
    path: stubs/some_plugin
a_plugin:
  prod:
    git: repos/a_plugin
not_used:
  prod: 1.0.0
''');
      final (result, config) = load('.');

      expect(
        describe(declarationsFor(result, config, project.root, 'prod')),
        [
          {
            'package': 'a_plugin',
            'spec': {'git': 'repos/a_plugin'},
          },
          {
            'package': 'some_plugin',
            'spec': {'path': 'stubs/some_plugin'},
          },
          {'package': 'z_plugin', 'spec': '2.0.0'},
        ],
      );
    });

    test('a module on another depth gets the path from there', () {
      project.pubspec('app', '''
name: app
dependencies:
  deep:
    path: ../a/b/c/deep
''');
      project.pubspec('a/b/c/deep', 'name: deep\ndependencies:\n  x: any\n');
      project.config('app', 'x:\n  prod:\n    path: ../stubs/x\n');
      final (result, config) = load('app');

      expect(
        describe(
          declarationsFor(result, config, project.path('a/b/c/deep'), 'prod'),
        ),
        [
          {
            'package': 'x',
            'spec': {'path': '../../../../stubs/x'},
          },
        ],
      );
    });
  });
}
