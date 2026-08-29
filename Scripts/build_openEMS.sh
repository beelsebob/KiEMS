#!/bin/bash
# Rebuilds vendor/openEMS's own libopenEMS against this project's own CSXCAD and HDF5 targets (see
# CSXCAD/CSXCAD/CSSpatialIndex.{h,cpp} and Scripts/build_hdf5.sh's own doc comment for why HDF5 is
# vendored too), entirely self-contained within this repo's build output -- never touches
# /Users/tdavie/opt/openEMS or Homebrew's hdf5. Invoked from the "openEMS" Xcode target's Run Script
# build phase, which depends on the CSXCAD and HDF5 targets having already built their own dylibs
# into BUILT_PRODUCTS_DIR.
set -euo pipefail

: "${SRCROOT:?SRCROOT must be set (run from an Xcode build phase)}"
: "${BUILT_PRODUCTS_DIR:?BUILT_PRODUCTS_DIR must be set (run from an Xcode build phase)}"

PREFIX="${SRCROOT}/build/csxcad-local-prefix"
mkdir -p "${PREFIX}/include" "${PREFIX}/lib"
ln -sfn "${SRCROOT}/CSXCAD/CSXCAD" "${PREFIX}/include/CSXCAD"
ln -sfn "${BUILT_PRODUCTS_DIR}/libCSXCAD.dylib" "${PREFIX}/lib/libCSXCAD.dylib"

VENDOR_DIR="${SRCROOT}/vendor/openEMS"
BUILD_DIR="${VENDOR_DIR}/build"

# Xcode's own ARCHS (e.g. "arm64") and CONFIGURATION (Debug/Release) -- explicitly forced rather than
# left to CMake's own defaults, since a stale CMakeCache.txt from a prior manual configure (or CMake's
# arch autodetection inside Xcode's build-script sandbox) can otherwise silently pick x86_64 on an
# Apple Silicon Mac, producing a libopenEMS.dylib that fails to link against every other arm64-only
# dependency in this project.
CMAKE_ARCHS="${ARCHS:-arm64}"
CMAKE_ARCHS="${CMAKE_ARCHS// /;}"
CMAKE_CONFIG="${CONFIGURATION:-Debug}"

# fparser/tinyxml stay as the existing prebuilt copies (out of scope for the CSXCAD vendoring work) --
# CSXCAD_ROOT_DIR now points at our own local prefix instead, so it no longer doubles as the hint for
# these two.
FPARSER_TINYXML_ROOT="/Users/tdavie/opt/openEMS"

# Built by the "HDF5" target's own Run Script phase (Scripts/build_hdf5.sh) -- its installed
# lib/cmake/hdf5 config package is what makes find_package(HDF5 COMPONENTS C HL REQUIRED) below
# resolve to this vendored copy instead of Homebrew's, as long as it's on CMAKE_PREFIX_PATH.
HDF5_PREFIX="${SRCROOT}/build/hdf5-local-prefix"

# vtk_file_writer.cpp/hdf5_file_writer.cpp's own `using namespace std;` trips Clang's
# ext_using_undefined_std ("using directive refers to implicitly-defined namespace 'std'") --
# confirmed against Clang's own DiagnosticSemaKinds.td that this diagnostic has no InGroup<...> at
# all, so there is no -Wno-<name> that can target it specifically (nor a #pragma clang diagnostic
# ignored spelling, which also needs a named group); -w is the only lever. Scoped to this vendored
# CMake sub-build alone -- this project's own first-party targets keep every warning they already
# have -- since openEMS's own occasional warnings (this one included) are vendored code we don't
# maintain and wouldn't act on regardless.
cmake -S "${VENDOR_DIR}" -B "${BUILD_DIR}" \
  -DCMAKE_BUILD_TYPE="${CMAKE_CONFIG}" \
  -DCMAKE_OSX_ARCHITECTURES="${CMAKE_ARCHS}" \
  -DCSXCAD_ROOT_DIR="${PREFIX}" \
  -DFPARSER_ROOT_DIR="${FPARSER_TINYXML_ROOT}" \
  -DCMAKE_PREFIX_PATH="${FPARSER_TINYXML_ROOT};${HDF5_PREFIX}" \
  -DCMAKE_C_FLAGS=-w \
  -DCMAKE_CXX_FLAGS=-w \
  -DWITH_MPI=OFF

cmake --build "${BUILD_DIR}" --target openEMS -j"$(sysctl -n hw.ncpu)"

REAL_LIB=$(find "${BUILD_DIR}" -maxdepth 1 -name 'libopenEMS.*.*.*.dylib' | head -1)
if [ -z "${REAL_LIB}" ]; then
  echo "error: could not find built libopenEMS.*.*.*.dylib in ${BUILD_DIR}" >&2
  exit 1
fi

DEST="${BUILT_PRODUCTS_DIR}/libopenEMS.dylib"
cp -a "${REAL_LIB}" "${DEST}"
chmod u+w "${DEST}"

install_name_tool -id "@rpath/libopenEMS.dylib" "${DEST}"

# Repoints each dependency at the unversioned @rpath name this project's own build actually
# publishes to BUILT_PRODUCTS_DIR (see this script's own libopenEMS.dylib copy above, and
# build_hdf5.sh's libhdf5.dylib/libhdf5_hl.dylib) -- CMake's own generated link line instead names
# the CSXCAD/HDF5 targets' *versioned* @rpath install names (e.g. @rpath/libhdf5.320.dylib), which
# dyld would otherwise look for and never find at runtime.
for lib in libCSXCAD libhdf5_hl libhdf5; do
  # Matches on the dependency's own basename (whatever precedes it -- @rpath/ or an absolute
  # Homebrew/local-prefix path alike), anchored with a trailing "." so "libhdf5." never also matches
  # a "libhdf5_hl.*" dependency.
  OLD_DEP=$(otool -L "${DEST}" | awk -v lib="${lib}" \
    '{n = split($1, parts, "/"); base = parts[n]} base ~ ("^" lib "\\.") {print $1; exit}')
  if [ -n "${OLD_DEP}" ] && [ "${OLD_DEP}" != "@rpath/${lib}.dylib" ]; then
    install_name_tool -change "${OLD_DEP}" "@rpath/${lib}.dylib" "${DEST}"
  fi
done

codesign --force --sign - "${DEST}"

echo "Rebuilt ${DEST} against ${SRCROOT}/CSXCAD"
