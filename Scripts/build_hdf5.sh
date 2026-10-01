#!/bin/bash
# Builds vendor/hdf5 (HDF5 2.2.0, matching what Homebrew's own hdf5 formula builds from) as this
# project's own self-contained libhdf5.dylib/libhdf5_hl.dylib, entirely within Xcode's build
# output -- never touches Homebrew's copy. Copper's field-frame files (Copper/Internal/
# CopperHDF5Blosc2.cpp) only need HDF5's own C API. Linking Homebrew's
# /opt/homebrew/opt/hdf5/lib/libhdf5*.dylib by absolute path would silently break (dyld "Library not
# loaded") the moment Homebrew's hdf5 is upgraded, reinstalled at a different version, or simply
# isn't present (e.g. this app run on a different machine); vendoring it with an @rpath install name
# matches the same self-contained treatment CSXCAD gets.
#
# Invoked from the "HDF5" Xcode target's Run Script build phase.
set -euo pipefail

: "${SRCROOT:?SRCROOT must be set (run from an Xcode build phase)}"
: "${BUILT_PRODUCTS_DIR:?BUILT_PRODUCTS_DIR must be set (run from an Xcode build phase)}"
: "${TARGET_TEMP_DIR:?TARGET_TEMP_DIR must be set (run from an Xcode build phase)}"

VENDOR_DIR="${SRCROOT}/vendor/hdf5"
BLOSC2_VENDOR_DIR="${SRCROOT}/vendor/c-blosc2"
# Keep all generated CMake state inside this Xcode build. A repository-global build directory can
# be entered concurrently by two Xcode builds using different DerivedData locations, allowing one
# link to observe another build's partially regenerated or missing object files.
BUILD_DIR="${TARGET_TEMP_DIR}/hdf5-cmake"
PREFIX="${BUILT_PRODUCTS_DIR}/hdf5-local-prefix"
BLOSC2_BUILD_DIR="${TARGET_TEMP_DIR}/blosc2-cmake"
BLOSC2_PREFIX="${BUILT_PRODUCTS_DIR}/blosc2-local-prefix"

# Xcode's own ARCHS (e.g. "arm64") and CONFIGURATION (Debug/Release) -- explicitly forced rather than
# left to CMake's own defaults, since a stale CMakeCache.txt from a prior manual configure (or CMake's
# arch autodetection inside Xcode's build-script sandbox) can otherwise silently pick x86_64 on an
# Apple Silicon Mac, producing a dylib that fails to link against every other arm64-only dependency.
CMAKE_ARCHS="${ARCHS:-arm64}"
CMAKE_ARCHS="${CMAKE_ARCHS// /;}"
CMAKE_CONFIG="${CONFIGURATION:-Debug}"

# c-blosc2's SIMD selection uses CMAKE_SYSTEM_PROCESSOR, but on macOS that can describe the host
# running CMake rather than the architecture Xcode asked this target to emit (in particular after
# changing an existing DerivedData build from an Intel/Rosetta configuration to arm64). Its CMake
# then caches `-msse2` in CMAKE_C_FLAGS, and that stale x86 flag makes every subsequent arm64 build
# fail before blosc2.h is installed. Pin the processor from Xcode's ARCHS and explicitly clear that
# upstream-owned cached flag on every configure. A multi-architecture build deliberately takes the
# generic SIMD path: one CMake source/flag selection cannot safely choose both NEON and SSE for the
# two slices, while the codec remains fully functional without those optional specialized shuffle
# translation units.
case "${CMAKE_ARCHS}" in
  arm64) BLOSC2_SYSTEM_PROCESSOR="arm64" ;;
  x86_64) BLOSC2_SYSTEM_PROCESSOR="x86_64" ;;
  *) BLOSC2_SYSTEM_PROCESSOR="universal" ;;
esac
export CMAKE_OSX_ARCHITECTURES="${CMAKE_ARCHS}"

# Blosc2 is linked statically into Copper.framework's small HDF5 filter adapter. This keeps the
# application self-contained and avoids HDF5_PLUGIN_PATH/dlopen packaging concerns while retaining
# the registered Blosc2 filter id and its standard on-disk chunk representation. Blosc2's bundled
# LZ4/Zstd/zlib-ng dependencies are folded into the archive by its own install target.
cmake -S "${BLOSC2_VENDOR_DIR}" -B "${BLOSC2_BUILD_DIR}" \
  -DCMAKE_BUILD_TYPE="${CMAKE_CONFIG}" \
  -DCMAKE_OSX_ARCHITECTURES="${CMAKE_ARCHS}" \
  -DCMAKE_SYSTEM_PROCESSOR="${BLOSC2_SYSTEM_PROCESSOR}" \
  -DCMAKE_C_FLAGS:STRING= \
  -DCMAKE_INSTALL_PREFIX="${BLOSC2_PREFIX}" \
  -DBUILD_SHARED=OFF \
  -DBUILD_STATIC=ON \
  -DBUILD_TESTS=OFF \
  -DBUILD_FUZZERS=OFF \
  -DBUILD_BENCHMARKS=OFF \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_PLUGINS=OFF \
  -DBLOSC_ENABLE_ZFP=OFF \
  -DBLOSC_DEPENDENCY_MODE=BUNDLED
cmake --build "${BLOSC2_BUILD_DIR}" --target install --parallel "$(sysctl -n hw.ncpu)"
cp -a "${BLOSC2_PREFIX}/lib/libblosc2.a" "${BUILT_PRODUCTS_DIR}/libblosc2.a"

