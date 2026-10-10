#!/usr/bin/env bash
# Builds one e2e fixture for one platform and flavor, then checks whether the
# native code of the ffo_probe plugin made it into the build: `dev` must have
# it, `prod` must not (there ffo_probe resolves to its no-op stub).
#
# Usage:
#   e2e/tool/verify.sh [options] \
#       <single|workspace|path_modules|melos6|melos6_local> \
#       <android|ios-cocoapods|ios-spm|macos-cocoapods|macos-spm|linux> \
#       <dev|prod>
#
# Options:
#   --golden         lay out the golden files from <fixture>/expected/<flavor>/
#                    instead of running the CLI (not for melos6_local)
#   --no-overrides   a negative control, `prod` must then FAIL: run the CLI
#                    with --clean instead of --flavor (with --golden: lay out
#                    nothing)
#   --keep           keep the temporary copy (its path is printed)
#   --workdir DIR    reuse a copy kept by an earlier run instead of making a
#                    new one (no `flutter clean`: a local switch of flavors)
#   --logs DIR       write pub and build logs to DIR (default: <copy>/logs)
#
# The fixture is never built in place. The script copies e2e/ (tracked and
# untracked-but-not-ignored files, as in a fresh checkout) to a temporary
# directory and runs the CLI of this repository in the copy, `dart
# --packages=<repo>/.dart_tool/package_config.json
# <repo>/bin/flutter_flavor_overrides.dart --flavor <flavor>`, from the app or
# from the root of the workspace or melos repository. With --golden
# it removes every pubspec_overrides.yaml in the copy instead and lays out the
# golden files (the same tree as the fixture). For iOS and macOS it sets
# `flutter: config: enable-swift-package-manager:` in the copy of the app's
# pubspec, so the machine's global `flutter config` does not matter. Then
# `flutter pub get` (melos6, melos6_local: `dart run melos bootstrap`),
# `flutter build`, and the checks, one PASS/FAIL line each. Flutter has no
# flavors on Linux: there the flavor only picks the overrides, and the build
# gets no --flavor.
#
# melos6 switches flavors in one copy, the way a developer does: first the
# other flavor, then <flavor>, each with the CLI, `melos bootstrap`, the build
# and the checks. Android only: on iOS, going from dev to prod in one copy
# needs a manual `pod install` when prod has no plugin left (e2e/README.md).
#
# melos6_local, where ffo_probe itself is a melos package, starts with `melos
# bootstrap`, which links the plugin, then runs <flavor>, the other flavor and
# <flavor> again in one copy: the first with the CLI, `flutter pub get` in the
# app only and the build, the others with the CLI, `melos bootstrap` and the
# build; each with the checks. Android only, like melos6.
#
# Exit code: 0 only if every build succeeded and every check passed.
#
# Needs: flutter and dart on PATH, git, tar, unzip, strings. The CLI needs
# `dart pub get` in the repository; the script runs it when it is missing.
# Android: an Android SDK with build-tools (dexdump, aapt2) in $ANDROID_HOME,
# $ANDROID_SDK_ROOT, ~/Library/Android/sdk or ~/Android/Sdk. iOS and macOS:
# Xcode and CocoaPods. Linux: what Flutter's Linux desktop builds need (clang,
# cmake, ninja, pkg-config, the GTK 3 headers).

set -euo pipefail

usage() {
  awk '/^# Usage:/ { p = 1 } /^# The fixture is never/ { exit } p' "$0" |
    sed 's/^# \{0,1\}//' >&2
  exit 2
}

keep=0
workdir=''
golden=0
no_overrides=0
logs=''
while [[ $# -gt 0 ]]; do
  case $1 in
    --golden) golden=1 ;;
    --no-overrides) no_overrides=1 ;;
    --keep) keep=1 ;;
    --workdir) workdir=${2:?--workdir needs a directory}; shift ;;
    --logs) logs=${2:?--logs needs a directory}; shift ;;
    -h | --help) usage ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) break ;;
  esac
  shift
