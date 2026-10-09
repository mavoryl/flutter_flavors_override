#!/usr/bin/env bash
# Smoke test for the oldest supported Flutter (3.22, Dart 3.4), which cannot
# build the fixtures: they come from the templates of a newer Flutter. So this
# creates an app with the Flutter on PATH, makes it depend on the ffo_probe
# plugin with a prod override to its stub, runs the CLI on the Dart of that
# Flutter, and checks pub's resolution and Flutter's plugin list after
# `flutter pub get`: prod gets the stub, then dev gets the plugin back. No
# native build.
#
# Usage:
#   e2e/tool/smoke_min_flutter.sh [--keep]
#
# Options:
#   --keep   keep the temporary directory (its path is printed)
#
# Everything happens in a temporary directory: e2e/plugins and e2e/stubs are
# copied there, next to the new app. The CLI runs from this repository with
# the dependencies of a throwaway package that depends on it by path, as the
# repository's own dev dependencies need a newer SDK.
#
# Exit code: 0 only if every check passed.
#
# Needs: flutter and dart on PATH, git, tar.

set -euo pipefail

usage() {
  awk '/^# Usage:/ { p = 1 } /^# Everything happens/ { exit } p' "$0" |
    sed 's/^# \{0,1\}//' >&2
  exit 2
}

keep=0
case $# in
  0) ;;
  1) [[ $1 == --keep ]] || usage; keep=1 ;;
  *) usage ;;
esac

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=${TMPDIR:-/tmp}
work=$(mktemp -d "${tmp%/}/ffo-smoke.XXXXXX")
cleanup() {
  if [[ $keep -eq 1 ]]; then
    echo "copy kept: $work"
  else
    rm -rf -- "${work:?}"
  fi
}
trap cleanup EXIT
logs=$work/logs
mkdir -p "$logs"

# run NAME COMMAND...: runs COMMAND with its output in logs/NAME.log; on
# failure prints the log's tail and exits.
run() {
  local log=$logs/$1.log
  shift
  if ! "$@" >"$log" 2>&1; then
    echo "FAIL  $* (log: $log)"
    tail -n 20 "$log"
    exit 1
  fi
}

# Not `flutter --version`: Flutter 3.22 fetches every tag of its repository
# for it. The Dart version tells the Flutter release just as well.
echo "== smoke: $(dart --version 2>&1) (copy: $work)"

# --- the app ------------------------------------------------------------------

git -C "$repo" ls-files -z --cached --others --exclude-standard -- e2e/plugins e2e/stubs |
  (cd "$repo" && tar --null -T - -cf -) | tar -xf - -C "$work"
app=$work/e2e/smoke
(cd "$work/e2e" && run create flutter --no-version-check create --no-pub --platforms=android \
  --org io.github.mavoryl --project-name smoke_app smoke)

pubspec=$app/pubspec.yaml
grep -q '^dependencies:$' "$pubspec" || { echo "no 'dependencies:' in $pubspec" >&2; exit 1; }
awk '
  { print }
  /^dependencies:$/ {
    print "  ffo_probe:"
    print "    path: ../plugins/ffo_probe"
  }' "$pubspec" >"$pubspec.tmp" && mv "$pubspec.tmp" "$pubspec"
cat >>"$pubspec" <<'EOF'

flavor_overrides:
  prod:
    ffo_probe:
      path: ../stubs/ffo_probe
EOF
echo "   created e2e/smoke: depends on ffo_probe, prod override to its stub"

# --- the CLI ------------------------------------------------------------------

mkdir "$work/cli"
cat >"$work/cli/pubspec.yaml" <<EOF
name: smoke_cli
publish_to: none
environment:
  sdk: '>=3.4.0 <4.0.0'
dependencies:
  flutter_flavor_overrides:
    path: $repo
EOF
(cd "$work/cli" && run cli-pub-get dart pub get)

# cli ARGS...: runs the CLI in the app, printing its output.
cli() {
  echo "   flutter_flavor_overrides $*"
  local out status=0
  out=$(cd "$app" && dart --packages="$work/cli/.dart_tool/package_config.json" \
    "$repo/bin/flutter_flavor_overrides.dart" "$@" 2>&1) || status=$?
  sed 's/^/     /' <<<"$out"
  if [[ $status -ne 0 ]]; then
    echo "FAIL  flutter_flavor_overrides $* exited with $status"
    exit 1
  fi
}

# --- checks -------------------------------------------------------------------

failures=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
has() { [[ -f $2 ]] && grep -q -- "$1" "$2"; }

# probe NAME COMMAND...: COMMAND succeeds when the plugin is found.
probe() {
  local name=$1 got=absent
  shift
  if "$@"; then got=present; fi
  if [[ $got == "$want" ]]; then pass "$name: $got"; else fail "$name: $got, want $want"; fi
}

# check FLAVOR: CLI, pub get, then whether Flutter sees the plugin.
check() {
  local f=$1 uri got
  echo "-- $f"
  cli --flavor "$f"
  (cd "$app" && run "pub-get-$f" flutter --no-version-check pub get)
  if [[ $f == dev ]]; then want=present; else want=absent; fi

  if [[ $f == prod ]]; then
    if has '^# flutter_flavor_overrides: ffo_probe$' "$app/pubspec_overrides.yaml"; then
      pass "pubspec_overrides.yaml has our entry"
    else
      fail "pubspec_overrides.yaml has our entry"
    fi
  elif [[ -e $app/pubspec_overrides.yaml ]]; then
    fail "pubspec_overrides.yaml removed"
  else
    pass "pubspec_overrides.yaml removed"
  fi

  uri=$({ grep -A1 '"name": "ffo_probe"' "$app/.dart_tool/package_config.json" || true; } |
    sed -n 's/.*"rootUri": "\(.*\)".*/\1/p')
  case $uri in
    */plugins/ffo_probe | */plugins/ffo_probe/) got=present ;;
    */stubs/ffo_probe | */stubs/ffo_probe/) got=absent ;;
    *) got="unexpected rootUri '$uri'" ;;
  esac
  if [[ $got == "$want" ]]; then
    pass "pub: ffo_probe is $uri"
  else
    fail "pub: ffo_probe is $uri, want the $([[ $want == present ]] && echo plugin || echo stub)"
  fi
  probe ".flutter-plugins-dependencies lists ffo_probe" \
    has '"name":"ffo_probe"' "$app/.flutter-plugins-dependencies"
  probe "GeneratedPluginRegistrant.java registers FfoProbePlugin" has FfoProbePlugin \
    "$app/android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java"
}

want=''
check prod
check dev

echo "== smoke: $([[ $failures -eq 0 ]] && echo PASS || echo "FAIL ($failures)")"
[[ $failures -eq 0 ]]
