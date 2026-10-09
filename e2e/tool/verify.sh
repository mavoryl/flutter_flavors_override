#!/usr/bin/env bash
# Builds one e2e fixture for one platform and flavor, then checks whether the
# native code of the ffo_probe plugin made it into the build: `dev` must have
# it, `prod` must not (there ffo_probe resolves to its no-op stub).
#
# Usage:
#   e2e/tool/verify.sh [options] <single|workspace|path_modules> \
#       <android|ios-cocoapods|ios-spm> <dev|prod>
#
# Options:
#   --keep           keep the temporary copy (its path is printed)
#   --workdir DIR    reuse a copy kept by an earlier run instead of making a
#                    new one (no `flutter clean`: a local switch of flavors)
#   --no-overrides   do not lay out expected/<flavor>/; a negative control:
#                    `prod` must then FAIL
#   --logs DIR       write pub and build logs to DIR (default: <copy>/logs)
#
# The fixture is never built in place. The script copies e2e/ (tracked and
# untracked-but-not-ignored files, as in a fresh checkout) to a temporary
# directory, removes every pubspec_overrides.yaml there, and for the flavor
# lays out the golden files from <fixture>/expected/<flavor>/ (the same tree
# as the fixture). For iOS it sets `flutter: config:
# enable-swift-package-manager:` in the copy of the app's pubspec, so the
# machine's global `flutter config` does not matter. Then `flutter pub get`,
# `flutter build`, and the checks, one PASS/FAIL line each.
#
# Exit code: 0 only if the build succeeded and every check passed.
#
# Needs: flutter on PATH, git, tar; Android: an Android SDK with build-tools
# (dexdump, aapt2) in $ANDROID_HOME, $ANDROID_SDK_ROOT or
# ~/Library/Android/sdk; iOS: Xcode and CocoaPods.

set -euo pipefail

usage() {
  sed -n '6,16p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

keep=0
workdir=''
no_overrides=0
logs=''
while [[ $# -gt 0 ]]; do
  case $1 in
    --keep) keep=1 ;;
    --workdir) workdir=${2:?--workdir needs a directory}; shift ;;
    --no-overrides) no_overrides=1 ;;
    --logs) logs=${2:?--logs needs a directory}; shift ;;
    -h | --help) usage ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) break ;;
  esac
  shift
done
[[ $# -eq 3 ]] || usage
structure=$1 platform=$2 flavor=$3
case $structure in single | workspace | path_modules) ;; *) usage ;; esac
case $platform in android | ios-cocoapods | ios-spm) ;; *) usage ;; esac
case $flavor in dev | prod) ;; *) usage ;; esac

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
tag="$structure-$platform-$flavor"

fixture=$work/e2e/$structure
case $structure in
  single) app=$fixture; pub_roots=("$fixture") ;;
  workspace) app=$fixture/app; pub_roots=("$fixture") ;;
  path_modules) app=$fixture/app; pub_roots=("$fixture/app" "$fixture/packages/feature") ;;
esac

echo "== $structure $platform $flavor (copy: $work)"

# --- overrides ----------------------------------------------------------------

# Start from no overrides at all, as the CLI does when it drops its own entries.
find "$fixture" -name pubspec_overrides.yaml -not -path "$fixture/expected/*" -print |
  while IFS= read -r file; do
    rm -- "$file"
    echo "   removed ${file#"$fixture"/}"
  done
expected=$fixture/expected/$flavor
if [[ $no_overrides -eq 1 ]]; then
  echo "   --no-overrides: expected/$flavor/ not laid out"
elif [[ -d $expected ]]; then
  (cd "$expected" && find . -name pubspec_overrides.yaml) | sort |
    while IFS= read -r rel; do
      rel=${rel#./}
      cp -- "$expected/$rel" "$fixture/$rel"
      echo "   placed $rel"
    done
else
  echo "   no expected/$flavor/: no overrides"
fi

# --- dependency manager on iOS --------------------------------------------------

# Lines this script adds end with "# verify.sh", so a reused copy can drop them.
pubspec=$app/pubspec.yaml
awk '!/# verify\.sh$/' "$pubspec" >"$pubspec.tmp" && mv "$pubspec.tmp" "$pubspec"
spm=''
case $platform in
  ios-cocoapods) spm=false ;;
  ios-spm) spm=true ;;
esac
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

for root in "${pub_roots[@]}"; do
  log=$logs/$tag-pub-get-$(basename "$root").log
  if ! (cd "$root" && flutter pub get) >"$log" 2>&1; then
    echo "FAIL  flutter pub get in ${root#"$work"/} (log: $log)"
    tail -n 20 "$log"
    exit 1
  fi
done

build_log=$logs/$tag-build.log
case $platform in
  android) build=(flutter build apk --release --flavor "$flavor") ;;
  ios-*) build=(flutter build ios --release --flavor "$flavor" --no-codesign) ;;
esac
echo "   ${build[*]} (log: $build_log)"
started=$SECONDS
if ! (cd "$app" && "${build[@]}") >"$build_log" 2>&1; then
  echo "FAIL  build (log: $build_log)"
  tail -n 30 "$build_log"
  exit 1