done
[[ $# -eq 3 ]] || usage
structure=$1 platform=$2 flavor=$3
case $structure in single | workspace | path_modules | melos6 | melos6_local) ;; *) usage ;; esac
case $platform in
  android | ios-cocoapods | ios-spm | macos-cocoapods | macos-spm | linux) ;;
  *) usage ;;
esac
case $flavor in dev | prod) ;; *) usage ;; esac
melos=0
[[ $structure == melos6 || $structure == melos6_local ]] && melos=1
if [[ $melos -eq 1 && $platform != android ]]; then
  echo "$structure runs on android only" >&2
  exit 2
fi
if [[ $structure == melos6_local && $golden -eq 1 ]]; then
  # Laying out the golden files removes melos's links, which the first build
  # needs.
  echo "melos6_local runs the CLI over the files of melos: no --golden" >&2
  exit 2
fi
# os: android, ios, macos or linux. spm: the dependency manager on iOS and
# macOS, Swift Package Manager (true) or CocoaPods (false).
os=${platform%%-*}
spm=''
case $platform in
  *-cocoapods) spm=false ;;
  *-spm) spm=true ;;
esac

# --- the copy -----------------------------------------------------------------

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
if [[ -n $workdir ]]; then
  work=$(cd "$workdir" && pwd)
  [[ -d $work/e2e/$structure ]] || { echo "no e2e/$structure in $work" >&2; exit 2; }
  keep=1
else
  tmp=${TMPDIR:-/tmp}
  work=$(mktemp -d "${tmp%/}/ffo-e2e.XXXXXX")
  git -C "$repo" ls-files -z --cached --others --exclude-standard -- e2e |
    (cd "$repo" && tar --null -T - -cf -) | tar -xf - -C "$work"
fi
cleanup() {
  if [[ $keep -eq 1 ]]; then
    echo "copy kept: $work"
  else
    rm -rf -- "${work:?}"
  fi
}
trap cleanup EXIT

logs=${logs:-$work/logs}
mkdir -p "$logs"
logs=$(cd "$logs" && pwd)

fixture=$work/e2e/$structure
# app: the app to build. cli_dir: where a developer runs the CLI. pub_roots:
# the packages that resolve on their own.
case $structure in
  single) app=$fixture; cli_dir=$fixture; pub_roots=("$fixture") ;;
  workspace) app=$fixture/app; cli_dir=$fixture; pub_roots=("$fixture") ;;
  path_modules | melos6 | melos6_local)
    app=$fixture/app
    cli_dir=$fixture
    [[ $structure == path_modules ]] && cli_dir=$app
    pub_roots=("$fixture/app" "$fixture/packages/feature")
    ;;
esac

# melos6 first builds the other flavor in the same copy; melos6_local builds
# <flavor>, the other one, then <flavor> again.
other=dev
[[ $flavor == dev ]] && other=prod
case $structure in
  melos6) flavors=("$other" "$flavor") ;;
  melos6_local) flavors=("$flavor" "$other" "$flavor") ;;
  *) flavors=("$flavor") ;;
esac

echo "== $structure $platform $flavor (copy: $work)"

# --- overrides ----------------------------------------------------------------

# Runs the CLI of this repository in cli_dir with ARGS, printing its output.
cli() {
  local config=$repo/.dart_tool/package_config.json log=$logs/cli-pub-get.log
  if [[ ! -f $config ]]; then
    if ! (cd "$repo" && dart pub get) >"$log" 2>&1; then
      echo "FAIL  dart pub get in the repository (log: $log)"
      tail -n 20 "$log"
      exit 1
    fi
  fi
  echo "   flutter_flavor_overrides $*"
  # An explicit --packages: `dart run <file>` would first resolve the package
  # in the current directory, i.e. run `pub get` in the fixture before the
  # overrides exist.
  local out status=0
  out=$(cd "$cli_dir" && dart --packages="$config" "$repo/bin/flutter_flavor_overrides.dart" "$@" 2>&1) || status=$?
  sed 's/^/     /' <<<"$out"
  if [[ $status -ne 0 ]]; then
    echo "FAIL  flutter_flavor_overrides $* exited with $status"
    exit 1
  fi
}

