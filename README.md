# flutter_flavor_overrides

Swap a Flutter plugin for a no-op stub in specific flavors — so the plugin's native code
(Android classes, iOS pods or Swift packages) is not in those builds at all.

Flutter has no per-flavor dependencies: every plugin in `pubspec.yaml` ends up in every flavor.
This CLI reads the per-flavor overrides of a project from one `flavor_overrides.yaml` next to its
root `pubspec.yaml` and generates `pubspec_overrides.yaml`, which pub applies on top of
`pubspec.yaml`, for every package of the project that uses an overridden package. Your committed
`pubspec.yaml` files never change.

```yaml
# flavor_overrides.yaml, next to the root pubspec.yaml
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

Put one `flavor_overrides.yaml` next to the root `pubspec.yaml` of the project: the pub workspace
root, the melos root, or the app itself (a single package, or an app with modules through
`path:`). Under each package to swap, the flavors that swap it:

```yaml
<package>:
  <flavor>: <any dependency spec pub accepts>
```

- The value is a normal dependency spec: `path:`, `git:`, a hosted version string, `sdk:`, or empty
  (any version from pub.dev).
- Relative paths are relative to `flavor_overrides.yaml`; the tool rebases them for every file it
  writes.
- A package without an entry for a flavor keeps the real package in that flavor. A typo in a
  flavor name therefore means "no override", not an error (the tool notes it, see
  [Options](#options)).
- Declare an override once: the tool applies it to every package of the project that uses the
  package (see [Where the files go](#where-the-files-go)), so no module can be forgotten.
- An override takes precedence over the same package in a pubspec's own `dependency_overrides`.
  In a pub workspace, a member must not override the same package itself: pub refuses a package
  overridden in two places, so the tool stops with an error instead.
- One file per project: the tool finds it from the directory it runs in, going up, and its
  directory is the project root. A `flavor_overrides.yaml` in another package of the project, or a
  `flavor_overrides` section left in a pubspec, is an error.

Flavor keys are just labels matched against `--flavor`; they don't have to match your Flutter
flavors. To vary overrides by build mode too, use composite keys such as `prodRelease` and
`prodDebug`, and run the tool with the one you build:

```yaml
some_plugin:
  prodRelease: {path: stubs/some_plugin}
  prodDebug: {path: stubs/some_plugin}
network_inspector:
  prodRelease: {path: stubs/network_inspector}
