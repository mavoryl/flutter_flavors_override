import 'package:flutter_flavor_overrides/src/config.dart';
import 'package:flutter_flavor_overrides/src/errors.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/project_builder.dart';

void main() {
  late ProjectBuilder project;

  setUp(() => project = ProjectBuilder());
  tearDown(() => project.delete());

  /// Writes [content] as the config file in the tree root and loads it.
  OverridesConfig load(String content) =>
      OverridesConfig.load(project.file(configFileName, content));

  group('load', () {
    test('reads every kind of spec, paths as written', () {
      final config = load('''
some_plugin:                 # package
  prod:                      # flavor
    path: stubs/some_plugin
  prodRelease:
    path: stubs/some_plugin
analytics:
  qa:
    git: {url: https://github.com/acme/analytics_no_op, ref: v1.0.0}
  demo: 2.0.0
  any_version:
''');

      expect(config.path, project.path(configFileName));
      expect(config.dir, project.root);
      expect(config.packages, {
        'some_plugin': {
          'prod': {'path': 'stubs/some_plugin'},
          'prodRelease': {'path': 'stubs/some_plugin'},
        },
        'analytics': {
          'qa': {
            'git': {
              'url': 'https://github.com/acme/analytics_no_op',
              'ref': 'v1.0.0',
            },
          },
          'demo': '2.0.0',
          'any_version': null,
        },
      });
      expect(config.packages['analytics'], containsPair('any_version', null));
    });

    test('an empty file is an empty config', () {
      for (final content in ['', '# nothing yet\n']) {
        final config = load(content);

        expect(config.packages, isEmpty, reason: content);
        expect(config.flavors, isEmpty, reason: content);
      }
    });

    test('the path is normalized', () {
      project.file(configFileName, '');

      final config = OverridesConfig.load(
        p.join(project.root, 'a', '..', configFileName),
      );

      expect(config.path, project.path(configFileName));
      expect(config.dir, project.root);
    });
  });

  group('flavors', () {
    test('every flavor of every package, sorted, once', () {
      final config = load('''
b_plugin:
  prod: 1.0.0
  dev: 1.0.0
a_plugin:
  qa: 1.0.0
  prod: 1.0.0
''');

      expect(config.flavors, ['dev', 'prod', 'qa']);
    });
  });

  group('forFlavor', () {
    test('package to spec, packages sorted', () {
      final config = load('''
z_plugin:
  prod: 2.0.0
a_plugin:
  prod:
    path: stubs/a_plugin
  dev: 1.0.0
m_plugin:
  dev:
''');

      final prod = config.forFlavor('prod');
      expect(prod, {
        'a_plugin': {'path': 'stubs/a_plugin'},
        'z_plugin': '2.0.0',
      });
      expect(prod.keys, ['a_plugin', 'z_plugin']);
      expect(config.forFlavor('dev'), {'a_plugin': '1.0.0', 'm_plugin': null});
    });

    test('an unknown flavor has none', () {
      expect(load('a_plugin:\n  prod: 1.0.0\n').forFlavor('staging'), isEmpty);
    });
  });

  group('errors name the file and the place in it', () {
    void expectError(String content, List<String> details) {
      final path = project.file(configFileName, content);
      expect(
        () => OverridesConfig.load(path),
        throwsA(
          isA<FlavorOverridesException>().having(
            (e) => e.message,
            'message',
            allOf(
                [startsWith('$path: '), for (final d in details) contains(d)]),
          ),
        ),
      );
    }

    test('a file that cannot be read', () {
      project.dir(configFileName);
      final path = project.path(configFileName);

      expect(
        () => OverridesConfig.load(path),
        throwsA(
          isA<FlavorOverridesException>()
              .having((e) => e.message, 'message', startsWith('$path: ')),
        ),
      );
    });

    test('invalid YAML', () {
      expectError('a_plugin:\n  prod: [1.0.0\n', ['not valid YAML', 'line']);
    });

    test('a root that is not a map', () {
      expectError('- a_plugin\n', ['map']);
      expectError('a_plugin\n', ['map']);
    });

    test('a package key that is not a string', () {
      expectError('3:\n  prod: 1.0.0\n', ['`3`', 'package name']);
      expectError('[a, b]:\n  prod: 1.0.0\n', ['package name']);
    });

    test('a package key that is not a valid package name', () {
      for (final name in ['Some_Plugin', '1plugin', 'some-plugin', 'a.b']) {
        expectError('$name:\n  prod: 1.0.0\n', ['`$name`', 'package name']);
      }
    });

    test('a package without flavors', () {
      expectError('a_plugin:\n', ['`a_plugin`', 'no flavors']);
      expectError('a_plugin: {}\n', ['`a_plugin`', 'no flavors']);
    });

    test('a package value that is not a map', () {
      expectError('a_plugin: 1.0.0\n', ['`a_plugin`', 'map']);
      expectError('a_plugin: [prod]\n', ['`a_plugin`', 'map']);
    });

    test('a flavor key that is not a non-empty string', () {
      expectError('a_plugin:\n  3: 1.0.0\n', ['`a_plugin.3`', 'flavor']);
      expectError('a_plugin:\n  true: 1.0.0\n', ['`a_plugin.true`', 'flavor']);
      expectError('a_plugin:\n  "": 1.0.0\n', ['`a_plugin.""`', 'flavor']);
      expectError('a_plugin:\n  ~: 1.0.0\n', ['`a_plugin.~`', 'flavor']);
    });

    test('a spec that is a boolean, a number or a list', () {
      for (final spec in ['true', '3', '2.0', '[1.0.0]']) {
        expectError(
          'a_plugin:\n  prod: $spec\n',
          ['`a_plugin.prod`', 'spec'],
        );
      }
    });

    test('in a flavor that is not the one asked for, too', () {
      expectError('''
a_plugin:
  prod:
    path: stubs/a_plugin
b_plugin:
  prod: 1.0.0
  qa: true
''', ['`b_plugin.qa`']);
      expectError('''
a_plugin:
  prod: 1.0.0
  4: 1.0.0
''', ['`a_plugin.4`']);
    });

    group('the shape of every dependency spec', () {
      test('accepts every shape pub takes', () {
        final config = load('''
a:
  version: ^1.0.0
  any:
  path: {path: stubs/a}
  git: {git: https://example.com/a.git}
  git_map:
    git:
      url: https://example.com/a.git
      ref: v1.0.0
      path: packages/a
      tag_pattern: v{{version}}
    version: ^1.0.0
  hosted: {hosted: https://pub.example.com, version: ^1.0.0}
  hosted_map: {hosted: {name: a, url: https://pub.example.com}}
  sdk: {sdk: flutter}
  sdk_version: {sdk: flutter, version: any}
''');

        expect(config.flavors, hasLength(9));
        expect(config.forFlavor('git_map'), {
          'a': {
            'git': {
              'url': 'https://example.com/a.git',
              'ref': 'v1.0.0',
              'path': 'packages/a',
              'tag_pattern': 'v{{version}}',
            },
            'version': '^1.0.0',
          },
        });
      });

      /// A config whose only spec is [spec], under `a.prod`.
      void expectSpecError(String spec, List<String> details) =>
          expectError('a:\n  prod: $spec\n', details);

      test('a source value of the wrong type', () {
        expectSpecError('{path: 42}', ['`a.prod.path`', 'string']);
        expectSpecError('{sdk: [flutter]}', ['`a.prod.sdk`', 'string']);
        expectSpecError('{hosted: 3}', ['`a.prod.hosted`']);
        expectSpecError('{git: true}', ['`a.prod.git`']);
      });

      test('a git map', () {
        expectSpecError('{git: {url: false}}', ['`a.prod.git.url`', 'string']);
        expectSpecError('{git: {ref: main}}', ['`a.prod.git.url`']);
        expectSpecError('{git: {url: u, ref: 3}}', ['`a.prod.git.ref`']);
        expectSpecError('{git: {url: u, branch: b}}', ['`a.prod.git.branch`']);
      });

      test('a hosted map', () {
        expectSpecError('{hosted: {name: 1}}', ['`a.prod.hosted.name`']);
        expectSpecError('{hosted: {url: u, x: y}}', ['`a.prod.hosted.x`']);
      });

      test('not exactly one source', () {
        expectSpecError('{path: a, git: b}', ['`a.prod`', 'one source']);
        expectSpecError('{}', ['`a.prod`', 'one source']);
        expectSpecError('{version: ^1.0.0}', ['`a.prod`', 'one source']);
      });

      test('an unknown key', () {
        expectSpecError('{unknown: x}', ['`a.prod.unknown`']);
        expectSpecError('{path: a, unknown: x}', ['`a.prod.unknown`']);
      });

      test('a version beside path:, or not a string', () {
        expectSpecError('{path: a, version: 1.0.0}', ['`a.prod.version`']);
        expectSpecError('{sdk: flutter, version: 3}', ['`a.prod.version`']);
      });

      test('an empty version string', () {
        expectSpecError("''", ['`a.prod`']);
      });

      test('a key that is not a string, at any level, in any flavor', () {
        expectError('''
a:
  prod: 1.0.0
  qa: {42: hi}
''', ['`a.qa.42`', 'string']);
        expectSpecError('{git: {url: u, 1: x}}', ['`a.prod.git.1`', 'string']);
      });
    });
  });

  group('find', () {
    test('from a nested directory', () {
      final path = project.file(configFileName, '');
      project.dir('packages/feature/lib');

      expect(OverridesConfig.find(project.path('packages/feature/lib')), path);
    });

    test('from its own directory', () {
      final path = project.file(configFileName, '');

      expect(OverridesConfig.find(project.root), path);
    });

    test('the nearest one', () {
      project.file(configFileName, '');
      final nearest = project.file('app/$configFileName', '');

      expect(OverridesConfig.find(project.path('app')), nearest);
    });

    test('none', () {
      project.dir('app');

      expect(OverridesConfig.find(project.path('app')), isNull);
    });

    test('a directory of that name does not count', () {
      project.dir('app/$configFileName');

      expect(OverridesConfig.find(project.path('app')), isNull);
    });
  });
}
