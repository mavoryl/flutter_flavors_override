import 'dart:io';

import 'package:flutter_flavor_overrides/flutter_flavor_overrides.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The e2e fixtures (see e2e/README.md): for each flavor, the CLI must write
/// exactly the golden files under `e2e/<fixture>/expected/<flavor>/`, the
/// ones the e2e builds prove right. No `expected/<flavor>/`: no files.
void main() {
  final e2e = p.join(Directory.current.path, 'e2e');
  // Not fixtures: what the fixtures share.
  const shared = {'plugins', 'stubs', 'tool'};
  final fixtures = [
    for (final entity in Directory(e2e).listSync())
      if (entity is Directory && !shared.contains(p.basename(entity.path)))
        p.basename(entity.path),
  ]..sort();

  test('the fixtures are found', () {
    expect(fixtures, containsAll(['single', 'workspace', 'path_modules']));
    for (final fixture in fixtures) {
      expect(
        _overridesFiles(p.join(e2e, fixture, 'expected', 'prod')),
        isNotEmpty,
        reason: '$fixture has golden files for prod',
      );
    }
  });

  late String temp;

  setUp(() {
    temp = Directory.systemTemp
        .createTempSync('flutter_flavor_overrides_e2e_')
        .resolveSymbolicLinksSync();
  });
  tearDown(() => Directory(temp).deleteSync(recursive: true));

  for (final fixture in fixtures) {
    for (final flavor in ['dev', 'prod']) {
      test('$fixture: --flavor $flavor writes expected/$flavor/', () async {
        // The fixture next to plugins/ and stubs/, so relative paths hold.
        for (final dir in [fixture, ...shared]) {
          _copyManifests(p.join(e2e, dir), p.join(temp, dir));
        }
        final copy = p.join(temp, fixture);
        // The app, or the root of a workspace or a melos repository.
        final start = File(p.join(copy, 'pubspec.yaml')).existsSync()
            ? copy
            : p.join(copy, 'app');
        final out = StringBuffer();
        final err = StringBuffer();

        final code = await run(
          ['--flavor', flavor],
          workingDirectory: start,
          out: out,
          err: err,
        );

        // The fixtures declare prod only; the CLI notes that dev has nothing.
        expect(
          err.toString(),
          flavor == 'prod'
              ? isEmpty
              : 'flutter_flavor_overrides: no flavor_overrides for flavor '
                  '`$flavor` in this project\n',
        );
        expect(code, 0, reason: out.toString());
        expect(
          _overridesFiles(copy),
          _overridesFiles(p.join(e2e, fixture, 'expected', flavor)),
        );
      });
    }
  }
}

/// Directories that hold no package manifest of a fixture: generated output,
/// native projects, golden files.
const _skipped = {'build', 'expected', 'android', 'ios'};

/// Copies every pubspec.yaml and melos.yaml under [from] to the same place
/// under [to]. Overrides files are left out: the CLI starts from none.
void _copyManifests(String from, String to) {
  for (final entity in Directory(from).listSync(followLinks: false)) {
    final name = p.basename(entity.path);
    if (entity is Directory) {
      if (name.startsWith('.') || _skipped.contains(name)) continue;
      _copyManifests(entity.path, p.join(to, name));
    } else if (entity is File &&
        (name == 'pubspec.yaml' || name == 'melos.yaml')) {
      Directory(to).createSync(recursive: true);
      entity.copySync(p.join(to, name));
    }
  }
}

/// Every pubspec_overrides.yaml under [root], outside `expected/`: its path
/// relative to [root] (with `/`) → its content. Empty when [root] is missing.
Map<String, String> _overridesFiles(String root) {
  if (!Directory(root).existsSync()) return {};
  final files = <String, String>{};
  for (final entity in Directory(root).listSync(
    recursive: true,
    followLinks: false,
  )) {
    final relative = p.split(p.relative(entity.path, from: root));
    if (entity is File &&
        relative.last == 'pubspec_overrides.yaml' &&
        !relative.contains('expected')) {
      files[p.posix.joinAll(relative)] = entity.readAsStringSync();
    }
  }
  return files;
}
