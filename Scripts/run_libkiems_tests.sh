#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname -- "$script_dir")
# Sources in the nested KiCad checkout are not always reflected in Xcode's incremental
# dependency graph. Use an isolated DerivedData directory so this command never runs a stale
# libkicad test bundle.
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/libkiems-tests.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM

xcodebuild \
    -project "$project_dir/kiems.xcodeproj" \
    -scheme libkiems_tests \
    -configuration Debug \
    -quiet \
    -derivedDataPath "$build_dir" \
    build-for-testing

xcrun xctest "$build_dir/Build/Products/Debug/libkiems_tests.xctest"
