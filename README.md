# flutter_flavor_overrides

Swap a Flutter plugin for a no-op stub in specific flavors — so the plugin's native code
(Android classes, iOS pods or Swift packages) is not in those builds at all.

Flutter has no per-flavor dependencies: every plugin in `pubspec.yaml` ends up in every flavor.
This CLI reads per-flavor declarations from your pubspec files and generates
`pubspec_overrides.yaml`, which pub applies on top of `pubspec.yaml`. Your committed
`pubspec.yaml` never changes.

```yaml
# pubspec.yaml of the package that uses the plugin
dependencies:
  some_plugin: 1.2.0

flavor_overrides:        # ignored by pub, read by this tool
  prod:
    some_plugin:
      path: ../stubs/some_plugin_no_op
```

```console
$ flutter_flavor_overrides --flavor prod
wrote pubspec_overrides.yaml (some_plugin)
$ flutter pub get
$ flutter build appbundle --release --flavor prod
```

In `prod` the app now resolves `some_plugin` to the stub; Flutter registers no native plugin for
it, so nothing of it is compiled into the Android or iOS build. Every other flavor keeps the real
package.

## Install

```console
dart pub global activate flutter_flavor_overrides
```

Use a global activation (pin the version in CI), not a `dev_dependency`: the tool pins its own
dependencies exactly, and inside your app's resolution those pins can clash with the SDK's — for
example `flutter_test` on Flutter 3.22 pins a different `path` version.

Requires Dart 3.4 or newer to run. Your project needs `pubspec_overrides.yaml` support (Dart 2.17+).

## Declare overrides

Add a top-level `flavor_overrides` section to the pubspec of the package that depends on the
plugin:

```yaml
flavor_overrides:
  <flavor>:
    <package>: <any dependency spec pub accepts>
```

- The value is a normal dependency spec: `path:`, `git:`, a hosted version, `sdk:`.
- Relative paths are relative to the pubspec they are written in; the tool rebases them for the
  file it writes.
- Without a matching section the real package is used. A typo in a flavor name therefore means
  "no override", not an error.
- Declare the override in **every** local package that depends on the plugin, not only in one of
  them: without a workspace each package resolves on its own and only sees declarations it can
  reach. Identical declarations in several pubspecs are merged; different specs for one package
  in one flavor are an error that names every pubspec involved.
- A declaration takes precedence over the same package in that pubspec's own
  `dependency_overrides`. In a pub workspace, a member must not override the same package itself:
  pub refuses a package overridden in two places, so the tool stops with an error instead.

## Write the stub

The tool does not generate stubs. A stub is a small package that:

- has the **same `name:`** as the plugin;
- exposes the part of the plugin's Dart API your code uses;
- has **no `flutter: plugin:` section** — that is what keeps native code out;
- degrades safely: return a neutral value or take the code path the plugin itself takes when the
  platform side is unavailable, rather than throwing.

Keep the stub outside your pub workspace members and outside melos `packages:` globs — two
packages with the same name in one resolution are not allowed.

## Run it

Run the tool **before** `pub get` / `melos bootstrap`, with the same flavor you build. After
switching flavors, run `pub get` (or `melos bootstrap`) again.

```yaml
# GitHub Actions example
env:
  FLAVOR: prod
steps:
  - uses: actions/checkout@v4
  - uses: subosito/flutter-action@v2
    with:
      flutter-version: 3.44.8
  - run: dart pub global activate flutter_flavor_overrides <version>
  - run: dart pub global run flutter_flavor_overrides --flavor "$FLAVOR"
  - run: flutter pub get
  - run: flutter build appbundle --release --flavor "$FLAVOR"
```

Add `pubspec_overrides.yaml` to `.gitignore`. Steps that delete `pubspec_overrides.yaml` must run
before the tool, not after it.

Locally, switching back is the same command with another flavor (or `--clean`): the tool removes
what it wrote.

### Where the files go

- **Pub workspace:** one `pubspec_overrides.yaml` at the workspace root, with declarations from
  the root, every member (glob entries are expanded) and every local `path:` package. Run the tool
  from the root or from any member.
- **No workspace:** one file in every local package that resolves on its own — the app and each
  module reachable through `path:` dependencies — so modules get the override in their own tests
  and analysis too. A package gets a file only if it can reach a declaration. Run the tool from
  the package you build (the app, or `example/` in a plugin repository): only packages reachable
  from it are visited, so `--clean` from a library does not reach an `example/` that depends on
  it.
- **melos 6 without a workspace:** packages listed under `packages:` in `melos.yaml` are local
  packages too, and dependencies on them by name count, so modules that melos links are covered.
  Run the tool from the melos root or from any melos package. melos's own entries and the tool's
  live side by side in the same files.

### Existing `pubspec_overrides.yaml` files

The tool owns only the entries listed in its marker comment, `# flutter_flavor_overrides: a,b`.
Everything else in the file — entries written by melos, your own entries, comments — is kept. If
another entry already overrides a package the tool needs to override, it stops with an error
naming the file. Whenever the tool writes entries, it also carries over your pubspec's own
`dependency_overrides` (pub ignores them once `pubspec_overrides.yaml` has a `dependency_overrides`
section), except packages the file already overrides. When the tool removes its entries, the
file returns to what it was before; a file left with nothing but what the tool wrote is deleted.

## Options

| Option | |
|---|---|
| `-f, --flavor <name>` | Write the overrides declared under `flavor_overrides.<name>`. |
| `--clean` | Remove the entries this tool wrote, in every file. |
| `--dry-run` | Print what would be written or removed; change nothing. |
| `--list-dependents` | Print the local packages that depend on a package overridden in this flavor; change nothing. |
| `-C, --directory <dir>` | Run in `<dir>` instead of the current directory. |

Status lines and `--list-dependents` print paths relative to the directory the tool runs in
(after `-C`); error messages name files by absolute path. If no pubspec
in the project declares the selected flavor, the tool says so on stderr — a typo in `--flavor`
is visible — and still exits `0`.

Exit codes: `0` success, `64` invalid usage, `1` a problem in the project or declarations (the
message names the file). Problems in the project or the declarations are found before any file
is written, so they leave the project untouched.

## Check stubs on pull requests

By default the real package is used, so a stub that drifted from the plugin's API breaks only the
flavor build — usually at release time. Catch it on every PR:

```console
flutter_flavor_overrides --flavor prod
for pkg in $(flutter_flavor_overrides --flavor prod --list-dependents); do
  (cd "$pkg" && flutter pub get && dart analyze --fatal-infos)
done
```

Analyze every dependent, not only the package that declares the override.

## Limitations

- In a flavor with overrides, `pubspec.lock` (and `Podfile.lock` on iOS) differ from the committed
  ones. Don't commit lock files from such a run.
- iOS with CocoaPods: switching a working copy locally from a flavor with plugins to one where
  **no** plugin is left can fail with "The sandbox is not in sync with the Podfile.lock" (Flutter
  removes `Pods/Manifest.lock` and skips `pod install` when there are no plugins). Run
  `pod install` in `ios/` once. Fresh checkouts (CI) are not affected.

## How it is tested

Besides unit tests, CI builds real apps through the CLI: a single package, a pub workspace,
`path:` modules without a workspace (on Android and on iOS with both CocoaPods and Swift Package
Manager) and a melos 6 project (on Android), in a flavor with the plugin and one with the stub — and
checks that the plugin's native code is present in one build and absent from the other. See
[`e2e/`](e2e/).

## License

MIT
