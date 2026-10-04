#!/bin/bash
# Configures and builds the parts of the KiCad submodule (submodules/kicad) that libkicad links
# against (see libkicad/KiCadLink.xcconfig), into build/kicad, using Homebrew's libraries.
# Run Scripts/check_dependencies.sh first; it checks the Homebrew formulas this needs.
#
# Usage: Scripts/build_kicad.sh
#
# Not run from Xcode: a from-scratch build takes a long time. Rerun it after the submodule moves.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$REPO_ROOT/submodules/kicad"
BUILD_DIR="$REPO_ROOT/build/kicad"

if [ ! -f "$SOURCE_DIR/CMakeLists.txt" ]; then
  echo "error: $SOURCE_DIR is empty -- run: git submodule update --init submodules/kicad" >&2
  exit 1
fi

BREW="$(command -v brew || true)"
for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  [ -z "$BREW" ] && [ -x "$candidate" ] && BREW="$candidate"
done
if [ -z "$BREW" ]; then
  echo "error: Homebrew not found -- run Scripts/check_dependencies.sh" >&2
  exit 1
fi
BREW_PREFIX="$("$BREW" --prefix)"
export PATH="$BREW_PREFIX/bin:$PATH"

# KiCad's FindngSpice looks for a Linux-style soname; point it at Homebrew's dylib explicitly.
NGSPICE_PREFIX="$BREW_PREFIX/opt/libngspice"

cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$BREW_PREFIX" \
  -DwxWidgets_CONFIG_EXECUTABLE="$BREW_PREFIX/opt/wxwidgets@3.2/bin/wx-config-3.2" \
  -DNGSPICE_INCLUDE_DIR="$NGSPICE_PREFIX/include" \
  -DNGSPICE_LIBRARY="$NGSPICE_PREFIX/lib/libngspice.dylib" \
  -DNGSPICE_DLL="$NGSPICE_PREFIX/lib/libngspice.dylib" \
  -DOCC_INCLUDE_DIR="$BREW_PREFIX/opt/opencascade/include/opencascade" \
  -DOCC_LIBRARY_DIR="$BREW_PREFIX/opt/opencascade/lib" \
  -DKICAD_BUILD_QA_TESTS=OFF \
  -DKICAD_SPICE_QA=OFF \
  -DKICAD_BUILD_I18N=OFF \
  -DKICAD_USE_SENTRY=OFF \
  -DKICAD_UPDATE_CHECK=OFF

# Exactly what libkicad/KiCadLink.xcconfig links: static libraries, the three dylibs (which CMake
# places in build/kicad/kicad/KiCad.app/Contents/Frameworks), and four of pcbnew's object files --
# built individually, since their pcbnew_kiface_objects target is all ~460 of pcbnew's sources.
PCBNEW_API_OBJECTS=pcbnew/CMakeFiles/pcbnew_kiface_objects.dir/api
cmake --build "$BUILD_DIR" --target \
  pcbcommon kiplatform common core planegcs kimath clipper2 fmt gal kicommon kiapi \
  "$PCBNEW_API_OBJECTS/api_handler_pcb.cpp.o" \
  "$PCBNEW_API_OBJECTS/api_handler_board.cpp.o" \
  "$PCBNEW_API_OBJECTS/headless_pcb_context.cpp.o" \
  "$PCBNEW_API_OBJECTS/pcb_context.cpp.o"

echo "Built KiCad libraries in $BUILD_DIR"
