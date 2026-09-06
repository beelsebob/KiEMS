#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname -- "$script_dir")
build_dir=${TMPDIR:-/tmp}/libkiems-tests

exec xcodebuild \
    -project "$project_dir/kiems.xcodeproj" \
    -scheme libkiems_tests \
    -configuration Debug \
    -quiet \
    -derivedDataPath "$build_dir" \
    test