# overrides FLAVOR: the pubspec_overrides.yaml files for FLAVOR.
overrides() {
  local f=$1
  if [[ $golden -eq 0 ]]; then
    if [[ $no_overrides -eq 1 ]]; then
      echo "   --no-overrides: none of ours"
      cli --clean
    else
      cli --flavor "$f"
    fi
    return
  fi
  # Golden files: start from no overrides at all.
  find "$fixture" -name pubspec_overrides.yaml -not -path "$fixture/expected/*" -print |
    while IFS= read -r file; do
      rm -- "$file"
      echo "   removed ${file#"$fixture"/}"
    done
  local expected=$fixture/expected/$f
  if [[ $no_overrides -eq 1 ]]; then
    echo "   --no-overrides: expected/$f/ not laid out"
  elif [[ -d $expected ]]; then
    (cd "$expected" && find . -name pubspec_overrides.yaml) | sort |
      while IFS= read -r rel; do
        rel=${rel#./}
        cp -- "$expected/$rel" "$fixture/$rel"
        echo "   placed $rel"
      done
  else
    echo "   no expected/$f/: no overrides"
  fi
}

# --- dependency manager on iOS and macOS ----------------------------------------

# Lines this script adds end with "# verify.sh", so a reused copy can drop them.
pubspec=$app/pubspec.yaml
awk '!/# verify\.sh$/' "$pubspec" >"$pubspec.tmp" && mv "$pubspec.tmp" "$pubspec"
if [[ -n $spm ]]; then
  grep -q '^flutter:$' "$pubspec" || { echo "no 'flutter:' block in $pubspec" >&2; exit 2; }
  awk -v spm="$spm" '
    { print }
    /^flutter:$/ {
      print "  config: # verify.sh"
      print "    enable-swift-package-manager: " spm " # verify.sh"
    }' "$pubspec" >"$pubspec.tmp" && mv "$pubspec.tmp" "$pubspec"
  echo "   app pubspec: flutter: config: enable-swift-package-manager: $spm"
fi

# --- pub get and build ----------------------------------------------------------

# resolve TAG: dependencies of every package that resolves on its own.
resolve() {
  local tag=$1 root log
  if [[ $melos -eq 1 ]]; then
    log=$logs/$tag-melos-bootstrap.log
    echo "   dart run melos bootstrap (log: $log)"
    if ! (cd "$fixture" && dart run melos bootstrap) >"$log" 2>&1; then
      echo "FAIL  melos bootstrap (log: $log)"
      tail -n 20 "$log"
      exit 1
    fi
    return
  fi
  for root in "${pub_roots[@]}"; do
    pub_get "$tag" "$root"
  done
}

# pub_get TAG ROOT: `flutter pub get` in ROOT.
pub_get() {
  local log=$logs/$1-pub-get-${2##*/}.log
  if ! (cd "$2" && flutter pub get) >"$log" 2>&1; then
    echo "FAIL  flutter pub get in ${2#"$work"/} (log: $log)"
    tail -n 20 "$log"
    exit 1
  fi
}

# build TAG FLAVOR
build() {
  local tag=$1 f=$2 log=$logs/$1-build.log started=$SECONDS command
  case $platform in
    android) command=(flutter build apk --release --flavor "$f") ;;
    ios-*) command=(flutter build ios --release --flavor "$f" --no-codesign) ;;
    macos-*) command=(flutter build macos --release --flavor "$f") ;;
    # No flavors on Linux: the flavor only picked the overrides.
    linux) command=(flutter build linux --release) ;;
  esac
  echo "   ${command[*]} (log: $log)"
  if ! (cd "$app" && "${command[@]}") >"$log" 2>&1; then
    echo "FAIL  build (log: $log)"
    tail -n 30 "$log"
    exit 1
  fi
  echo "   built in $((SECONDS - started))s"
}

# --- checks -------------------------------------------------------------------

failures=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }

# The plugin's native code is expected in dev and must be absent in prod.
want=''

