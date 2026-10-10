# flutter_flavor_overrides

A CLI that gives Flutter flavors their own dependencies. It writes `pubspec_overrides.yaml`, so
your `pubspec.yaml` files never change.

Flutter has no per-flavor dependencies: every plugin in `pubspec.yaml` ends up in every flavor.
The typical case is a plugin that must not ship in one flavor. Swap it for a no-op stub there, and
none of its native code (Android classes, CocoaPods pods or Swift packages) is built into that
flavor.

## How it works

1. List the overrides per flavor in `flavor_overrides.yaml`, next to the root `pubspec.yaml`.
2. Run `flutter_flavor_overrides --flavor <flavor>`. It writes the overrides of that flavor into
   `pubspec_overrides.yaml` of every package in the project that uses an overridden package.
3. Run `flutter pub get`. pub applies `pubspec_overrides.yaml` on top of `pubspec.yaml`, and the
   build gets the swapped packages.

```yaml
# flavor_overrides.yaml
some_plugin:
  prod:
    path: stubs/some_plugin_no_op
```

```console
$ flutter_flavor_overrides --flavor prod
wrote pubspec_overrides.yaml (some_plugin)
$ flutter pub get
$ flutter build appbundle --release --flavor prod
```

In `prod`, `some_plugin` resolves to the stub; other flavors keep the real plugin. A run with
another flavor, or with `--clean`, removes what the tool wrote.

## Install

```console
dart pub global activate flutter_flavor_overrides
```

Install it globally, not as a `dev_dependency`: the tool pins its dependencies to exact versions,
which can clash with the Flutter SDK's inside your app. Pin the version in CI. Requires Dart 3.4
or newer.

## flavor_overrides.yaml

One file per project, next to the root `pubspec.yaml`: the pub workspace root, the melos root, or
the app. The tool looks for it from the current directory upward, so run it from the root or
below.

```yaml
<package>:
  <flavor>: <dependency spec>
```

- A spec is anything pub accepts in `dependency_overrides`: `path:`, `git:`, `hosted:`, `sdk:`, a
  version, or empty (any version from pub.dev).
- Relative paths are relative to `flavor_overrides.yaml`.
- A flavor without an entry keeps the real package.
- Flavors are labels matched against `--flavor`. To vary overrides by build mode, use keys such as
  `prodRelease` and `prodDebug` and pass the one you build: `--flavor prodRelease`.

## The stub

The tool does not generate stubs. A stub is a package that:

- has the same `name:` as the plugin;
- implements the part of the plugin's Dart API your code uses, returning neutral values instead of
  throwing;
- has no `flutter: plugin:` section, which is what keeps the native code out.

Only `flavor_overrides.yaml` points to the stub. It is not a pub workspace member, not matched by
melos `packages:` (list it under `ignore:`), and not a `path:` dependency of anything.

A stub that drifts from the plugin's API breaks only the flavor build. To catch that on pull
requests, analyze every package that imports a swapped package:

```console
flutter_flavor_overrides --flavor prod
for pkg in $(flutter_flavor_overrides --flavor prod --list-dependents); do
  (cd "$pkg" && flutter pub get && dart analyze --fatal-infos)
done
```

## Running it

Run the tool before `pub get` or `melos bootstrap`, with the flavor you build. Always run
`pub get` after it, also right before a build: while `pubspec.lock` is newer than `pubspec.yaml`,
`flutter build` skips its own `pub get` and builds with the previous resolution.

```yaml
# GitHub Actions
- run: dart pub global activate flutter_flavor_overrides <version>
- run: dart pub global run flutter_flavor_overrides --flavor prod
- run: flutter pub get
- run: flutter build appbundle --release --flavor prod
```

Add `pubspec_overrides.yaml` to `.gitignore`.

With melos 7 or later, a `bootstrap` pre hook runs the tool on every `melos bootstrap`:

```yaml
# pubspec.yaml at the workspace root
melos:
  command:
    bootstrap:
      hooks:
        pre: dart pub global run flutter_flavor_overrides --flavor "${FLAVOR:-dev}"
```

```console
$ FLAVOR=prod melos bootstrap
```

The hook is an `sh` command; on Windows, call a script instead. It does not run on a plain
`flutter pub get`.

## Which files it writes

- **Pub workspace:** one `pubspec_overrides.yaml` at the workspace root.
- **No workspace, with or without melos 6:** one file in every local package that resolves on its
  own (the app, its `path:` modules, packages melos links), so modules get the override in their
  own tests too.

A package gets an override when it uses the overridden package: depends on it directly or through
a local package, or lists it in its `pubspec.lock`. An override that no package uses is skipped
with a warning.

The tool owns only the entries named in its marker comment, `# flutter_flavor_overrides: a,b`;
everything else in the file is kept. Another entry for the same package is an error, except one
managed by melos 6, which the tool takes over. When the tool writes, it also copies the pubspec's
own `dependency_overrides` into the file, because pub ignores them once `pubspec_overrides.yaml`
has a `dependency_overrides` section. Removing its entries restores the file, or deletes it if
nothing else is left.

## Options

| Option | |
|---|---|
| `-f, --flavor <name>` | Write the overrides of flavor `<name>`. |
| `--clean` | Remove the entries the tool wrote, in every file. |
| `--dry-run` | Print what would change; change nothing. |
| `--list-dependents` | Print the local packages that depend on a package swapped in this flavor. |
| `-C, --directory <dir>` | Run in `<dir>` instead of the current directory. |

A flavor with no overrides is not an error. The tool prints a note and exits `0`:

```console
$ flutter_flavor_overrides --flavor prd
flutter_flavor_overrides: no flavor_overrides for flavor `prd` in this project. Did you mean `prod`? Declared flavors: develop, prod.
```

Exit codes: `0` success, `64` invalid usage, `1` an error in the project or in
`flavor_overrides.yaml`. Errors are found before any file is written.

## Limitations

- A pub workspace member cannot be swapped: pub refuses to override workspace packages, so the
  tool stops with an error. Depend on such a package through `path:` instead of listing it in
  `workspace:`.
- Do not commit `pubspec.lock` or `Podfile.lock` from a run with overrides.
- CocoaPods: locally switching to a flavor where no plugin is left can fail with "The sandbox is
  not in sync with the Podfile.lock". Run `pod install` in `ios/` once.
- A module without its own `pubspec.lock` that gets a package only through a package from pub.dev
  or git keeps the real package in its own tests until its first `pub get`. Run the tool again
  after it.

## License

MIT
