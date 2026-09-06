# Field frame-series file format

Stores a time series of 3D FDTD field-component grids captured during a GPU simulation run
(`Copper/CopperFDTDRunner.cpp`'s field-frame capture), so they can be written incrementally as the
run proceeds and read back a frame (or a small block of frames) at a time for playback/scrubbing,
without ever holding the whole series in memory.

One file per (simulation name, excited port). Container format is HDF5 (the vendored copy this
project already builds via `Scripts/build_hdf5.sh` — see that script's own doc comment for why a
vendored copy exists at all). The encoder/decoder live in `Copper/FieldFrameSeriesWriter.hpp`/
`Copper/FieldFrameSeriesReader.hpp`.

## Two conventions this format deliberately does NOT get wrong

These are both real mistakes that already happened once elsewhere in this codebase — stated
explicitly here so a future reader/writer never reintroduces either:

1. **`line_x`/`line_y`/`line_z` are E-field *sample positions*, one per cell along that axis
   (`count == nx`/`ny`/`nz`), not `nx+1` cell *boundaries*.** `Gerber2EMSStudio/Bridge/
   FieldSnapshotBridge.h`'s own doc comment currently claims the `nx+1`-boundary convention for the
   in-memory `EMSFieldSnapshot.lineX` while the actual data has always been the `nx`-sample-point
   convention — `Gerber2EMSStudio/FieldView.swift` had to work around the mismatch after it silently
   broke rendering. This format uses the sample-point convention throughout, matching what
   `copper::CopperFieldSnapshot::lineX/Y/Z` (`Copper/CopperFDTDRunner.h`) actually produces.
2. **Units are meters**, matching `CopperFieldSnapshot::lineX/Y/Z` — not `kicad_ems::
   ComputedGridLines`' simulation-unit doubles (`libkicadems/kicad_ems/simulation.hpp`), which are
   a different frame (scaled, and re-origined to the board's own Edge_Cuts bounding box) entirely.
   Don't mix the two without an explicit, documented conversion.

## File identity

A file is meaningless without knowing which simulation and which excited port it belongs to — see
`format_version`/`simulation_name`/`excited_port` below. A multi-port simulation gets one file per
excited port, and the field viewer exposes every completed excitation through its selector.

## Schema

### Root attributes

| Attribute | Type | Meaning |
|---|---|---|
| `format_version` | int32 | `1` for this revision |
| `simulation_name` | string | The `SimulationConfig::name()` this file belongs to |
| `excited_port` | int32 | Which port index was driven for this run |
| `nx`, `ny`, `nz` | int32 | Grid dimensions (cell counts along each axis) |
| `timestep_seconds` | double | The FDTD's fixed per-step time delta (`dt`) |
| `board_z_min`, `board_z_max` | double, meters | Board's own Z extent, for cropping a viewer's display without re-deriving it from config |

### `/grid` group — written once, at file creation, uncompressed (tiny: O(nx+ny+nz) doubles)

| Dataset | Shape | Meaning |
|---|---|---|
| `/grid/line_x` | `(nx,)` double, meters | E-field sample position along X (see convention note above) |
| `/grid/line_y` | `(ny,)` double, meters | Same, Y |
| `/grid/line_z` | `(nz,)` double, meters | Same, Z |

### `/frames` group — extendible, grows by one frame per `writeFrame()` call

| Dataset | Shape | Chunk | Compression | Meaning |
|---|---|---|---|---|
| `/frames/Ex`, `/frames/Ey`, `/frames/Ez`, `/frames/Hx`, `/frames/Hy`, `/frames/Hz` | `(N, nx, ny, nz)` float32 | `(chunkFrames, nx, ny, nz)` | Blosc2: bitshuffle + Zstd level 1 | Raw field component, one full grid per frame |
| `/frames/timestep` | `(N,)` uint32 | — | none | The FDTD global timestep this frame was captured at |
| `/frames/time_seconds` | `(N,)` double | — | none | `timestep * timestep_seconds` — stored explicitly (not recomputed) since capture cadence is wall-clock-gated and irregular, not a fixed stride |
| `/frames/min_energy`, `/frames/max_energy` | `(N,)` float32 | — | none | `eps0*(Ex²+Ey²+Ez²) + mu0*(Hx²+Hy²+Hz²)` extrema over that frame's cells — lets a reader pick a sane color scale by reading two tiny arrays instead of scanning all six big datasets for every frame on open |
| `/frames/Ex_min`, `/frames/Ex_max` | `(N,)` float32 | — | none | Minimum and maximum signed Ex value over all cells in each frame |
| `/frames/Ey_min`, `/frames/Ey_max` | `(N,)` float32 | — | none | Minimum and maximum signed Ey value over all cells in each frame |
| `/frames/Ez_min`, `/frames/Ez_max` | `(N,)` float32 | — | none | Minimum and maximum signed Ez value over all cells in each frame |
| `/frames/Hx_min`, `/frames/Hx_max` | `(N,)` float32 | — | none | Minimum and maximum signed Hx value over all cells in each frame |
| `/frames/Hy_min`, `/frames/Hy_max` | `(N,)` float32 | — | none | Minimum and maximum signed Hy value over all cells in each frame |
| `/frames/Hz_min`, `/frames/Hz_max` | `(N,)` float32 | — | none | Minimum and maximum signed Hz value over all cells in each frame |
| `/frames/published_frame_count` | scalar uint32 | — | none | Number of complete frames visible to SWMR readers; the authoritative publication boundary |

`maxdims` on every `/frames/*` dataset is `H5S_UNLIMITED` on the frame axis (fixed on the spatial
axes — `nx`/`ny`/`nz` never change once the mesh is built for a run).

### Component ranges and normalization

Each of the six raw field components has a pair of per-frame range datasets. Values are the true
signed extrema, not extrema of the absolute value. This preserves enough information for a reader
to choose the normalization it needs without opening any field-data chunk:

- For normalization within one frame, use that frame's corresponding `Ex_min[i]`/`Ex_max[i]` pair
  (or the equivalent pair for the selected component).
- For a stable scale across playback, take the minimum of every per-frame minimum and the maximum
  of every per-frame maximum for that component.
- For a zero-centred diverging scale, use
  `max(abs(series_min), abs(series_max))` as the magnitude at both ends.

Electric and magnetic components retain their native, different units (V/m for Ex/Ey/Ez and A/m
for Hx/Hy/Hz). Their ranges must not be combined directly into one six-component numeric range.
Derived energy continues to use `/frames/min_energy` and `/frames/max_energy`.

The writer computes all twelve component extrema while it already has the six input arrays for
`writeFrame()`, and appends them with the other small per-frame metadata. This adds only 48 bytes per
frame. Readers require all twelve datasets and reject a partially populated file.

## Chunking / compression rationale

`chunkFrames` (default 16) is the compression *and* I/O granularity: HDF5 compresses each chunk
independently, and reading any single frame requires decompressing only the chunk(s) that cover it.
This is the same trade-off as a video codec's GOP size — a larger `chunkFrames` compresses better
(field data evolves smoothly frame-to-frame, giving Zstd more redundancy to find) at the cost of
decompressing more surrounding frames to serve one random-access read; a smaller value gives finer
seek granularity at a worse compression ratio. Sixteen also matches the simulation runner's two
ping-pong block buffers, so one block can be encoded while the next is generated. Tune per measured
ratio/seek-latency and memory use on real captures before changing it, not by theory alone.

## Streaming write / durability

The low-level writer extends each `/frames/*` dataset and writes one frame's hyperslab per
`writeFrame()` call, relying on HDF5's own per-file chunk cache (sized via `H5Pset_chunk_cache` to
comfortably hold one full chunk in each big dataset) to coalesce those single-frame writes into real
chunk-sized, compressed I/O. The simulation runner feeds it through two reusable 16-frame block
buffers on a dedicated writer thread. While HDF5 encodes one block, FDTD can continue and capture
into the other; if both are occupied, capture applies bounded back-pressure rather than dropping a
frame or allowing memory use to grow with run length. All HDF5 calls remain on that one writer
thread — the vendored library is not assumed to be thread-safe. The in-process Blosc2 filter uses
bitshuffle followed by Zstd level 1 and lets Blosc2 parallelize compression internally across the
machine's available CPU threads.

The file is created with HDF5's latest-format bounds and enters SWMR-write mode after every object
has been created. After every `chunkFrames` frames, the writer first calls
`H5Fflush(file, H5F_SCOPE_GLOBAL)` to make all nineteen extendible datasets visible, then advances
and flushes `/frames/published_frame_count`. SWMR has no transaction spanning those datasets, so
readers use that scalar as the sole authoritative boundary: observing a new count guarantees the
corresponding field data and metadata were flushed first. The final partial block is published by
`close()`. A process killed mid-block therefore leaves only the preceding complete block visible,
instead of exposing a frame assembled from mismatched dataset extents.

The vendored HDF5 C library is built thread-safe because the simulation's encoder and the field
viewer's decoder use different handles from different threads while a run is active. HDF5 may
serialize portions of those calls internally; this setting provides safe concurrent access, while
SWMR provides the on-disk visibility and consistency contract.

Blosc2 is registered with HDF5 in-process using the standard filter id 32026; no
`HDF5_PLUGIN_PATH` or dynamically loaded plug-in is required. The static Blosc2 archive is built by
the HDF5 aggregate target and linked into Copper through Xcode's Frameworks build phase. This is
still format version 1: the format is under active design and has not yet been released as a stable
external interchange contract.

## Performance signposts

The `com.tdavie.kicad_ems` / `FieldFrames` Instruments log exposes interval signposts for:

- generating one 16-frame block (or the final partial block);
- generating each individual frame within that block;
- encoding one block through HDF5/Blosc2; and
- decoding one block for the field viewer's cache.

These intervals make the intended overlap between block generation and block encoding visible in
Instruments, and make it clear whether capture, compression, or viewer decode is the current
bottleneck.

## Reading

Open with `H5F_ACC_SWMR_READ`, read the root attributes and the three small `/grid/line_*` datasets
eagerly (cheap).
Read `/frames/timestep`, `/frames/time_seconds`, `/frames/min_energy`, `/frames/max_energy` and the
twelve component-range datasets eagerly too. Together these are only 68 bytes per frame, negligible
even for a very long run, and provide whole-series normalization ranges without reading a field-data
chunk. For a requested frame, divide its index by the component
dataset's discovered chunk length, issue one hyperslab read for that complete chunk, and cache it.
Copy the requested frame from the cached block; adjacent playback frames then require no HDF5
operation until playback crosses a chunk boundary. Neither opening a series nor selecting it scans
the other field-data chunks. While encoding continues, refresh `/frames/published_frame_count`; only
when it advances, refresh the component dataset extents and reload the small metadata arrays through
that published prefix. The field viewer currently does this by reopening its lightweight reader on
simulation progress updates, which also ensures each newly returned lazy snapshot has a stable
published extent.