# probe NAME COMMAND...: COMMAND succeeds when the plugin is found.
probe() {
  local name=$1 got=absent
  shift
  if "$@"; then got=present; fi
  if [[ $got == "$want" ]]; then pass "$name: $got"; else fail "$name: $got, want $want"; fi
}
# require NAME COMMAND...: an invariant that does not depend on the flavor.
require() {
  local name=$1
  shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}
has() { [[ -f $2 ]] && grep -q -- "$1" "$2"; }
lacks() { ! has "$@"; }
starts_with() { [[ -f $2 ]] && [[ $(head -n 1 "$2") == "$1"* ]]; }
# lists NAME LIST: the comma-separated LIST has NAME; unlists: it has not.
lists() { [[ ,$2, == *,"$1",* ]]; }
unlists() { ! lists "$@"; }
ends_with() { [[ $2 == *"$1" ]]; }
# lists_plugin SECTION FILE: the SECTION list (android, ios, macos, linux) of
# a .flutter-plugins-dependencies has ffo_probe. Its entries are flat objects.
lists_plugin() {
  local list
  [[ -f $2 ]] && list=$(grep -oE "\"$1\":\[(\{[^{}]*\},?)*\]" "$2") &&
    [[ $list == *'"name":"ffo_probe"'* ]]
}
# cmake_lists_plugin FILE: FLUTTER_PLUGIN_LIST in a generated_plugins.cmake
# has ffo_probe.
cmake_lists_plugin() {
  local list
  [[ -f $1 ]] && list=$(awk '/^list\(APPEND FLUTTER_PLUGIN_LIST$/ { p = 1; next } p && /^\)/ { p = 0 } p' "$1") &&
    grep -qx '  ffo_probe' <<<"$list"
}

# A string that only the plugin's native code for macOS or Linux has.
marker=ffo_probe_native_marker_$os

# The Android SDK: $ANDROID_HOME, $ANDROID_SDK_ROOT, or the default location of
# Android Studio on macOS or Linux.
android_sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
if [[ -z $android_sdk ]]; then
  for dir in "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
    if [[ -d $dir ]]; then android_sdk=$dir; break; fi
  done
fi

# Prints the newest build-tools directory with dexdump and aapt2.
android_tools() {
  local dir tools=''
  while IFS= read -r dir; do
    if [[ -x $dir/dexdump && -x $dir/aapt2 ]]; then tools=$dir; fi
  done < <(find "${android_sdk:-/nonexistent}/build-tools" -mindepth 1 -maxdepth 1 2>/dev/null | sort -V)
  [[ -n $tools ]] && echo "$tools"
}

# The packages whose resolution `check` looks at: pub_roots, or the app alone
# when only the app has resolved since the CLI ran.
checked_roots=("${pub_roots[@]}")

