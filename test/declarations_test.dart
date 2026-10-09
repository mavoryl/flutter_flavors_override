import 'package:flutter_flavor_overrides/src/declarations.dart';
import 'package:flutter_flavor_overrides/src/errors.dart';
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
          for (final d in declarations)
            {'package': d.package, 'spec': d.spec, 'sources': d.sources},
        ];

    /// app → packages/feature by path; feature declares a prod stub.
    void appWithFeature({String appExtra = ''}) {
      project.pubspec('app', '''
name: app
dependencies:
  feature:
    path: ../packages/feature
$appExtra''');
      project.pubspec('packages/feature', '''
name: feature
flavor_overrides:
  prod:
    some_plugin:
      path: ../../stubs/some_plugin
  dev:
    other_plugin:
      path: ../../stubs/other_plugin
''');
    }

    test('a module declaration is rebased to each resolving package', () {
      appWithFeature();
      final result = Project.discover(project.path('app'));

      expect(describe(declarationsFor(result, project.path('app'), 'prod')), [
        {
          'package': 'some_plugin',
          'spec': {'path': '../stubs/some_plugin'},
          'sources': [project.path('packages/feature/pubspec.yaml')],
        },
      ]);
      expect(
        describe(
          declarationsFor(result, project.path('packages/feature'), 'prod'),
        ),
        [
          {
            'package': 'some_plugin',
            'spec': {'path': '../../stubs/some_plugin'},
            'sources': [project.path('packages/feature/pubspec.yaml')],
          },
        ],
      );
    });

    test('a flavor without declarations is empty', () {
      appWithFeature();
      final result = Project.discover(project.path('app'));

      expect(declarationsFor(result, project.path('app'), 'staging'), isEmpty);
    });

    test('declarations of another flavor are ignored', () {
      appWithFeature();
      final result = Project.discover(project.path('app'));

      expect(
        declarationsFor(result, project.path('app'), 'dev')
            .map((d) => d.package),
        ['other_plugin'],
      );
    });

    test('packages not reachable from the target do not contribute', () {
      appWithFeature(appExtra: '''
flavor_overrides:
  prod:
    app_only: 1.0.0
''');
      final result = Project.discover(project.path('app'));

      // feature does not depend on app, so app's declarations stay out.
      expect(
        declarationsFor(result, project.path('packages/feature'), 'prod')
            .map((d) => d.package),
        ['some_plugin'],
      );
      expect(
        declarationsFor(result, project.path('app'), 'prod')
            .map((d) => d.package),
        ['app_only', 'some_plugin'],
      );
    });

    test('workspace: declarations from every local package go to the root', () {
      project.pubspec('.', '''
name: root
workspace:
  - app
  - packages/feature
''');
      project.pubspec('app', '''
name: app
resolution: workspace
flavor_overrides:
  prod:
    z_plugin: 2.0.0
''');
      project.pubspec('packages/feature', '''
name: feature
resolution: workspace
dependencies:
  vendor:
    path: ../../vendor
flavor_overrides:
  prod:
    some_plugin:
      path: ../../stubs/some_plugin
''');
      project.pubspec('vendor', '''
name: vendor
flavor_overrides:
  prod:
    a_plugin:
      git: ../repos/a_plugin
''');
      final result = Project.discover(project.path('app'));

      expect(describe(declarationsFor(result, project.root, 'prod')), [
        {
          'package': 'a_plugin',
          'spec': {'git': 'repos/a_plugin'},
          'sources': [project.path('vendor/pubspec.yaml')],
        },
        {
          'package': 'some_plugin',
          'spec': {'path': 'stubs/some_plugin'},
          'sources': [project.path('packages/feature/pubspec.yaml')],
        },
        {
          'package': 'z_plugin',
          'spec': '2.0.0',
          'sources': [project.path('app/pubspec.yaml')],
        },
      ]);
    });

    test('identical declarations collapse into one with every source', () {
      appWithFeature(appExtra: '''
flavor_overrides:
  prod:
    some_plugin:
      path: ../stubs/some_plugin
''');
      final result = Project.discover(project.path('app'));

      expect(describe(declarationsFor(result, project.path('app'), 'prod')), [
        {
          'package': 'some_plugin',
          'spec': {'path': '../stubs/some_plugin'},
          'sources': [
            project.path('app/pubspec.yaml'),
            project.path('packages/feature/pubspec.yaml'),
          ],
        },
      ]);
    });

    test('different declarations for one package are an error', () {
      appWithFeature(appExtra: '''
flavor_overrides:
  prod:
    some_plugin:
      path: ../stubs/another_stub
''');
      final result = Project.discover(project.path('app'));

      expect(
        () => declarationsFor(result, project.path('app'), 'prod'),
        throwsA(
          isA<FlavorOverridesException>().having(
            (e) => e.message,
            'message',
            allOf([
              contains('some_plugin'),
              contains('prod'),
              contains(project.path('app/pubspec.yaml')),
              contains(project.path('packages/feature/pubspec.yaml')),
            ]),
          ),
        ),
      );
    });
  });
}
