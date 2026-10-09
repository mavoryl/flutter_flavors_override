import 'package:flutter_flavor_overrides/src/errors.dart';
import 'package:flutter_flavor_overrides/src/project.dart';
import 'package:test/test.dart';

import 'support/project_builder.dart';

void main() {
  late ProjectBuilder project;

  setUp(() => project = ProjectBuilder());
  tearDown(() => project.delete());

  /// Absolute dirs of [relative] project paths, for comparing with results.
  List<String> dirs(List<String> relative) => [
        for (final r in relative) project.path(r),
      ];

  Matcher throwsAbout(List<String> fragments) => throwsA(
        isA<FlavorOverridesException>().having(
          (e) => e.message,
          'message',
          allOf([for (final f in fragments) contains(f)]),
        ),
      );

  test('a single package is its own root and resolves on its own', () {
    final app = project.pubspec('app', '''
name: app
dependencies:
  some_plugin: 1.2.0
''');

    final result = Project.discover(app);

    expect(result.mode, ProjectMode.packages);
    expect(result.root.dir, app);
    expect(result.packages.keys, [app]);
    expect(result.resolvingDirs, [app]);
    expect(result.members, isEmpty);
    expect(result.reachableFrom(app), {app});
  });

  group('path modules without a workspace', () {
    test('a chain app → feature → core', () {
      final app = project.pubspec('app', '''
name: app
dependencies:
  feature:
    path: ../packages/feature
''');
      final feature = project.pubspec('packages/feature', '''
name: feature
dependencies:
  core:
    path: ../core
''');
      final core = project.pubspec('packages/core', 'name: core\n');

      final result = Project.discover(app);

      expect(result.mode, ProjectMode.packages);
      expect(result.root.dir, app);
      expect(result.packages.keys, unorderedEquals([app, feature, core]));
      expect(result.packages[core]!.name, 'core');
      expect(result.resolvingDirs,
          dirs(['app', 'packages/core', 'packages/feature']));
      expect(result.localDependencies(app, resolving: true), [feature]);
      expect(result.localDependencies(feature, resolving: false), [core]);
      expect(result.localDependencies(core, resolving: true), isEmpty);
      expect(result.reachableFrom(app), {app, feature, core});
      expect(result.reachableFrom(feature), {feature, core});
      expect(result.reachableFrom(core), {core});
    });

    test('a cycle core ↔ feature terminates', () {
      final app = project.pubspec('app', '''
name: app
dependencies:
  feature:
    path: ../feature
''');
      final feature = project.pubspec('feature', '''
name: feature
dependencies:
  core:
    path: ../core
''');
      final core = project.pubspec('core', '''
name: core
dependencies:
  feature:
    path: ../feature
''');

      final result = Project.discover(app);

      expect(result.packages.keys, unorderedEquals([app, feature, core]));
      expect(result.reachableFrom(core), {core, feature});
      expect(result.reachableFrom(app), {app, feature, core});
    });

    test('a diamond reaches the shared package once, however it is spelled',
        () {
      final app = project.pubspec('app', '''
name: app
dependencies:
  a:
    path: ../a
  b:
    path: ../b/
''');
      project.pubspec('a', '''
name: a
dependencies:
  core:
    path: ../core
''');
      project.pubspec('b', '''
name: b
dependencies:
  core:
    path: ../b/../core/.
''');
      final core = project.path('core');
      project.pubspec('core', 'name: core\n');

      final result = Project.discover(app);

      expect(result.packages.keys,
          unorderedEquals(dirs(['app', 'a', 'b', 'core'])));
      expect(result.localDependencies(project.path('b'), resolving: false),
          [core]);
      expect(
          result.reachableFrom(app), dirs(['app', 'a', 'b', 'core']).toSet());
    });

    test('dev_dependencies count only at the first hop', () {
      final app = project.pubspec('app', '''
name: app
dependencies:
  feature:
    path: ../feature
dev_dependencies:
  app_tools:
    path: ../app_tools
''');
      final feature = project.pubspec('feature', '''
name: feature
dev_dependencies:
  feature_tools:
    path: ../feature_tools
''');
      final appTools = project.pubspec('app_tools', 'name: app_tools\n');
      final featureTools =
          project.pubspec('feature_tools', 'name: feature_tools\n');

      final result = Project.discover(app);

      // Every local package resolves on its own, so a module's dev
      // dependencies are local packages too.
      expect(
        result.packages.keys,
        unorderedEquals([app, feature, appTools, featureTools]),
      );
      expect(result.localDependencies(feature, resolving: false), isEmpty);
      expect(
          result.localDependencies(feature, resolving: true), [featureTools]);
      expect(result.reachableFrom(app), {app, feature, appTools});
      expect(result.reachableFrom(feature), {feature, featureTools});
    });

    test('an absolute path is followed', () {
      final core = project.pubspec('core', 'name: core\n');
      final app = project.pubspec('app', '''
name: app
dependencies:
  core:
    path: $core
''');

      expect(Project.discover(app).reachableFrom(app), {app, core});
    });

    test('a path to a directory without pubspec.yaml is an error', () {
      final app = project.pubspec('app', '''
name: app
dependencies:
  feature:
    path: ../feature
''');
      project.dir('feature');

      expect(
        () => Project.discover(app),
        throwsAbout(
            [project.path('app/pubspec.yaml'), project.path('feature')]),
      );
    });
  });

  group('workspace', () {
    String member(String dir, [String extra = '']) => project.pubspec(
          dir,
          'name: ${dir.split('/').last}\nresolution: workspace\n$extra',
        );

    test('members listed one by one', () {
      final root = project.pubspec('.', '''
name: root
workspace:
  - app
  - packages/feature
''');
      final app = member('app');
      final feature = member('packages/feature');

      final result = Project.discover(root);

      expect(result.mode, ProjectMode.workspace);
      expect(result.root.dir, root);
      expect(result.members, {root, app, feature});
      expect(result.packages.keys, unorderedEquals([root, app, feature]));
      expect(result.resolvingDirs, [root]);
    });

    test('a glob matches directories with pubspec.yaml only', () {
      final root = project.pubspec('.', '''
name: root
workspace:
  - packages/*
  - plugins/*
''');
      final a = member('packages/a');
      final b = member('packages/b');
      project.dir('packages/no_pubspec');
      project.file('packages/README.md', 'not a package');
      member('packages/a/nested');

      final result = Project.discover(root);

      expect(result.members, {root, a, b});
      expect(result.packages.keys, unorderedEquals([root, a, b]));
    });

    test('** matches nested directories', () {
      final root = project.pubspec('.', '''
name: root
workspace:
  - packages/**
''');
      final a = member('packages/a');
      final b = member('packages/group/b');
      project.dir('packages/group/no_pubspec');

      final result = Project.discover(root);

      expect(result.members, {root, a, b});
    });

    test('a literal entry without pubspec.yaml is an error', () {
      final root = project.pubspec('.', '''
name: root
workspace:
  - app
''');
      project.dir('app');

      expect(
        () => Project.discover(root),
        throwsAbout([project.path('pubspec.yaml'), project.path('app')]),
      );
    });

    test('starting from a member finds the root', () {
      final root = project.pubspec('.', '''
name: root
workspace:
  - packages/feature
''');
      project.pubspec('packages', 'name: unrelated\n');
      final feature = member('packages/feature');

      final result = Project.discover(feature);

      expect(result.mode, ProjectMode.workspace);
      expect(result.root.dir, root);
      expect(result.members, {root, feature});
      expect(result.resolvingDirs, [root]);
    });

    test('a member without a root is an error', () {
      project.pubspec('.', '''
name: root
workspace:
  - other
''');
      member('other');
      final feature = member('feature');

      expect(
        () => Project.discover(feature),
        throwsAbout([project.path('feature/pubspec.yaml'), 'workspace']),
      );
    });

    test('a nested workspace belongs to the outer root', () {
      final root = project.pubspec('.', '''
name: root
workspace:
  - sub
''');
      final sub = member('sub', 'workspace:\n  - pkg\n');
      final pkg = member('sub/pkg');

      final result = Project.discover(pkg);

      expect(result.root.dir, root);
      expect(result.members, {root, sub, pkg});
    });

    test('path packages outside the workspace are local packages', () {
      final root = project.pubspec('.', '''
name: root
workspace:
  - app
''');
      final app = member('app', '''
dependencies:
  vendor:
    path: ../vendor
dev_dependencies:
  app_tools:
    path: ../app_tools
''');
      final vendor = project.pubspec('vendor', '''
name: vendor
dependencies:
  core:
    path: ../core
dev_dependencies:
  missing_tools:
    path: ../missing_tools
''');
      final core = project.pubspec('core', 'name: core\n');
      final appTools = project.pubspec('app_tools', 'name: app_tools\n');

      final result = Project.discover(root);

      expect(result.members, {root, app});
      expect(
        result.packages.keys,
        unorderedEquals([root, app, vendor, core, appTools]),
      );
      expect(result.reachableFrom(app), {app, vendor, core, appTools});
      expect(result.reachableFrom(vendor), {vendor, core});
    });

    test('members depend on each other by name', () {
      final root = project.pubspec('.', '''
name: root
workspace:
  - app
  - feature
''');
      final app = member('app', 'dependencies:\n  feature: ^1.0.0\n');
      final feature = member('feature');

      final result = Project.discover(root);

      expect(result.localDependencies(app, resolving: true), [feature]);
      expect(result.reachableFrom(app), {app, feature});
    });
  });

  group('melos packages without a workspace', () {
    late String root;

    setUp(() {
      root = project.pubspec('.', '''
name: root
dev_dependencies:
  melos: 6.3.3
''');
    });

    test('packages come from melos.yaml globs, linked by name', () {
      project.file('melos.yaml', '''
name: root
packages:
  - app
  - packages/*
''');
      final app = project.pubspec('app', '''
name: app
dependencies:
  feature: 0.0.1
''');
      final feature = project.pubspec('packages/feature', 'name: feature\n');
      project.dir('packages/no_pubspec');

      final result = Project.discover(root);

      expect(result.mode, ProjectMode.packages);
      expect(result.root.dir, root);
      expect(result.members, isEmpty);
      expect(result.packages.keys, unorderedEquals([root, app, feature]));
      expect(result.resolvingDirs, dirs(['.', 'app', 'packages/feature']));
      expect(result.localDependencies(app, resolving: false), [feature]);
      expect(result.reachableFrom(app), {app, feature});
      expect(result.reachableFrom(root), {root});
    });

    test('a package found only through path: is not linked by name', () {
      project.file('melos.yaml', 'name: root\npackages:\n  - app\n');
      final app = project.pubspec('app', '''
name: app
dependencies:
  core: ^1.0.0
  feature:
    path: ../feature
''');
      final feature = project.pubspec('feature', '''
name: feature
dependencies:
  core:
    path: ../core
''');
      final core = project.pubspec('core', 'name: core\n');

      final result = Project.discover(root);

      expect(result.packages.keys, unorderedEquals([root, app, feature, core]));
      expect(result.localDependencies(app, resolving: true), [feature]);
      expect(result.localDependencies(feature, resolving: true), [core]);
    });

    test('without melos.yaml nothing is linked by name', () {
      final app = project.pubspec('app', '''
name: app
dependencies:
  feature: 0.0.1
''');
      project.pubspec('feature', 'name: feature\n');

      final result = Project.discover(app);

      expect(result.packages.keys, [app]);
    });

    test('invalid melos.yaml is an error naming it', () {
      project.file('melos.yaml', 'packages: [app\n');

      expect(
        () => Project.discover(root),
        throwsAbout([project.path('melos.yaml')]),
      );
    });

    test('melos.yaml packages must be a list of globs', () {
      project.file('melos.yaml', 'name: root\npackages: app\n');

      expect(
        () => Project.discover(root),
        throwsAbout([project.path('melos.yaml'), '`packages`']),
      );
    });

    test('two melos packages with one name is an error', () {
      project.file('melos.yaml', 'name: root\npackages:\n  - packages/*\n');
      project.pubspec('packages/a', 'name: same\n');
      project.pubspec('packages/b', 'name: same\n');

      expect(
        () => Project.discover(root),
        throwsAbout([
          project.path('packages/a/pubspec.yaml'),
          project.path('packages/b/pubspec.yaml'),
        ]),
      );
    });
  });
}
