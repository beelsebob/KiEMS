#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname -- "$script_dir")
build_dir=${TMPDIR:-/tmp}/libkiems-tests
compiler=${CXX:-clang++}

mkdir -p "$build_dir"

"$compiler" \
    -std=c++23 \
    -Wall \
    -Wextra \
    -Werror \
    -Wnewline-eof \
    -I"$project_dir/libkiems" \
    -I/opt/homebrew/include \
    "$project_dir/libkiems_tests/main.cpp" \
    "$project_dir/libkiems/kiems/component_value.cpp" \
    "$project_dir/libkiems/kiems/fft_postprocess.cpp" \
    "$project_dir/libkiems/kiems/eye_diagram.cpp" \
    -o "$build_dir/libkiems_tests"

exec "$build_dir/libkiems_tests"

