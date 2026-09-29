# Field frame-series format (version 4)

One HDF5 file stores the captured field time series for one simulation/excited-port pair. Version 4
is intentionally the only supported revision while the format is still a prototype; opening an old
file reports that the simulation must be rerun.

The format has two spatial levels:

- `/preview` is used for ordinary Field Viewer playback. It is reduced by 16 in X, 16 in Y, and 2
  in Z (ceil at edges). Energy is max pooled so narrow energetic features remain visible. Signed E/H
  components are block means so differential legs can be combined without losing their signs.
- `/frames` retains lossless residuals for full-resolution signed components. Each chunk is one
  frame and one preview cell (at most 16×16×2 full-resolution samples), so refinement units can be
  decoded independently in priority order without decompressing their neighbours.

All arrays use X as the fastest-varying coordinate. Grid coordinates are E-field sample positions,
one per cell (`line_x.count == nx`, etc.), in metres—not `nx+1` cell boundaries.

## Root attributes

| Attribute | Type | Meaning |
|---|---|---|
| `format_version` | int32 | `4` |
| `simulation_name` | string | Simulation identity |
| `excited_port` | int32 | Driven port index |
| `nx`, `ny`, `nz` | int32 | Full-resolution dimensions |
| `preview_nx`, `preview_ny`, `preview_nz` | int32 | Preview dimensions |
| `preview_factor_x`, `preview_factor_y`, `preview_factor_z` | int32 | Currently 16, 16, 2 |
| `timestep_seconds` | double | FDTD step duration |
| `board_z_min`, `board_z_max` | double | Board Z extent in metres |

`/grid/line_x`, `/grid/line_y`, and `/grid/line_z` are the full-resolution sample coordinates. A
preview coordinate is the midpoint of the first and last sample represented by that preview cell.
`/grid/domain_xy_class` is a full-resolution, X-fastest `uint8[nx*ny]` array. Zero marks external
space which is never simulated and must always render with zero energy; non-zero values mark active
interior or CPML nodes. Keeping this full-resolution mask alongside the preview prevents a
max-pooled preview cell that straddles the CPML edge from visually leaking energy into external
space.

## Preview datasets

All preview datasets have HDF5 shape `(N, preview_nz, preview_ny, preview_nx)`, chunks of one preview
frame, float32 values, and Blosc2 bitshuffle + LZ4 compression.

| Dataset | Filtering |
|---|---|
| `/preview/energy_max` | Maximum `eps0*|E|² + mu0*|H|²` in the represented block |
| `/preview/Ex_mean` … `/preview/Hz_mean` | Arithmetic mean of the signed component in the block |

The normal viewer reads only these datasets. For the reported 146-million-cell mesh, the reduction
is about 512:1 before compression.

`/preview/refinement_order` has shape `(N, preview_nx*preview_ny*preview_nz)`, uint32 values, and one
compressed chunk per frame. Each row is a permutation of x-fastest linear preview-cell indices,
ordered from greatest to least high-resolution variation. Variation is the maximum of:

- the energy span within the preview cell, normalized by the frame's energy range; and
- each signed component's maximum absolute difference from its preview mean, normalized by that
  component's frame range.

Normalizing each quantity independently prevents the different units and scales of E, H, and energy
from dominating the ordering. Non-finite residuals sort first; equal scores sort by ascending cell
index, making encoding deterministic. A time-budgeted decoder reads the preview and this ordering,
then decodes preview-cell detail blocks in list order until its deadline.

## Full-resolution and metadata datasets

`/frames/Ex_xor` through `/frames/Hz_xor` have HDF5 shape `(N,nz,ny,nx)`, uint32 values, and chunks
`(1,min(nz,2),min(ny,16),min(nx,16))`. Reversing the spatial dimension order makes X the actual
contiguous/fastest coordinate in HDF5, rather than merely claiming it in the API. They are detail
tiles; ordinary playback does not read them. Each value is
`bitPattern(fullResolutionFloat) XOR bitPattern(previewComponentMean)`. XOR is used instead of
floating-point subtraction so reconstruction is bit exact, including low mantissa bits, signed zero,
infinities, and NaNs. The shared preview baseline also tends to turn common high bits into zeros for
the compressor.

The small datasets `timestep`, `time_seconds`, `min_energy`, `max_energy`, and signed min/max values
for each component have one entry per frame. The scalar `published_frame_count` is the authoritative
SWMR boundary.

## Streaming and memory bounds

The simulation owns one reusable six-component capture frame. It applies back-pressure and writes
that frame before advancing; the removed two-slot × sixteen-frame queue retained 192 full-grid
component arrays. HDF5's raw chunk cache is capped at 32 MiB per dataset, and spatial chunks are
small enough that Blosc2 never receives a whole-grid buffer.

`chunkFrames` controls publication cadence (16 by default), not field-data chunk shape. After each
publication group, all datasets are flushed before `published_frame_count` advances. The final
partial group is published by `close()`.

The Field Viewer retains only the displayed frame and one prepared successor. While the displayed
frame remains on screen for approximately 100ms, a serial background decoder reads the successor's
preview and refinement order, then decodes greatest-variation-first detail tiles until that same
100ms deadline. Playback promotes the prepared frame without rereading it. Direct timeline scrubbing
remains responsive by decoding only the requested low-resolution preview.

## Filtering choice and future detail refinement

Bicubic filtering was rejected for energy because it can blur narrow peaks and introduce ringing.
Max pooling is conservative for a diagnostic heat map. Component means are stored alongside it only
for signed field combinations.

Full-resolution chunks are independently compressed and addressable one preview cell at a time. The
reader reconstructs only the requested region by XORing its residual tiles with the corresponding
signed preview means. `readRefinementOrder()` supplies the persisted priority permutation and
`readPreviewCellDetail()` maps one entry directly to its edge-aware full-resolution block. The energy
preview is not a viable reconstruction baseline: it has different units and discards field sign and
direction.
