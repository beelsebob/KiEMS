// Force-included (via -include, see build_hdf5.sh) ahead of every vendor/hdf5 translation unit.
// HDF5's own CMakeLists appends its own -Wall (which pulls in -Wuninitialized-const-pointer on
// recent Clang) *after* the -Wno-uninitialized-const-pointer this project's build passes via
// CMAKE_C_FLAGS, so the command-line -Wno- loses to the later -Wall on ordering alone. A #pragma
// takes effect at the point the frontend parses it -- unlike a command-line flag, it isn't subject
// to "whichever flag comes last on the line wins" -- so forcing this to the very top of every file
// sidesteps HDF5's own flag ordering entirely. See H5Dint.c's own H5D__dset_size_oh_msg_size(),
// vendored source we don't patch, for the one real (harmless) site this silences.
#pragma clang diagnostic ignored "-Wuninitialized-const-pointer"
