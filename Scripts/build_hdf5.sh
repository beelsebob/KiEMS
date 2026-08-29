#!/bin/bash
# Builds vendor/hdf5 (HDF5 2.2.0, matching what Homebrew's own hdf5 formula builds from) as this
# project's own self-contained libhdf5.dylib/libhdf5_hl.dylib, entirely within this repo's build
# output -- never touches Homebrew's copy. openEMS only needs HDF5's own C API (see
# vendor/openEMS/tools/hdf5_file_{reader,writer}.cpp's plain `#include <hdf5.h>`), and previously
# linked Homebrew's /opt/homebrew/opt/hdf5/lib/libhdf5*.dylib by absolute path -- fine for a build on
# this machine, but that path isn't embedded/rewritten anywhere, so it silently breaks (dyld "Library
# not loaded") the moment Homebrew's hdf5 is upgraded, reinstalled at a different version, or simply
# isn't present (e.g. this app run on a different machine). Vendoring it, and rewriting libopenEMS's
# own dependency onto it via @rpath (see build_openEMS.sh), matches the same self-contained treatment
# CSXCAD/openEMS themselves already get.
#
# Invoked from the "HDF5" Xcode target's Run Script build phase; build_openEMS.sh's own CMake
# configure step points at this script's install prefix so openEMS's `find_package(HDF5)` picks up
# this vendored copy instead of Homebrew's.
set -euo pipefail

: "${SRCROOT:?SRCROOT must be set (run from an Xcode build phase)}"
: "${BUILT_PRODUCTS_DIR:?BUILT_PRODUCTS_DIR must be set (run from an Xcode build phase)}"

VENDOR_DIR="${SRCROOT}/vendor/hdf5"
BUILD_DIR="${VENDOR_DIR}/build"
PREFIX="${SRCROOT}/build/hdf5-local-prefix"

# See build_openEMS.sh's own comment on why ARCHS/CONFIGURATION are forced explicitly rather than
# left to CMake's own defaults.
CMAKE_ARCHS="${ARCHS:-arm64}"
CMAKE_ARCHS="${CMAKE_ARCHS// /;}"
CMAKE_CONFIG="${CONFIGURATION:-Debug}"

# H5Dint.c's own H5D__dset_size_oh_msg_size() passes an intentionally-uninitialized `time_t mtime`
# by address to H5O_msg_size_oh() purely so it can report that message type's on-disk size -- the
# callee only ever reads its type/size, never mtime's own value, but Clang can't prove that across
# the call and flags it regardless. Vendored upstream source we don't patch; suppressed narrowly (by
# name, unlike ext_using_undefined_std in build_openEMS.sh, which has none) rather than the whole
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
  -DHDF5_ENABLE_ZLIB_SUPPORT=ON \
  -DHDF5_ENABLE_SZIP_SUPPORT=OFF

cmake --build "${BUILD_DIR}" --target hdf5-shared hdf5_hl-shared -j"$(sysctl -n hw.ncpu)"

# `cmake --install` isn't staleness-checked the way `cmake --build` is -- it reruns every install
# rule, including the generated BUILD_RPATH->INSTALL_RPATH install_name_tool fixup, on every
# invocation regardless of whether anything actually changed. That fixup isn't idempotent (a second
# run tries to -delete_rpath a path the first run already removed, and -add_rpath ones it already
# added), so re-running it against an unchanged, already-installed dylib just prints
# install_name_tool errors -- harmless (the file is already in the state the fixup wants), but
# noisy. This build phase runs on every Xcode build now (alwaysOutOfDate, so script *content*
# changes aren't missed -- see this project's own HDF5 target), so skip the actual (re)install
# unless the build tree produced something newer than what's already installed -- or PREFIX itself
# is gone (e.g. a project-level Clean, which wipes $(SRCROOT)/build but not vendor/hdf5/build's own
# CMake cache/object files a level up, so `cmake --build` above found nothing to rebuild even though
# there's nothing installed yet).
STAMP="${BUILD_DIR}/.last-install-stamp"
if [ ! -d "${PREFIX}/lib" ] || [ ! -f "${STAMP}" ] || \
   [ -n "$(find "${BUILD_DIR}/bin" -maxdepth 1 -name 'libhdf5*.dylib' -newer "${STAMP}" 2>/dev/null)" ]; then
  cmake --install "${BUILD_DIR}" --prefix "${PREFIX}"
  touch "${STAMP}"
fi

# Copies+renames+@rpath-izes the same way build_openEMS.sh does for libopenEMS.dylib -- landing both
# libraries directly in BUILT_PRODUCTS_DIR (unversioned names), where the app's own linker rpath
# already resolves libCSXCAD.dylib/libopenEMS.dylib from today.
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