# check FLAVOR
check() {
  local f=$1 root config uri got name
  if [[ $f == dev ]]; then want=present; else want=absent; fi

  # 1. Resolution: which ffo_probe pub picked, in every package that resolves.
  for root in "${checked_roots[@]}"; do
    config=$root/.dart_tool/package_config.json
    uri=$({ grep -A1 '"name": "ffo_probe"' "$config" || true; } | sed -n 's/.*"rootUri": "\(.*\)".*/\1/p')
    case $uri in
      */plugins/ffo_probe | */plugins/ffo_probe/) got=present ;;
      */stubs/ffo_probe | */stubs/ffo_probe/) got=absent ;;
      *) got="unexpected rootUri '$uri'" ;;
    esac
    name="pub: ffo_probe in ${config#"$work"/} is $uri"
    if [[ $got == "$want" ]]; then pass "$name"; else fail "$name, want the $([[ $want == present ]] && echo plugin || echo stub)"; fi
  done

  # melos: its entries and ours share the app's file; melos's marker stays first.
  if [[ $melos -eq 1 ]]; then
    local file=$app/pubspec_overrides.yaml
    require "melos: app/pubspec_overrides.yaml starts with melos's marker" \
      starts_with '# melos_managed_dependency_overrides: ' "$file"
    if [[ $f == prod ]]; then
      require "melos: app/pubspec_overrides.yaml has our marker too" \
        has '^# flutter_flavor_overrides: ffo_probe$' "$file"
    else
      require "melos: app/pubspec_overrides.yaml has no marker of ours" \
        lacks '^# flutter_flavor_overrides:' "$file"
    fi
    # melos6_local: melos links ffo_probe as well; in prod the CLI has taken
    # that entry over, out of melos's marker into ours.
    if [[ $structure == melos6_local ]]; then
      local names
      names=$(sed -n 's/^# melos_managed_dependency_overrides: //p' "$file" | head -n 1)
      if [[ $f == prod ]]; then
        require "melos: its marker ($names) does not list ffo_probe" unlists ffo_probe "$names"
      else
        require "melos: its marker ($names) lists ffo_probe" lists ffo_probe "$names"
      fi
    fi
    uri=$({ grep -A1 '"name": "feature"' "$app/.dart_tool/package_config.json" || true; } |
      sed -n 's/.*"rootUri": "\(.*\)".*/\1/p')
    require "melos: app resolves feature to packages/feature ($uri)" \
      ends_with /packages/feature "${uri%/}"
  fi

  # 2. Flutter's plugin list. Flutter deletes the file when there are no plugins.
  local deps=$app/.flutter-plugins-dependencies
  probe ".flutter-plugins-dependencies lists ffo_probe for $os" lists_plugin "$os" "$deps"

  # 3. The generated registrant.
  local registrant
  case $os in
    android) registrant=$app/android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java ;;
    ios) registrant=$app/ios/Runner/GeneratedPluginRegistrant.m ;;
    macos) registrant=$app/macos/Flutter/GeneratedPluginRegistrant.swift ;;
    linux) registrant=$app/linux/flutter/generated_plugin_registrant.cc ;;
  esac
  require "${registrant#"$app"/} exists" test -f "$registrant"
  probe "${registrant#"$app"/} registers FfoProbePlugin" has FfoProbePlugin "$registrant"
  if [[ $os == linux ]]; then
    local cmake=$app/linux/flutter/generated_plugins.cmake
    require "${cmake#"$app"/} exists" test -f "$cmake"
    probe "${cmake#"$app"/} lists ffo_probe in FLUTTER_PLUGIN_LIST" cmake_lists_plugin "$cmake"
  fi

  # 4. The artifact.
  case $os in
    android) check_apk "$f" ;;
    ios | macos) check_xcode_app "$f" ;;
    linux) check_linux_bundle ;;
  esac
}

# check_apk FLAVOR
check_apk() {
  local f=$1
  local tools apk base_id want_id got_id dex classes strings_txt file
  if ! tools=$(android_tools); then
    fail "no build-tools with dexdump and aapt2 in the Android SDK '$android_sdk'"
    exit 1
  fi
  apk=$app/build/app/outputs/flutter-apk/app-$f-release.apk
  require "flavor: ${apk#"$app"/} exists" test -f "$apk"
  base_id=$(sed -n 's/^ *applicationId = "\(.*\)"$/\1/p' "$app/android/app/build.gradle.kts")
  if [[ $f == dev ]]; then want_id=$base_id.dev; else want_id=$base_id; fi
  got_id=$("$tools/aapt2" dump packagename "$apk" 2>/dev/null || true)
  require "flavor: application id is $want_id (got '$got_id')" test "$got_id" = "$want_id"

  dex=$(mktemp -d "$work/dex.XXXXXX")
  unzip -q -o "$apk" 'classes*.dex' -d "$dex"
  classes=$dex/classes.txt
  strings_txt=$dex/strings.txt
  : >"$classes"
  : >"$strings_txt"
  for file in "$dex"/classes*.dex; do
    "$tools/dexdump" "$file" 2>/dev/null | sed -n "s/^  Class descriptor  : '\(.*\)'$/\1/p" >>"$classes"
    strings -a "$file" >>"$strings_txt"
  done
  require "dex: classes listed ($(wc -l <"$classes" | tr -d ' '))" test -s "$classes"
  probe "dex: class io.github.mavoryl.ffo_probe.FfoProbePlugin" \
    grep -q '^Lio/github/mavoryl/ffo_probe/FfoProbePlugin;$' "$classes"
  probe "dex: package io.github.mavoryl.ffo_probe" grep -q '^Lio/github/mavoryl/ffo_probe/' "$classes"
  # A literal from the plugin's Kotlin code: R8 renames classes, not strings.
  probe "dex: string getPlatformVersion" grep -q '^getPlatformVersion$' "$strings_txt"
}