```

```console
$ flutter_flavor_overrides --flavor prodRelease
$ flutter pub get
$ flutter build ipa --release --flavor prod
```

The tool runs before `pub get`, so build mode never reaches it: after switching modes or flavors
locally, run it and `pub get` again.

## Write the stub

The tool does not generate stubs. A stub is a small package that:

- has the **same `name:`** as the plugin;
- exposes the part of the plugin's Dart API your code uses;
- has **no `flutter: plugin:` section** — that is what keeps native code out;
- degrades safely: return a neutral value or take the code path the plugin itself takes when the
  platform side is unavailable, rather than throwing.

The stub is never a participant of its own: not a pub workspace member, not under melos
`packages:` globs (list it under `ignore:` if a glob would catch it), not a `path:` dependency of
anything. Only `flavor_overrides.yaml` points to it, so it joins the resolution only in the flavor
that swaps it — and then it is resolved together with the rest of the project, no separate `pub
get` needed. Run `pub get` inside the stub only to work on it as a package of its own (its tests,
`dart analyze` in its directory). Before writing anything, the tool checks that a `path:` points to
a directory whose `pubspec.yaml` has the package's name.

## What can be swapped

An override replaces where a package name comes from; it does not add a second package. Whether
that works depends on where the real package comes from:

| The real package | Can it be swapped? |
|---|---|
| pub.dev or git (a regular plugin) | Yes. |
| A local package reached through `path:`, no workspace | Yes. |
| A local package that is a **pub workspace member** | **No.** pub refuses to override workspace members ("Cannot override workspace packages"); the tool stops with an error before writing anything. Take the package out of `workspace:` and depend on it through `path:` instead. |
| A local package outside the workspace members, reached through `path:` | Yes. It then resolves on its own for its own tests and analysis. |
| A melos 6 package, linked by melos (no workspace) | Yes, with the stub under `ignore:` in `melos.yaml`. The tool takes the entry over from melos, so the order of the tool and `melos bootstrap` does not matter; after switching back, `melos bootstrap` restores melos's link. |

## Run it

Run the tool **before** `pub get` / `melos bootstrap`, with the same flavor you build, and
**always run `pub get` (or `melos bootstrap`) after it** — also right before a build. `flutter
build` does not notice a changed `pubspec_overrides.yaml`: while `pubspec.lock` is newer than
`pubspec.yaml` it skips its own `pub get` and builds with the previous resolution, real plugin
included.

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

The directory of `flavor_overrides.yaml` is the project root, and the project is what the root
sees: the root package, workspace members (glob entries are expanded), melos packages, and every
local package reached through `path:` dependencies or `path:` overrides. The tool looks for the
file from the directory it runs in upward, so run it from the root or from below it, such as a
workspace member or a melos package. Without a workspace or melos, the root is the app you build
(`example/` in a plugin repository): modules next to it are part of the project, but a run from
one of them does not find the file.

- **Pub workspace:** one `pubspec_overrides.yaml` at the workspace root, with every override a
  package of the workspace uses.
- **No workspace:** one file in every local package that resolves on its own — the app and each
  module reachable through `path:` dependencies — so modules get the override in their own tests
  and analysis too.
- **melos 6 without a workspace:** packages listed under `packages:` in `melos.yaml` are local
  packages too, and dependencies on them by name count, so modules that melos links are covered.
  melos's own entries and the tool's live side by side in the same files.

A package's file gets the override of a package it uses: one that it, or a local package it
reaches, depends on (`dependencies`; `dev_dependencies` only of the package that resolves, in a
workspace of every member), or one its `pubspec.lock` lists, which covers packages that come in
through other packages from pub.dev or git. A package never gets an override of itself. An
override that no package of the project uses is left out with a warning: pub would otherwise pull
the package into the resolution.

The `pubspec.lock` is read when it is there. A module without one (a library that does not commit
it) that uses a package only through a package from pub.dev or git keeps the real package in its
own tests until its first `pub get`; run the tool again after it. App builds are not affected when
the app commits its `pubspec.lock`, as Flutter recommends.

`--clean` works without `flavor_overrides.yaml` too: it then cleans the project found from the
directory it runs in.

### Existing `pubspec_overrides.yaml` files

The tool owns only the entries listed in its marker comment, `# flutter_flavor_overrides: a,b`.
Everything else in the file — entries written by melos, your own entries, comments — is kept. If
another entry already overrides a package the tool needs to override, it stops with an error
naming the file — except an entry melos manages, which the tool takes over (see
[What can be swapped](#what-can-be-swapped)). Whenever the tool writes entries, it also carries over your pubspec's own
`dependency_overrides` (pub ignores them once `pubspec_overrides.yaml` has a `dependency_overrides`
section), except packages the file already overrides. When the tool removes its entries, the
file returns to what it was before; a file left with nothing but what the tool wrote is deleted.

## Options

| Option | |
|---|---|
| `-f, --flavor <name>` | Write the overrides `flavor_overrides.yaml` gives for flavor `<name>`. |
| `--clean` | Remove the entries this tool wrote, in every file. |
| `--dry-run` | Print what would be written or removed; change nothing. |
| `--list-dependents` | Print the local packages that depend on a package overridden in this flavor; change nothing. |
| `-C, --directory <dir>` | Run in `<dir>` instead of the current directory. |

Status lines and `--list-dependents` print paths relative to the directory the tool runs in
(after `-C`); error messages name files by absolute path. If `flavor_overrides.yaml` names the
selected flavor under no package, the tool says so on stderr, suggests close matches and lists the
flavors it found, and still exits `0`:

```console
$ flutter_flavor_overrides --flavor prd
flutter_flavor_overrides: no flavor_overrides for flavor `prd` in this project. Did you mean `prod`? Declared flavors: develop, prod.
```

A flavor that has no overrides, such as `dev`, gets the same note; it only informs.

Exit codes: `0` success, `64` invalid usage, `1` a problem in the project or in
`flavor_overrides.yaml` (the message names the file). Such problems are found before any file is
written, so they leave the project untouched. Warnings (`flutter_flavor_overrides: warning: …`)
do not stop a run: an override no package uses, a `pubspec.lock` that cannot be read, a `path:`
dependency on a directory that does not exist yet.

## Check stubs on pull requests

By default the real package is used, so a stub that drifted from the plugin's API breaks only the
flavor build — usually at release time. Catch it on every PR:

```console
flutter_flavor_overrides --flavor prod
for pkg in $(flutter_flavor_overrides --flavor prod --list-dependents); do
  (cd "$pkg" && flutter pub get && dart analyze --fatal-infos)
done
```

`--list-dependents` lists every local package that depends on a swapped package directly: their
code imports it, so analyze each of them, not only the app.

## Limitations

- In a flavor with overrides, `pubspec.lock` (and `Podfile.lock` on iOS) differ from the committed
  ones. Don't commit lock files from such a run.
- iOS with CocoaPods: switching a working copy locally from a flavor with plugins to one where
  **no** plugin is left can fail with "The sandbox is not in sync with the Podfile.lock" (Flutter
  removes `Pods/Manifest.lock` and skips `pod install` when there are no plugins). Run
  `pod install` in `ios/` once. Fresh checkouts (CI) are not affected.

## How it is tested

Besides unit tests, CI builds real apps through the CLI: a single package, a pub workspace,
`path:` modules without a workspace (on Android, on iOS and macOS with both CocoaPods and Swift
Package Manager, and on Linux desktop) and a melos 6 project (on Android), in a flavor with the
plugin and one with the stub — and checks that the plugin's native code is present in one build and
absent from the other. Windows desktop is not built. See [`e2e/`](e2e/).

## License

MIT