# H5Dint.c's own H5D__dset_size_oh_msg_size() passes an intentionally-uninitialized `time_t mtime`
# by address to H5O_msg_size_oh() purely so it can report that message type's on-disk size -- the
# callee only ever reads its type/size, never mtime's own value, but Clang can't prove that across
# the call and flags it regardless. Vendored upstream source we don't patch; suppressed narrowly (by
# name) rather than the whole
# build's warnings, since this is the only warning HDF5's own build otherwise produces. A plain
# -Wno-uninitialized-const-pointer in CMAKE_C_FLAGS isn't enough on its own -- HDF5's own CMakeLists
# appends its own -Wall *after* CMAKE_C_FLAGS on each compile line, which re-enables this warning on
# recent Clang (it's part of -Wall there) regardless of what came before it; force-including a
# pragma (see hdf5_suppress_warnings.h) sidesteps that ordering fight entirely.
cmake -S "${VENDOR_DIR}" -B "${BUILD_DIR}" \
  -DCMAKE_BUILD_TYPE="${CMAKE_CONFIG}" \
  -DCMAKE_OSX_ARCHITECTURES="${CMAKE_ARCHS}" \
  -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
  -DCMAKE_C_FLAGS="-include ${SRCROOT}/Scripts/hdf5_suppress_warnings.h" \
  -DHDF5_INSTALL_CMAKE_DIR=lib/cmake/hdf5 \
  -DBUILD_SHARED_LIBS=ON \
  -DHDF5_ONLY_SHARED_LIBS=ON \
  -DHDF5_BUILD_HL_LIB=ON \
  -DHDF5_BUILD_CPP_LIB=OFF \
  -DHDF5_BUILD_FORTRAN=OFF \
  -DHDF5_BUILD_JAVA=OFF \
  -DHDF5_BUILD_TOOLS=OFF \
  -DHDF5_BUILD_EXAMPLES=OFF \
  -DHDF5_BUILD_DOC=OFF \
  -DBUILD_TESTING=OFF \
  -DHDF5_ENABLE_THREADSAFE=ON \
  -DHDF5_ALLOW_UNSUPPORTED=ON \
  -DHDF5_ENABLE_ZLIB_SUPPORT=ON \
  -DHDF5_ENABLE_SZIP_SUPPORT=OFF

# hdf5_hl-shared already depends on hdf5-shared. Asking Make for both top-level targets is
# redundant; following the single dependency graph ensures the core library is linked exactly once.
cmake --build "${BUILD_DIR}" --target hdf5_hl-shared --parallel "$(sysctl -n hw.ncpu)"

# `cmake --install` isn't staleness-checked the way `cmake --build` is -- it reruns every install
# rule, including the generated BUILD_RPATH->INSTALL_RPATH install_name_tool fixup, on every
# invocation regardless of whether anything actually changed. That fixup isn't idempotent (a second
# run tries to -delete_rpath a path the first run already removed, and -add_rpath ones it already
# added), so re-running it against an unchanged, already-installed dylib just prints
# install_name_tool errors -- harmless (the file is already in the state the fixup wants), but
# noisy. This build phase runs on every Xcode build now (alwaysOutOfDate, so script *content*
# changes aren't missed -- see this project's own HDF5 target), so skip the actual (re)install
# unless the build tree produced something newer than what's already installed -- or PREFIX itself
# is gone.
STAMP="${BUILD_DIR}/.last-install-stamp"
if [ ! -d "${PREFIX}/lib" ] || [ ! -f "${STAMP}" ] || \
   [ -n "$(find "${BUILD_DIR}/bin" -maxdepth 1 -name 'libhdf5*.dylib' -newer "${STAMP}" 2>/dev/null)" ]; then
  cmake --install "${BUILD_DIR}" --prefix "${PREFIX}"
  touch "${STAMP}"
fi

# Copies+renames+@rpath-izes both libraries directly into BUILT_PRODUCTS_DIR (unversioned names),
# where the app's own linker rpath already resolves libCSXCAD.dylib from today.
_publish() {
  local base="$1" # e.g. "hdf5"
  local real
  real=$(find "${PREFIX}/lib" -maxdepth 1 -name "lib${base}.*.*.*.dylib" | head -1)
  if [ -z "${real}" ]; then
    echo "error: could not find installed lib${base}.*.*.*.dylib in ${PREFIX}/lib" >&2
    exit 1
  fi
  local dest="${BUILT_PRODUCTS_DIR}/lib${base}.dylib"
  cp -a "${real}" "${dest}"
  chmod u+w "${dest}"
  install_name_tool -id "@rpath/lib${base}.dylib" "${dest}"
  echo "${dest}"
}

HDF5_DEST=$(_publish hdf5)
HDF5_HL_DEST=$(_publish hdf5_hl)

# libhdf5_hl.dylib itself links against libhdf5.dylib by the same absolute install-prefix path --
# repoint that at the just-published sibling before either gets codesigned.
OLD_HDF5_DEP=$(otool -L "${HDF5_HL_DEST}" | awk '/libhdf5\./{print $1; exit}')
if [ -n "${OLD_HDF5_DEP}" ] && [ "${OLD_HDF5_DEP}" != "@rpath/libhdf5.dylib" ]; then
  install_name_tool -change "${OLD_HDF5_DEP}" "@rpath/libhdf5.dylib" "${HDF5_HL_DEST}"
fi

codesign --force --sign - "${HDF5_DEST}"
codesign --force --sign - "${HDF5_HL_DEST}"

echo "Rebuilt ${HDF5_DEST} and ${HDF5_HL_DEST} from ${VENDOR_DIR}"
echo "Rebuilt ${BUILT_PRODUCTS_DIR}/libblosc2.a from ${BLOSC2_VENDOR_DIR}"
