import 'package:flutter_flavor_overrides/flutter_flavor_overrides.dart';
import 'package:test/test.dart';

import 'support/project_builder.dart';

void main() {
  late ProjectBuilder project;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() {
    project = ProjectBuilder();
    out = StringBuffer();
    err = StringBuffer();
  });
  tearDown(() => project.delete());

  // An empty directory: a usage error must not even look for a project.
  Future<int> cli(List<String> arguments) =>
      run(arguments, workingDirectory: project.root, out: out, err: err);

  test('fails without --flavor', () async {
    expect(await cli(const []), 64);
    expect(err.toString(), contains('--flavor'));
    expect(err.toString(), contains('Usage:'));
    expect(out.toString(), isEmpty);
  });

  test('--help prints the usage and succeeds', () async {
    expect(await cli(['--help']), 0);
    expect(out.toString(), contains('Usage:'));
    expect(out.toString(), contains('--list-dependents'));
    expect(err.toString(), isEmpty);
  });

  test('an unknown option is a usage error', () async {
    expect(await cli(['--flavor', 'prod', '--frobnicate']), 64);
    expect(err.toString(), contains('Usage:'));
  });

  test('a positional argument is a usage error', () async {
    expect(await cli(['--flavor', 'prod', 'extra']), 64);
    expect(err.toString(), contains('extra'));
  });

  test('--clean does not take --flavor or --list-dependents', () async {
    expect(await cli(['--clean', '--flavor', 'prod']), 64);
    expect(await cli(['--clean', '--list-dependents']), 64);
  });

  test('an empty flavor is a usage error', () async {
    expect(await cli(['--flavor', '']), 64);
  });
}