fi
echo "   built in $((SECONDS - started))s"

# --- checks -------------------------------------------------------------------

failures=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }

# The plugin's native code is expected in dev and must be absent in prod.
if [[ $flavor == dev ]]; then want=present; else want=absent; fi

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

# 1. Resolution: which ffo_probe pub picked, in every package that resolves.
for root in "${pub_roots[@]}"; do
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

# 2. Flutter's plugin list. Flutter deletes the file when there are no plugins.
deps=$app/.flutter-plugins-dependencies
probe ".flutter-plugins-dependencies lists ffo_probe" has '"name":"ffo_probe"' "$deps"

# 3. The generated registrant.
case $platform in
  android) registrant=$app/android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java ;;
  ios-*) registrant=$app/ios/Runner/GeneratedPluginRegistrant.m ;;
esac
require "${registrant#"$app"/} exists" test -f "$registrant"
probe "${registrant#"$app"/} registers FfoProbePlugin" has FfoProbePlugin "$registrant"

# 4. The artifact.
if [[ $platform == android ]]; then
  sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
  tools=''
  while IFS= read -r dir; do
    if [[ -x $dir/dexdump && -x $dir/aapt2 ]]; then tools=$dir; fi
  done < <(find "$sdk/build-tools" -mindepth 1 -maxdepth 1 2>/dev/null | sort -V)
  [[ -n $tools ]] || { fail "no build-tools with dexdump and aapt2 in $sdk"; exit 1; }

  apk=$app/build/app/outputs/flutter-apk/app-$flavor-release.apk
  require "flavor: ${apk#"$app"/} exists" test -f "$apk"
  base_id=$(sed -n 's/^ *applicationId = "\(.*\)"$/\1/p' "$app/android/app/build.gradle.kts")
  if [[ $flavor == dev ]]; then want_id=$base_id.dev; else want_id=$base_id; fi
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
else
  ios=$app/ios
  runner_app=$app/build/ios/iphoneos/Runner.app
  require "flavor: build/ios/Release-$flavor-iphoneos exists (configuration Release-$flavor)" \
    test -d "$app/build/ios/Release-$flavor-iphoneos"
  require "build/ios/iphoneos/Runner.app exists" test -d "$runner_app"
  bundle_id=$(plutil -extract CFBundleIdentifier raw "$runner_app/Info.plist" 2>/dev/null || true)
  if [[ $flavor == dev ]]; then
    require "flavor: bundle id $bundle_id ends with .dev" test "${bundle_id%.dev}" != "$bundle_id"
  else
    require "flavor: bundle id $bundle_id has no .dev suffix" test -n "$bundle_id" -a "${bundle_id%.dev}" = "$bundle_id"
  fi

  package_swift=$ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/Package.swift
  podfile_lock=$ios/Podfile.lock
  frameworks=$runner_app/Frameworks
  lacks() { ! has "$@"; }
  # Which dependency manager Flutter used, provable with and without plugins:
  # with Swift Package Manager on, Flutter generates the plugins package with a
  # FlutterFramework dependency; with it off, an empty package (the fixtures'
  # Xcode projects are already integrated). Without plugins Flutter skips
  # `pod install` altogether, so a missing Podfile.lock is fine in prod.
  if [[ -f $deps ]]; then
    require "mechanism: .flutter-plugins-dependencies has swift_package_manager_enabled ios=$spm" \
      has "\"swift_package_manager_enabled\":{\"ios\":$spm" "$deps"
  fi
  if [[ $platform == ios-cocoapods ]]; then
    require "mechanism: FlutterGeneratedPluginSwiftPackage has no FlutterFramework dependency" \
      lacks FlutterFramework "$package_swift"
    require "mechanism: FlutterGeneratedPluginSwiftPackage does not list ffo_probe" \
      lacks ffo_probe "$package_swift"
    probe "CocoaPods: Podfile.lock has ffo_probe" has ffo_probe "$podfile_lock"
    probe "CocoaPods: Runner.app/Frameworks/ffo_probe.framework" test -d "$frameworks/ffo_probe.framework"
  else
    require "mechanism: FlutterGeneratedPluginSwiftPackage depends on FlutterFramework" \
      has FlutterFramework "$package_swift"
    require "mechanism: Podfile.lock does not list ffo_probe" lacks ffo_probe "$podfile_lock"
    require "mechanism: no Runner.app/Frameworks/ffo_probe.framework" test ! -e "$frameworks/ffo_probe.framework"
    probe "SwiftPM: FlutterGeneratedPluginSwiftPackage lists ffo_probe" has ffo_probe "$package_swift"
  fi
  symbols=$work/runner-symbols-$tag.txt
  strings -a "$runner_app/Runner" >"$symbols" 2>/dev/null || true
  require "Runner binary readable" test -s "$symbols"
  probe "Runner binary mentions FfoProbePlugin" grep -q FfoProbePlugin "$symbols"
fi

echo "== $structure $platform $flavor: $([[ $failures -eq 0 ]] && echo PASS || echo "FAIL ($failures)")"
[[ $failures -eq 0 ]]
