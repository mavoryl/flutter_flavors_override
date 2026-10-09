import 'dart:io';

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
      expect(result.localDependencies(app, resolution: app), [feature]);
      expect(result.localDependencies(feature, resolution: app), [core]);
      expect(result.localDependencies(core, resolution: core), isEmpty);
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
      expect(
          result.localDependencies(project.path('b'), resolution: app), [core]);
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
      expect(result.localDependencies(feature, resolution: app), isEmpty);
      expect(result.localDependencies(feature, resolution: feature),
          [featureTools]);
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

    test('a path to a missing directory is skipped with a warning', () {
      // A generated package before code generation, say.
      final app = project.pubspec('app', '''
name: app
dependencies:
  generated:
    path: ../generated
''');

      final result = Project.discover(app);

      expect(result.packages.keys, [app]);
      expect(result.localDependencies(app, resolution: app), isEmpty);
      expect(result.warnings, [
        allOf(
          contains(project.path('app/pubspec.yaml')),
          contains(project.path('generated')),
        ),
      ]);
    });

    test('found packages give no warnings', () {
      final app = project.pubspec('app', 'name: app\n');

      expect(Project.discover(app).warnings, isEmpty);
    });

    group('a path: override', () {
      test('of a dependency replaces its spec', () {
        final app = project.pubspec('app', '''
name: app
dependencies:
  feature: any
  core:
    path: ../core_old
dependency_overrides:
  feature:
    path: ../feature
  core:
    path: ../core
''');
        final feature = project.pubspec('feature', 'name: feature\n');
        final core = project.pubspec('core', 'name: core\n');
        project.pubspec('core_old', 'name: core\n');

        final result = Project.discover(app);

        expect(result.packages.keys, unorderedEquals([app, feature, core]));
        expect(result.reachableFrom(app), {app, feature, core});
      });

      test('applies to a dependency of any package in the resolution', () {
        final app = project.pubspec('app', '''
name: app
dependencies:
  feature:
    path: ../feature
dependency_overrides:
  core:
    path: ../core
''');
        final feature = project.pubspec('feature', '''
name: feature
dependencies:
  core: ^1.0.0
''');
        final core = project.pubspec('core', 'name: core\n');

        final result = Project.discover(app);

        expect(result.packages.keys, unorderedEquals([app, feature, core]));
        expect(result.reachableFrom(app), {app, feature, core});
        // feature resolves on its own, without the overrides of app.
        expect(result.reachableFrom(feature), {feature});
      });

      test('of a package no local package depends on is reached anyway', () {
        // A fork of a package that a hosted dependency depends on.
        final app = project.pubspec('app', '''
name: app
dependencies:
  http: 1.0.0
dependency_overrides:
  http_parser:
    path: ../http_parser
''');
        final fork = project.pubspec('http_parser', 'name: http_parser\n');

        final result = Project.discover(app);

        expect(result.packages.keys, unorderedEquals([app, fork]));
        expect(result.reachableFrom(app), {app, fork});
      });

      test('of a dependency applies in its own resolution only', () {
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
  core: ^1.0.0
dependency_overrides:
  core:
    path: ../core
''');
        final core = project.pubspec('core', 'name: core\n');

        final result = Project.discover(app);

        expect(result.packages.keys, unorderedEquals([app, feature, core]));
        expect(result.reachableFrom(feature), {feature, core});
        expect(result.reachableFrom(app), {app, feature});
      });
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

      expect(result.localDependencies(app, resolution: root), [feature]);
      expect(result.reachableFrom(app), {app, feature});
    });

    test("a member's path: override applies to the whole workspace", () {
      final root = project.pubspec('.', '''
name: root
workspace:
  - app
  - feature
''');
      final app = member('app', '''
dependency_overrides:
  core:
    path: ../core
''');
      final feature = member('feature', 'dependencies:\n  core: ^1.0.0\n');
      final core = project.pubspec('core', 'name: core\n');

      final result = Project.discover(root);

      expect(result.members, {root, app, feature});
      expect(
        result.packages.keys,
        unorderedEquals([root, app, feature, core]),
      );
      expect(result.reachableFrom(feature), {feature, core});
    });
  });

  group('an invalid glob is an error naming the file and the pattern', () {
    test('in workspace:', () {
      final root = project.pubspec('.', '''
name: root
workspace:
  - packages/[
''');

      expect(
        () => Project.discover(root),
        throwsAbout([project.path('pubspec.yaml'), 'packages/[']),
      );
    });

    test('in melos.yaml packages:', () {
      final root = project.pubspec('.', 'name: root\n');
      project.file('melos.yaml', 'name: root\npackages:\n  - packages/[\n');

      expect(
        () => Project.discover(root),
        throwsAbout([project.path('melos.yaml'), 'packages/[']),
      );
    });

    test('in melos.yaml ignore:', () {
      final root = project.pubspec('.', 'name: root\n');
      project.file(
        'melos.yaml',
        'name: root\npackages:\n  - app\nignore:\n  - legacy/[\n',
      );

      expect(
        () => Project.discover(root),
        throwsAbout([project.path('melos.yaml'), 'legacy/[']),
      );
    });
  });

  group('symbolic links', () {
    test('a package reached through an alias is one package', () {
      final app = project.pubspec('app', '''
name: app
dependencies:
  a:
    path: ../a
  b:
    path: ../b
''');
      project.pubspec(
          'a', 'name: a\ndependencies:\n  core:\n    path: ../core\n');
      project.pubspec('b', '''
name: b
dependencies:
  core:
    path: ../links/core_alias
''');
      final core = project.pubspec('core', 'name: core\n');
      project.link('links/core_alias', '../core');

      final result = Project.discover(app);

      expect(result.packages.keys,
          unorderedEquals(dirs(['app', 'a', 'b', 'core'])));
      expect(
          result.localDependencies(project.path('b'), resolution: app), [core]);
      expect(
        result.reachableFrom(project.path('links/core_alias')),
        {core},
      );
    });

    test('a path: link back to the package itself terminates', () {
      final app = project.pubspec('app', '''
name: app
dependencies:
  mirror:
    path: link
''');
      project.link('app/link', '.');

      final result = Project.discover(app);

      expect(result.packages.keys, [app]);
    });

    test('a directory link cycle under a ** glob terminates', () {
      final root = project.pubspec('.', '''
name: root
workspace:
  - packages/**
''');
      final a = project.pubspec(
        'packages/a',
        'name: a\nresolution: workspace\n',
      );
      project.link('packages/a/loop', '..');

      final result = Project.discover(root);

      expect(result.members, {root, a});
    }, timeout: const Timeout(Duration(seconds: 20)));
  }, skip: Platform.isWindows ? 'symbolic links need privileges' : false);

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
      expect(result.localDependencies(app, resolution: root), [feature]);
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
      expect(result.localDependencies(app, resolution: app), [feature]);
      expect(result.localDependencies(feature, resolution: feature), [core]);
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

    test('melos.yaml ignore: globs exclude packages', () {
      project.file('melos.yaml', '''
name: root
packages:
  - packages/**
ignore:
  - packages/legacy
  - packages/experimental_*
''');
      final a = project.pubspec('packages/a', 'name: a\n');
      project.pubspec('packages/legacy', 'name: legacy\n');
      project.pubspec('packages/experimental_x', 'name: experimental_x\n');

      expect(Project.discover(root).packages.keys, unorderedEquals([root, a]));
    });

    test('melos.yaml ignore must be a list of globs', () {
      project.file(
        'melos.yaml',
        'name: root\npackages:\n  - app\nignore: app\n',
      );

      expect(
        () => Project.discover(root),
        throwsAbout([project.path('melos.yaml'), '`ignore`']),
      );
    });

    test("melos's default exclusions apply to directories", () {
      // packages/** matches every one of these, as it does for melos.
      project.file('melos.yaml', 'name: root\npackages:\n  - packages/**\n');
      final app = project.pubspec('packages/app', 'name: app\n');
      project.pubspec('packages/app/ios/.symlinks/plugins/a', 'name: a\n');
      project.pubspec(
        'packages/app/macos/Flutter/ephemeral/.symlinks/plugins/b',
        'name: b\n',
      );
      project.pubspec(
        'packages/app/linux/flutter/ephemeral/.plugin_symlinks/c',
        'name: c\n',
      );
      project.pubspec('packages/app/.dart_tool/d', 'name: d\n');
      project.pubspec('packages/.fvm/flutter_sdk/packages/e', 'name: e\n');

      expect(
        Project.discover(root).packages.keys,
        unorderedEquals([root, app]),
      );
    });

    group('directory links', () {
      test('plugin links into the pub cache are not packages', () {
        project.file('melos.yaml', 'name: root\npackages:\n  - packages/**\n');
        final app = project.pubspec('packages/app', 'name: app\n');
        // What a local iOS, macOS or Linux build leaves: absolute links into
        // the pub cache, outside the repository.
        final plugin = project.pubspec('pub_cache/plugin', 'name: plugin\n');
        project.pubspec('pub_cache/plugin/example', 'name: plugin_example\n');
        project.link('packages/app/ios/.symlinks/plugins/plugin', plugin);
        project.link(
          'packages/app/linux/flutter/ephemeral/.plugin_symlinks/plugin',
          plugin,
        );

        final result = Project.discover(app);

        expect(result.root.dir, root);
        expect(result.packages.keys, unorderedEquals([root, app]));
      });

      test('a ** glob follows them, as melos does', () {
        project.file('melos.yaml', 'name: root\npackages:\n  - packages/**\n');
        final core = project.pubspec('vendor/shared/core', 'name: core\n');
        project.link('packages/shared', project.path('vendor/shared'));

        expect(
          Project.discover(root).packages.keys,
          unorderedEquals([root, core]),
        );
      });

      test('a link cycle under a ** glob terminates', () {
        project.file('melos.yaml', 'name: root\npackages:\n  - packages/**\n');
        final a = project.pubspec('packages/a', 'name: a\n');
        project.link('packages/a/loop', '..');

        expect(
          Project.discover(root).packages.keys,
          unorderedEquals([root, a]),
        );
      }, timeout: const Timeout(Duration(seconds: 20)));
    }, skip: Platform.isWindows ? 'symbolic links need privileges' : false);

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

    group('starting from a package', () {
      test('one of the melos packages finds the melos root', () {
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

        final result = Project.discover(app);

        expect(result.mode, ProjectMode.packages);
        expect(result.root.dir, root);
        expect(result.members, isEmpty);
        expect(result.packages.keys, unorderedEquals([root, app, feature]));
        expect(result.resolvingDirs, dirs(['.', 'app', 'packages/feature']));
        expect(result.localDependencies(app, resolution: root), [feature]);
      });

      test('not one of the melos packages is its own root', () {
        project.file('melos.yaml', 'name: root\npackages:\n  - app\n');
        project.pubspec('app', 'name: app\n');
        final tool = project.pubspec('tool', '''
name: tool
dependencies:
  app: 0.0.1
''');

        final result = Project.discover(tool);

        expect(result.root.dir, tool);
        expect(result.packages.keys, [tool]);
      });

      test('melos.yaml without pubspec.yaml next to it is an error naming it',
          () {
        project.file('repo/melos.yaml', 'name: repo\npackages:\n  - app\n');
        final app = project.pubspec('repo/app', 'name: app\n');

        expect(
          () => Project.discover(app),
          throwsAbout([project.path('repo/melos.yaml'), 'pubspec.yaml']),
        );
      });

      test('the nearest melos.yaml wins', () {
        project.file('melos.yaml', 'name: root\npackages:\n  - repo/app\n');
        final repo = project.pubspec('repo', 'name: repo\n');
        project.file('repo/melos.yaml', 'name: repo\npackages:\n  - app\n');
        final app = project.pubspec('repo/app', 'name: app\n');

        final result = Project.discover(app);

        expect(result.root.dir, repo);
        expect(result.packages.keys, unorderedEquals([repo, app]));
      });

      test('the nearest melos.yaml not listing it ends the search', () {
        project.file('melos.yaml', 'name: root\npackages:\n  - repo/app\n');
        project.pubspec('repo', 'name: repo\n');
        project.file('repo/melos.yaml', 'name: repo\npackages:\n  - other\n');
        final app = project.pubspec('repo/app', 'name: app\n');

        final result = Project.discover(app);

        expect(result.root.dir, app);
        expect(result.packages.keys, [app]);
      });

      test('a melos root with a pub workspace is not its root', () {
        project.pubspec('.', 'name: root\nworkspace:\n  - packages/*\n');
        project.file('melos.yaml', 'name: root\npackages:\n  - app\n');
        final app = project.pubspec('app', 'name: app\n');

        final result = Project.discover(app);

        expect(result.mode, ProjectMode.packages);
        expect(result.root.dir, app);
        expect(result.packages.keys, [app]);
      });

      test('a workspace member keeps its workspace root', () {
        project.pubspec('.', 'name: root\nworkspace:\n  - packages/*\n');
        // A melos root nearer than the workspace root, listing the member.
        project.pubspec('packages', 'name: packages\n');
        project.file('packages/melos.yaml', 'name: p\npackages:\n  - "*"\n');
        final feature = project.pubspec(
          'packages/feature',
          'name: feature\nresolution: workspace\n',
        );

        final result = Project.discover(feature);

        expect(result.mode, ProjectMode.workspace);
        expect(result.root.dir, root);
        expect(result.members, {root, feature});
      });
    });
  });
}