# check_xcode_app FLAVOR: the iOS or macOS app.
check_xcode_app() {
  local f=$1 xcode=$app/$os deps=$app/.flutter-plugins-dependencies
  local bundle frameworks binary label bundle_id
  if [[ $os == ios ]]; then
    bundle=$app/build/ios/iphoneos/Runner.app
    frameworks=$bundle/Frameworks
    binary=$bundle/Runner
    label=Runner
    require "flavor: build/ios/Release-$f-iphoneos exists (configuration Release-$f)" \
      test -d "$app/build/ios/Release-$f-iphoneos"
    require "build/ios/iphoneos/Runner.app exists" test -d "$bundle"
    bundle_id=$(plutil -extract CFBundleIdentifier raw "$bundle/Info.plist" 2>/dev/null || true)
    if [[ $f == dev ]]; then
      require "flavor: bundle id $bundle_id ends with .dev" test "${bundle_id%.dev}" != "$bundle_id"
    else
      require "flavor: bundle id $bundle_id has no .dev suffix" test -n "$bundle_id" -a "${bundle_id%.dev}" = "$bundle_id"
    fi
  else
    # The app's name and base bundle id: Runner/Configs/AppInfo.xcconfig.
    local app_info=$xcode/Runner/Configs/AppInfo.xcconfig name base_id want_id products
    name=$(sed -n 's/^PRODUCT_NAME = //p' "$app_info")
    base_id=$(sed -n 's/^PRODUCT_BUNDLE_IDENTIFIER = //p' "$app_info")
    products=$app/build/macos/Build/Products/Release-$f
    bundle=$products/$name.app
    frameworks=$bundle/Contents/Frameworks
    binary=$bundle/Contents/MacOS/$name
    label=$name.app/Contents/MacOS/$name
    require "flavor: ${products#"$app"/} exists (configuration Release-$f)" test -d "$products"
    require "${bundle#"$app"/} exists" test -n "$name" -a -d "$bundle"
    if [[ $f == dev ]]; then want_id=$base_id.dev; else want_id=$base_id; fi
    bundle_id=$(plutil -extract CFBundleIdentifier raw "$bundle/Contents/Info.plist" 2>/dev/null || true)
    require "flavor: bundle id is $want_id (got '$bundle_id')" test -n "$base_id" -a "$bundle_id" = "$want_id"
  fi

  local package_swift=$xcode/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/Package.swift
  local podfile_lock=$xcode/Podfile.lock framework=${frameworks#"${bundle%/*}"/}/ffo_probe.framework
  # Which dependency manager Flutter used, provable with and without plugins:
  # with Swift Package Manager on, Flutter generates the plugins package with a
  # FlutterFramework dependency; with it off, an empty package (the fixtures'
  # Xcode projects are already integrated). Without plugins Flutter skips
  # `pod install` altogether, so a missing Podfile.lock is fine in prod.
  if [[ -f $deps ]]; then
    require "mechanism: .flutter-plugins-dependencies has swift_package_manager_enabled $os=$spm" \
      grep -Eq "\"swift_package_manager_enabled\":\{[^}]*\"$os\":${spm}[,}]" "$deps"
  fi
  if [[ $spm == false ]]; then
    require "mechanism: FlutterGeneratedPluginSwiftPackage has no FlutterFramework dependency" \
      lacks FlutterFramework "$package_swift"
    require "mechanism: FlutterGeneratedPluginSwiftPackage does not list ffo_probe" \
      lacks ffo_probe "$package_swift"
    probe "CocoaPods: Podfile.lock has ffo_probe" has ffo_probe "$podfile_lock"
    probe "CocoaPods: $framework" test -d "${bundle%/*}/$framework"
  else
    require "mechanism: FlutterGeneratedPluginSwiftPackage depends on FlutterFramework" \
      has FlutterFramework "$package_swift"
    require "mechanism: Podfile.lock does not list ffo_probe" lacks ffo_probe "$podfile_lock"
    require "mechanism: no $framework" test ! -e "${bundle%/*}/$framework"
    probe "SwiftPM: FlutterGeneratedPluginSwiftPackage lists ffo_probe" has ffo_probe "$package_swift"
  fi
  require "$label binary exists" test -s "$binary"
  # The whole file, not what `strings` shows (on macOS only C strings in
  # sections): the plugin's class is in the binary's imports with CocoaPods, in
  # its class names with SwiftPM, and the Swift registrant of macOS keeps the
  # short literal "FfoProbePlugin" inline in the code.
  probe "$label binary mentions FfoProbePlugin" grep -qF FfoProbePlugin "$binary"
  if [[ $os == macos ]]; then
    # In the plugin's framework with CocoaPods, in the app binary with SwiftPM.
    probe "${bundle##*/} has the string $marker" grep -rqF -- "$marker" "$bundle"
  fi
}

# check_linux_bundle: the Linux bundle.
check_linux_bundle() {
  local name bundle binary
  name=$(sed -n 's/^set(BINARY_NAME "\(.*\)")$/\1/p' "$app/linux/CMakeLists.txt")
  # build/linux/<x64|arm64>/release/bundle
  bundle=$(find "$app/build/linux" -mindepth 3 -maxdepth 3 -type d -path '*/release/bundle' 2>/dev/null | head -n 1 || true)
  require "build/linux/<arch>/release/bundle exists (${bundle#"$app"/})" test -n "$bundle" -a -d "$bundle"
  binary=$bundle/$name
  require "bundle/$name binary exists" test -n "$name" -a -s "$binary"
  probe "bundle/lib/libffo_probe_plugin.so" test -f "$bundle/lib/libffo_probe_plugin.so"
  probe "bundle has the string $marker" grep -rqF -- "$marker" "$bundle"
  # The binary's dynamic section names the library it needs, and the
  # registrant's literal names the plugin.
  probe "bundle/$name binary needs libffo_probe_plugin.so" grep -qF libffo_probe_plugin.so "$binary"
  probe "bundle/$name binary mentions FfoProbePlugin" grep -qF FfoProbePlugin "$binary"
}

# --- run ----------------------------------------------------------------------

if [[ $structure == melos6_local ]]; then
  echo "-- melos bootstrap, before the CLI"
  resolve "$structure-$platform-0-bootstrap"
fi
for i in "${!flavors[@]}"; do
  f=${flavors[$i]}
  tag="$structure-$platform-$f"
  if [[ ${#flavors[@]} -gt 1 ]]; then
    tag="$structure-$platform-$((i + 1))-$f"
    echo "-- $f"
  fi
  overrides "$f"
  if [[ $structure == melos6_local && $i -eq 0 ]]; then
    # A plain pub get is enough after the CLI, but one is needed: `flutter
    # build` skips its own while pubspec.yaml is older than pubspec.lock and
    # package_config.json, whatever pubspec_overrides.yaml says (Flutter
    # 3.44.8, flutter_tools lib/src/dart/pub.dart).
    echo "   flutter pub get in app, not melos bootstrap"
    pub_get "$tag" "$app"
    checked_roots=("$app")
  else
    resolve "$tag"
    checked_roots=("${pub_roots[@]}")
  fi
  build "$tag" "$f"
  check "$f"
done

echo "== $structure $platform $flavor: $([[ $failures -eq 0 ]] && echo PASS || echo "FAIL ($failures)")"
[[ $failures -eq 0 ]]
