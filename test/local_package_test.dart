import 'package:flutter_flavor_overrides/src/errors.dart';
import 'package:flutter_flavor_overrides/src/local_package.dart';
import 'package:test/test.dart';

import 'support/project_builder.dart';

void main() {
  late ProjectBuilder project;

  setUp(() => project = ProjectBuilder());
  tearDown(() => project.delete());

  test('reads every section into plain Dart values', () {
    final dir = project.pubspec('app', '''
name: app
resolution: workspace
workspace:
  - packages/*
  - tool
dependencies:
  some_plugin: 1.2.0
  feature:
    path: ../feature
dev_dependencies:
  test: any
dependency_overrides:
  other:
    git:
      url: https://example.com/other.git
      ref: main
flavor_overrides:
  prod:
    some_plugin:
      path: ../stubs/some_plugin
  dev:
    other: 2.0.0
''');

    final package = LocalPackage.load(dir);

    expect(package.dir, project.path('app'));
    expect(package.pubspecPath, project.path('app/pubspec.yaml'));
    expect(package.name, 'app');
    expect(package.inWorkspace, isTrue);
    expect(package.workspace, ['packages/*', 'tool']);
    expect(package.dependencies, {
      'some_plugin': '1.2.0',
      'feature': {'path': '../feature'},
    });
    expect(package.dependencies['feature'], isA<Map<String, Object?>>());
    expect(package.devDependencies, {'test': 'any'});
    expect(package.dependencyOverrides, {
      'other': {
        'git': {'url': 'https://example.com/other.git', 'ref': 'main'},
      },
    });
    expect(package.hasFlavorOverridesSection, isTrue);
  });

  test('missing sections are empty, workspace is null', () {
    final package = LocalPackage.load(project.pubspec('app', 'name: app\n'));

    expect(package.dependencies, isEmpty);
    expect(package.devDependencies, isEmpty);
    expect(package.dependencyOverrides, isEmpty);
    expect(package.workspace, isNull);
    expect(package.inWorkspace, isFalse);
    expect(package.hasFlavorOverridesSection, isFalse);
  });

  test('sections without a value are empty, like pub reads them', () {
    final package = LocalPackage.load(project.pubspec('app', '''
name: app
resolution: local
dependencies:
dev_dependencies:
dependency_overrides:
flavor_overrides:
'''));

    expect(package.dependencies, isEmpty);
    expect(package.devDependencies, isEmpty);
    expect(package.dependencyOverrides, isEmpty);
    expect(package.inWorkspace, isFalse);
    expect(package.hasFlavorOverridesSection, isTrue);
  });

  test('a flavor_overrides section of any shape is only noted', () {
    for (final section in ['[a]', '3', '{prod: 3}']) {
      final package = LocalPackage.load(
        project.pubspec('app', 'name: app\nflavor_overrides: $section\n'),
      );

      expect(package.hasFlavorOverridesSection, isTrue, reason: section);
    }
  });

  test('normalizes the directory', () {
    project.pubspec('app', 'name: app\n');

    final package = LocalPackage.load(project.path('app/../app/./'));

    expect(package.dir, project.path('app'));
  });

  group('errors name the pubspec', () {
    Matcher throwsAbout(String pubspecPath, String detail) => throwsA(
          isA<FlavorOverridesException>().having(
            (e) => e.message,
            'message',
            allOf(contains(pubspecPath), contains(detail)),
          ),
        );

    void expectError(String content, String detail) {
      final dir = project.pubspec('app', content);
      expect(
        () => LocalPackage.load(dir),
        throwsAbout(project.path('app/pubspec.yaml'), detail),
      );
    }

    test('missing pubspec', () {
      final dir = project.dir('app');
      expect(
        () => LocalPackage.load(dir),
        throwsAbout(project.path('app/pubspec.yaml'), 'not found'),
      );
    });

    test('invalid YAML', () {
      expectError('name: app\ndependencies: [a\n', 'not valid YAML');
    });

    test('not a map at the top level', () {
      expectError('', 'must be a map');
      expectError('- a\n', 'must be a map');
    });

    test('no name', () {
      expectError('version: 1.0.0\n', '`name`');
    });

    test('a name that is not a string', () {
      expectError('name: 3\n', '`name`');
    });

    test('a dependency section is not a map', () {
      expectError('name: app\ndependencies: [a]\n', '`dependencies`');
      expectError('name: app\ndev_dependencies: 3\n', '`dev_dependencies`');
      expectError(
        'name: app\ndependency_overrides: x\n',
        '`dependency_overrides`',
      );
    });

    test('workspace is not a list of strings', () {
      expectError('name: app\nworkspace: packages\n', '`workspace`');
      expectError('name: app\nworkspace:\n  - a: b\n', '`workspace`');
    });
  });
}
