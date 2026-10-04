# Copper field storage and fused-update experiments

October 2026. All of this is opt-in through environment variables, read when a `CopperEngine` is
built; with none set, Copper behaves exactly as before except that lumped RLC elements are now
corrected on the GPU (see [Lumped RLC on the GPU](#lumped-rlc-on-the-gpu)).

Measurements are on the Keyboard Hub board (`TestSim`; [Separable CPML](#separable-cpml) on a later
version of it), simulations *Upstream/SS CTx1* (503 x 524 x 87 = 22.9M cells, 10.5M of them in the
CPML, 288 voltage excitation cells, 581 lumped RLC cells)
and *Upstream/SS CRx1* (454 x 543 x 87 = 21.4M cells, 11.0M CPML, 448 excitation, 403 lumped), both
rectangular domains. Accuracy is every S-parameter of both simulations (all four driven ports, 1-10
GHz, 1001 points) against an fp32 reference run; speed is CTx1's first port run to the -60 dB
energy-decay criterion.

## Summary

| | Wall time per step | vs fp32 | Main-path S-param error vs fp32 | Memory |
|---|---|---|---|---|
| fp32 (default) | 9.29 ms | -- | -- | 1.64 GB |
| Q16 tiles | 7.69 ms | -17% | -62.8 dB worst | 1.49 GB |
| **Mixed Q16/fp32 tiles** | **8.25 ms** | **-11%** | **-84.5 dB worst** | 2.00 GB |
| Mixed + fused E+H | 9.88 ms | +6% | -96.0 dB worst | 2.83 GB |

(Time: CTx1 first port to convergence, GPU lumped RLC throughout. Error: the worst complex difference
on thru, return-loss and P/N-coupling paths over CTx1 and CRx1, see [Q16 tiles](#q16-tiles) -- with a
~-70 dB floor on CRx1 from where each run happens to stop, see [Verification](#verification).)

0. **The CPML is now separable and folded into the update kernels** (default, not opt-in): 1-D
   coefficient tables, psi only on each axis's own slabs, no second pass. A step takes half the
   time in every field format (wall, CTx1 to convergence: fp32 9.4 -> 4.9 ms, Q16 8.3 -> 3.9, mixed
   9.1 -> 4.4) and half the memory, with S-parameters unchanged to the CSVs' 6 digits. See [Separable CPML](#separable-cpml);
   the table below predates it.
1. **Mixed precision works**: promoting the ~2% of tiles holding the energetic fields to fp32 takes
   Q16's error from -63 to -85 dB on the main paths (-96 dB with the fused kernel) at the same
   convergence, and keeps most of Q16's speed.
2. **Fused E+H is correct but slower** (+9% to +28%) in its current one-tile-per-SIMD form: the
   halo recomputation and idle lanes cost more lane work than the halved field traffic saves.
3. **Lumped RLC runs on the GPU** (default now), 1-4% faster; with it the fused kernel covers every
   tile outside the CPML.
4. **CPML was the real bottleneck on this board**: about half the cells and roughly half of each
   step, stored as 24 floats per cell -- fixed by 0.

## Configurations

| Variable | Effect |
|---|---|
| `COPPER_FIELD_Q16=1` | E/H stored as Q16 tiles (below), arithmetic fp32 |
| `COPPER_FIELD_MIXED` | Q16 tiles, each promoted to fp32 while it's energetic -- **now the default**; `=0` for plain fp32 fields |
| `COPPER_MIXED_PROMOTE_DB` | promote within this many dB of the side's all-time peak tile energy (default 50) |
| `COPPER_MIXED_HYSTERESIS_DB` | demote this far below the promote threshold (default 10) |
| `COPPER_MIXED_RETILE_STEPS` | how often tiles change format (default every 8 steps) |
| `COPPER_MIXED_PIN_ALL=1` | every tile fp32 -- an exact fp32 run in the tiled code path, for comparison |
| `COPPER_FUSED=1` | one fused E+H pass per step for every tile it can take (needs Q16/MIXED, rectangular domain) |
| `COPPER_FUSED_CORRECTIONS=0` | keep excitation and lumped RLC tiles out of the fused pass (default: fused) |
| `COPPER_FUSED_CHUNK` | tile planes per fused segment (default 16) |
| `COPPER_CPU_LUMPED=1` | the runner's original CPU lumped RLC correction instead of the GPU one |
| `COPPER_Q16_ROUND=stochastic` | dithered Q16 rounding (measured worse; default round-to-nearest) |
| `COPPER_FIELD_FP16=1` | E/H stored as half (first experiment; superseded by Q16) |
| `COPPER_SNAPSHOT_DIR`, `COPPER_SNAPSHOT_STEPS` | dump decoded fields (and the CPML's psi as stored) at listed steps for offline analysis |
| `COPPER_GPU_TIMING=1` | per-100-step GPU timing, and mixed-tile statistics every 1000 steps |
| `COPPER_PROFILE_KERNELS=1` | GPU time per kernel category, each in its own timestamped encoder |
| `kiems --absorbing-boundary-cells N`, `grid.absorbing_boundary_cells`, the app's Absorbing Boundary field | absorbing boundary (CPML) depth in cells, default 8; changes the geometry |
| `COPPER_END_CHECK_STEPS=N` | check the -60 dB end criterion every N steps instead of every 4 s of wall time |
| `COPPER_CPML_PSI` | CPML psi storage: `fp32` (default), `fp16`, `bf16`, `bf16sr` (stochastically rounded), `dropN`/`dropNsr` (fp32 with N mantissa bits rounded away); see [Reduced-precision psi](#reduced-precision-psi) |
| `COPPER_CPML_PSI_SIDE` | `E`, `H` or `EH` (default): which sides' psi use `COPPER_CPML_PSI`; the other stays fp32 |
| `COPPER_CPML_PSI_SCALE_LOG2=e,h` | `fp16` psi stores the E/H side times 2^e / 2^h |

## Q16 tiles

E and H are stored as 4x4x1 tiles: per tile a float `(bias, scale)` header and a 16-bit `n` per
cell, decoding to `scale * (n - bias)`. All arithmetic stays fp32. Bias is snapped to a whole number
whenever the tile's range spans zero, so zero (every PEC and out-of-domain cell) decodes exactly, and
tiles spanning less than 2^-110 flush to zero (a subnormal scale gave `1/scale = inf` and a NaN bias
on the CPU encoder -- regression test `testQ16TinyCellWritesStayFinite`). Half a SIMD group owns
each tile, so it can find the tile's range with shuffles and re-encode it on every store.

What was tried on the way, against fp32 (worst complex S-parameter error, CTx1+CRx1):

| Variant | Main paths (thru, return loss, P/N coupling) | Paths at -30..-20 dB | Worst path relative to its own peak | Steps to converge (4 ports) |
|---|---|---|---|---|
| fp32 reference | -- | -- | -- | 23,872 / 47,203 / 33,094 / 28,456 |
| Q16, 32-cell runs along x | -52.6 dB | -57.1 dB | -9.2 dB | 27,354 / 52,350 / 45,850 / 33,226 |
| Q16, 4x4x1 tiles | -62.8 dB | -76.9 dB | -25.7 dB | 24,054 / 47,341 / 32,958 / 28,723 |
| Q16 tiles, stochastic rounding | -61.1 dB | -72.4 dB | -17.2 dB | 23,748 / 53,639 / 34,590 / 28,802 |
| **Mixed Q16/fp32 tiles** | **-84.5 dB** | **-84.7 dB** | **-28.0 dB** | 23,723 / 47,180 / 32,799 / 28,476 |

(Main-path medians: Q16 tiles -86 dB, mixed -100 dB.) Runs of 32 cells along x mixed traces and air
in one block and left a ~-57 dB energy noise floor that stalled convergence; 4x4 tiles removed it.
Stochastic rounding only added noise: round-to-nearest error is already unbiased.

### Why mixed precision

Decoded fp32 snapshots of CTx1 at steps 3000-22000 showed:

- Within a tile ~96% of cells sit within one decade of the tile's peak at every phase of the run:
  the exponential spread of field magnitudes is *between* tiles, which the per-tile scale already
  handles. Offline, linear min/max encoding beat sign+magnitude, E2M13-E4M11 mini-floats and mu-law
  companding by 2-20x in energy-weighted error at 16 bits.
- The run-vs-run (Q16 vs fp32) error energy rose to about -64 dB relative to peak field energy while
  the field was strong, then stayed flat while the field decayed another 37 dB: almost all of it
  went in near the energy peak.
- At that time 99.9% of the field energy sat in 1.5-3% of tiles.

So tiles are promoted to fp32 while their amplitude is within 50 dB of their side's all-time peak
tile amplitude, and demoted 10 dB below that. On CTx1 that peaks at about 2% of tiles and falls to
none once the field has decayed ~50 dB; convergence matches fp32 to within ~1% of steps (the stop
step is only resolved to the ~450 steps between energy checks).

How it works: each field buffer holds the Q16 tile data then an fp32 copy of every tile; a format
byte per tile (shared by the three components of a side) says which is live, and a promoted tile's
header carries a negative scale so reads can tell from the header they load anyway. Update kernels
record each tile's peak amplitude and whether it wants fp32; every 8 steps `q_retile_e/h` converts
the tiles whose wish changed. A per-tile "near fp32" byte (any tile within one tile is fp32) lets
each update choose, once per tile, between the pure-Q16 read path and the mixed one: the fp32 branch
in every field read, though almost never taken, cost ~25% of a step until it was hoisted out this
way. Tiles the CPU writes every step (CPU lumped RLC) are pinned fp32.

## Lumped RLC on the GPU

Yes, they can, and they now are by default. The runner's correction (a clean-room port of
openEMS's `Engine_Ext_LumpedRLC` SERIES branch) is purely local: after the E update and excitation,
each element reads its own cell's new voltage, advances six values of ADE history (its last three
`vdn` and `jn`) and writes the corrected voltage back. Nothing couples one element to another, so
it maps straight onto a kernel, `apply_lumped_rlc` (`_f16`, `_q16`), run at the point the CPU
correction used to land.

- `CopperEngine::setLumpedRLC(cells)` hands the elements to the engine; both backends apply them
  (the CPU backend in double, exactly as the runner's callback did). The runner uses it unless
  `COPPER_CPU_LUMPED=1`.
- Elements are grouped by the cell (flat layouts) or (component, tile) (Q16) they correct, one
  thread or half SIMD group owning each group, so elements sharing a cell still apply in order.
- GPU state is float rather than double. `testEngineLumpedRLCMatchesMidStepCorrection` (R, L and C
  all present, 30 steps): CPU engine-side correction bit-identical to the callback; Metal within
  1e-4 relative in every storage mode.
- With no CPU correction left, a step is one command buffer again instead of two with a CPU wait
  between; under `COPPER_FUSED` the elements go inside the fused kernel.
- `CopperEngine::declareMidStepCorrectionCells(cells)` remains for any other MidStepCorrection, so
  the fused kernel can keep its tiles out (and MIXED pin them fp32).

## Fused E+H kernel

`COPPER_FUSED=1` updates E and H in one pass per step (`fusedEH`), so each field is read once and
written once rather than twice each.

- A SIMD group owns a segment of a 4x4 tile column (up to 16 tile planes) and marches *down* it a
  plane at a time. Lanes 0-15 are the tile's cells; lanes 16-23 compute the new E of the column and
  row just past the tile in +x and +y -- cells of neighbouring tiles that the tile's H update needs
  -- and discard it. The new E of the plane above comes from the previous iteration, in registers;
  a segment ending below the top first computes (and discards) the plane above it. Neighbouring
  lanes' E arrive by `simd_shuffle`.
- Since a neighbouring group may already have written its new values, every step reads one buffer
  set and writes the other (ping-pong), doubling field memory. The separate E and H kernels read and
  write the same sets, so the two kinds of tile mix freely.
- A tile is fused only if neither it nor the halo cells it computes need a correction between the
  E and H updates that the fused kernel can't make: CPML, current excitation, and anything declared
  to `declareMidStepCorrectionCells`. Voltage excitation and GPU lumped RLC it applies itself
  (`COPPER_FUSED_CORRECTIONS`, default on), from a per-tile correction list; halo lanes correct a
  neighbour's E from the element's old ADE state, which is ping-ponged like the fields so the owner
  can write the new state in the same pass.
- On CTx1 it takes 52.7% of tiles -- essentially everything outside the CPML shells, which hold 51%
  of this board's cells. The remainder (CPML, and tiles whose halo reaches it) run the separate
  kernels.
- With fp32 tiles it matches the separate kernels to float rounding (`testFusedEHKernelMatchesSeparateKernels`,
  1e-6 relative; `testFusedEHKernelAppliesExcitationAndLumpedRLC` likewise with excitation and lumped
  RLC inside the fused tiles). With Q16 tiles it agrees to Q16 precision and is, if anything, more
  accurate: its H update uses the new E straight from registers, where the separate H kernel reads
  it back after rounding.

## Performance

CTx1, first port, run to the -60 dB criterion (about 23,600-24,000 steps in every configuration),
one run at a time with the machine otherwise idle. Wall time and GPU busy time per step, averaged
over the whole port from `COPPER_GPU_TIMING`'s per-100-step reports; Metal memory is the engine's
peak allocation.

| Field storage | Kernels | CPU lumped RLC | GPU lumped RLC | Metal memory |
|---|---|---|---|---|
| fp32 (default) | separate | 9.55 ms (GPU 8.89) | **9.29 ms** (8.83) | 1.64 GB |
| Q16 tiles | separate | 8.03 ms (7.18) | **7.69 ms** (7.04) | 1.49 GB |
| Mixed Q16/fp32 | separate | 8.40 ms (7.46) | **8.25 ms** (7.60) | 2.00 GB |
| Mixed Q16/fp32 | fused E+H | 9.84 ms (8.90) | 9.88 ms (9.24) | 2.83 GB |
| Q16 tiles | fused E+H | -- | 8.42 ms (7.77) | 1.81 GB |
| fp32 tiles (`PIN_ALL`) | separate | -- | 10.18 ms (9.50) | 2.00 GB |
| fp32 tiles (`PIN_ALL`) | fused E+H | -- | 13.07 ms (12.41) | 2.83 GB |

- **Q16 tiles**: 17% faster than fp32 (7.69 vs 9.29 ms) at the same convergence.
- **Mixed**: 11% faster than fp32 (8.25 ms), with the accuracy above. It needed two fixes to get
  there: the field read's fp32 branch hoisted to once per tile (it had made mixed *slower* than fp32,
  9.48 ms), and the all-time peak read from a snapshot instead of atomically by every tile.
- **GPU lumped RLC**: 1-4% faster than the CPU correction (9.55 -> 9.29 ms fp32, 8.03 -> 7.69 Q16).
  The pipelined encoder was already hiding most of the mid-step round trip.
- **Fused E+H**: slower in every storage mode -- +9% (Q16), +20% (mixed), +28% (fp32 tiles) -- even
  though it reads each field half as often. Segment length doesn't matter (4 to 64 tile planes all
  within 0.5%), so it isn't the z-march's serial latency. The cost is lane work: per tile, 16 lanes
  own cells, 8 recompute neighbours' E as halo (reading neighbouring tiles' fields and coefficients
  again) and 8 idle, so each owned cell costs ~4 lane-slots of work against the separate kernels' 2.
  These kernels are not bandwidth-bound enough on this GPU for the traffic saved to pay for that.

**16x16 footprint (follow-up).** The fused kernel now runs one 288-thread threadgroup per 4x4-tile
footprint, exchanging neighbours' new E *and* old H through threadgroup memory (~6.9 KB, two
barriers per plane) and carrying each cell's own H(z), H(z-1) and E(z+1) down the column in
registers. Same run, separate vs fused, ms/step: Q16 8.44 vs 8.59 (+2%, was +9%), mixed 8.22 vs
9.03 (+10%, was +20%), fp32 tiles 10.39 vs 11.70 (+13%, was +28%). Closer, but still not a win.

**Per-kernel profile** (`COPPER_PROFILE_KERNELS=1`: each kernel category in its own encoder with
start/end GPU timestamps; serial loop; CTx1, ~600 steps in), GPU ms per step:

| | fused E+H | update E | CPML E | update H | CPML H | total |
|---|---|---|---|---|---|---|
| fp32 | -- | 1.95 | 2.85 | 1.87 | 2.82 | 9.49 |
| Q16 | -- | 1.15 | 2.23 | 1.10 | 2.17 | 6.67 |
| Q16 + fused | 1.47 | 0.57 | 2.21 | 0.57 | 2.16 | 6.98 |
| Mixed | -- | 1.51 | 2.28 | 1.45 | 2.22 | 7.56 |
| Mixed + fused | 2.06 | 0.63 | 2.21 | 0.62 | 2.17 | 7.76 |

(Excitation, lumped RLC and retile are 0.01-0.07 ms each.) The fused kernel covers 52.7% of tiles;
the separate kernels would do those for 0.527 x (1.15 + 1.10) = 1.18 ms in Q16 and 1.56 ms in mixed,
so per owned tile it is ~24% (Q16) to ~30% (mixed) slower. The rest is accounted for: the separate
kernels on the other tiles cost exactly their share, so ping-pong itself is free. Segment length 16
is best (4: 2.41 ms, 8: 2.17, 16: 2.04, 48: 2.20 in mixed) and compiling out the in-kernel
excitation/lumped lookups saves only ~0.1 ms (mixed) / ~0.02 ms (Q16). The remaining cost is per-cell
work the fused kernel adds: halo E (+12.5% of E work) and each segment's discarded top plane (+6%),
two threadgroup barriers and shared-memory round trips per plane. Occupancy and limiter counters
need Xcode: `MTL_CAPTURE_ENABLED=1 COPPER_GPU_CAPTURE_STEP=n COPPER_GPU_CAPTURE_PATH=...` writes a
`.gputrace` of one step. (A profiler gotcha: an empty encoder at the end of a command buffer was
timestamped as several ms; sections now open only around real dispatches.)

### Where the time goes

(Before [Separable CPML](#separable-cpml).) The six CPML shells of CTx1 hold 11.6M of its 22.9M cells (counting edges and corners once per shell; 10.5M distinct), and each stores per cell, per side, the
b/c coefficients of all three grading axes and two psi values per field component: 24 floats (96
bytes) per CPML cell, ~1.1 GB of the fp32 run's 1.64 GB. The correction kernels then make a second
pass over those cells after each update. Skipping the CPML dispatches altogether (timing only --
it removes the absorber) cut a step from 14.0 to 6.3 ms in fp32 and 14.9 to 7.1 ms in Q16: roughly
half of every step is CPML. (Those four runs shared the GPU with another application, so only their
ratio means anything; the table above was measured on an idle machine.)

That also explains the modest gains elsewhere: Q16 shrinks only the field half of the traffic, and
the fused kernel can only take the non-CPML half of the grid.

## Separable CPML

The CPML is no longer six per-face shells with per-cell coefficients and a correction pass of its
own (it's the default -- nothing here is opt-in except the psi formats). `copper::CopperCPML` holds,
per axis:

- **1-D coefficient tables.** b/c for the E and H sides per grid line along the axis. The grading
  was always separable -- `computeBaseGrading`/`finishGrading` only ever read the coordinate along
  the axis being graded -- so the per-cell arrays just repeated these tables 10M times.
- **psi only where it can be non-zero.** Along axis w only the two components transverse to w have
  a curl term driven along w, and that term's psi is identically zero outside w's slabs. So each
  axis stores two psi arrays over its own slabs (laid out like the grid with w's extent replaced by
  its layer count): 4 floats per slab cell per axis, where each shell cell stored 12 psi and 12 b/c.
- **No second pass.** The correction needs exactly the curl differences the update already read, so
  it's folded into `update_e/h_interior` (`_cpml` variants for all three axes; `_zcpml` for the
  irregular domain's Z slabs, which used to be a separate structure doing the same thing for Z
  alone). The CPU backend applies it as a pass after its update, with identical arithmetic.

Edges and corners are just where two or three axes' slabs overlap; nothing needs deduplicating.
psi0 - psi1 is summed in the same order as before, so the CPU backend is bit-identical to the old
per-shell CPU code (CPML cavity, impulses in faces, edges and corners, 80 steps), and the Metal fold
matches it to 6e-7 of peak.

Measured on the board as saved on 2026-10-03 18:58 (the sections above used the version before it:
GND stitching vias since removed, 593 lumped RLC cells instead of 581, CRx1 456 x 543 x 87). CTx1's
grid is unchanged, 503 x 524 x 87, with a 16-cell CPML (33 lines per axis): 10.47M cells lie in some
axis's slabs. (The 11.6M quoted above counted edge and corner cells once per shell covering them.)

### Step by step

GPU ms per step (`COPPER_PROFILE_KERNELS=1`, CTx1 first port, steps ~300-1500), fp32 fields, all four
measured in one session on the previous version of the board (same grid and CPML):

| | update E | CPML E | update H | CPML H | total | Metal memory |
|---|---|---|---|---|---|---|
| Per-face shells (before) | 1.74 | 2.68 | 1.72 | 2.59 | **8.73** | 1.64 GB |
| 1. 1-D b/c tables, shell psi, separate pass | 1.82 | 1.97 | 1.81 | 1.93 | 7.54 | 1.07 GB |
| 2. + psi on each axis's slabs only | 1.77 | 1.37 | 1.75 | 1.33 | 6.23 | 0.77 GB |
| 3. + folded into the update kernels | 2.18 | -- | 2.14 | -- | **4.34** | 0.77 GB |

On the current board the end points are 8.59 -> 4.21 ms.

Each step removes the traffic it targets: the tables take ~0.6 ms of coefficient reads off each
CPML pass, slab psi another ~0.6, and folding removes the second pass's own field reads and writes.
What's left is psi: the folded update E moves 870 MB of fields and coefficient indices plus 186 MB
of psi read-modify-write, ~1.06 GB in 2.12 ms (current board), ~500 GB/s -- the same rate as the
plain update. CPML is now ~0.85 ms (20%) of an fp32 step instead of 60%.

With the other field formats, early (steps 300-1500) and late (8,000-9,500) in the run -- mixed's
cost depends on how many tiles are fp32 at the time:

| | fp32 | Q16 | Mixed | Metal memory |
|---|---|---|---|---|
| Per-face shells | 8.59 / 9.03 ms | 6.69 / 7.07 ms | 7.09 / 8.12 ms | 1.64 / 1.49 / 2.00 GB |
| Separable CPML | **4.21 / 4.39 ms** | **2.96 / 3.34 ms** | **4.50 / 4.24 ms** | 0.77 / 0.61 / 1.13 GB |

Wall time to convergence, CTx1 first port, two runs each, before and after interleaved (the
machine is someone's laptop: a first pass, run while it was in use, read up to 25% slow for both
versions, so only interleaved pairs are quoted):

| | Before | After | |
|---|---|---|---|
| fp32 | 9.36 / 9.52 ms (GPU busy 8.93 / 9.02) | **4.82 / 4.90 ms** (4.38 / 4.40) | -49% |
| Q16 | 8.45 / 8.11 ms (7.83 / 7.56) | **3.99 / 3.83 ms** (3.45 / 3.25) | -52% |
| Mixed | 9.34 / 8.78 ms (7.44 / 8.13) | **4.21 / 4.67 ms** (3.62 / 4.10) | -50% |

The irregular domain (as the app runs it, through `copper_fdtd_worker`, CTx1, 1500 steps) already
had a folded Z-only CPML, now the same code with X and Y compiled out: 4.12 -> 4.09 ms, unchanged.

### Accuracy

Every S-parameter of CTx1 and CRx1 (4 driven ports) against the fp32 reference (per-face shells),
both run with `COPPER_END_CHECK_STEPS=200` so each port stops at a step that doesn't depend on
machine speed (see [End criterion](#end-criterion)); the fp32 GPU path is deterministic run to run
(two identical runs, 3000 steps x 2 ports, byte-identical probes).

| Run | Main paths worst / median | Paths at -30..-20 dB | Worst path vs own peak | Steps (4 ports) |
|---|---|---|---|---|
| fp32 reference | -- | -- | -- | 23,600 / 47,000 / 33,000 / 27,800 |
| Separable CPML, fp32 | -117 / -120 dB* | -137 dB* | -101.5 dB | identical |
| Separable CPML, mixed fields | -117 / -117 dB* | -131 dB* | -73.7 dB | identical |

\* At the CSVs' resolution: Sx*.csv carries 6 significant digits, so a near-unity path can't
differ by less than ~1e-6 (-120 dB) -- the main paths agree to every digit recorded. The last
column, relative to each path's own peak, isn't floored that way.

So the restructuring itself is invisible at the S-parameter level, and so is the grading fix below.
Mixed fields stay well inside what the earlier [verification](#verification) found (-28 dB worst
path vs own peak there was dominated by where each run stopped).

### Reduced-precision psi

psi is now the only CPML traffic, so 16-bit psi was tried (`COPPER_CPML_PSI`, see
[Configurations](#configurations)). It would be worth ~9% (profile: fp32 fields 4.21 -> 3.85 ms,
Q16 2.96 -> 2.69 ms; wall time, fp32 fields 4.80 -> 4.39 ms, mixed 4.38 -> 4.03 ms) and 0.09 GB.
**It isn't stable, in any form tried, so psi stays fp32.** On the board:

- **bf16, round to nearest** grows without bound after ~22,000 steps (CTx1 port 1).
- **fp16, scaled per side** (2^40 for E, 2^30 for H, from this board's psi range -- 1e-13..1e-9 on
  the E side, 1e-10..5e-7 on the H side, so any scale is board-specific) goes NaN by ~30,000 steps.
- **bf16, stochastically rounded** converges on CTx1's first port exactly like fp32 (same stop step)
  but grows exponentially on its second, from ~27,000 steps.

Two separate things are going on:

1. **Stagnation.** Where b is close to 1, a step's change to psi is often under half an ulp, so
   round-to-nearest loses it every step and psi freezes off zero. Stochastic rounding fixes that --
   but only with a dither that's fresh every step. The first version hashed the dither from the cell
   and the value, which makes rounding a fixed function of the value: b * psi can then round straight
   back to psi forever, exactly as with round to nearest (a scalar model of the recursion with the
   drive switched off: fp32 and per-step dither decay 400x in 30,000 steps; round to nearest and the
   value-hashed dither don't move). The dither is now hashed from the cell and a per-step seed.
2. **A precision threshold.** Even with proper stochastic rounding, too few bits make the coupled
   system grow exponentially. `COPPER_CPML_PSI=dropN[sr]` stores psi as fp32 with its low N mantissa
   bits rounded away, to find where (CPML cavity, impulses seeded, 32,000 steps; fp32 settles at
   the impulses' static remnant):

   | explicit mantissa bits kept | 15+ | 11 | 10 (fp16) | 9 | 8 | 7 (bf16) |
   |---|---|---|---|---|---|---|
   | stochastic | stable | stable | +4% energy by 32k steps | grows (x2.7e5 per 16k steps) | grows fast | explodes |
   | round to nearest | stable | +2% by 16k steps | grows | grows fast | explodes | explodes |

   The threshold barely moves when alpha (the CFS damping at the inner layers) changes tenfold, so
   it isn't the rounding step outgrowing the inner layers' 1 - b. Nor is psi's rounding error large
   next to the field's change: on the board's snapshots |psi| is a median 0.03-0.07 of the net curl
   it corrects (1% of Z-slab cells exceed 10x), so 16-bit psi perturbs the update by ~1e-4 of the
   curl per step -- yet the growth rate is ~2e-3 per step at 8 bits and rises ~2.7x per bit dropped,
   between what a bias (2x) and a variance (4x) would give.

3. **It takes both sides.** Rounding only one side's psi doesn't grow (`COPPER_CPML_PSI_SIDE`, same
   cavity, up to 64,000 steps). Which side is exact depends on the static field the impulses leave
   behind: with magnetic seeds (a static H remnant, which drives the E side's psi), bf16 on the H
   side matches fp32 to four digits and stochastic bf16 on the E side settles 1% high; with electric
   seeds it's the other way round (E side exact, H side 3% high). Round to nearest on the driven
   side also creeps up through stagnation (4x by 64,000 steps). With both sides bf16 it explodes by
   step 8,000 whatever the seeds, and removing alpha makes it grow faster -- a loop through both psi
   recursions and the fields between them, which alpha damps. The exact mechanism is still open.

So with both sides reduced, psi needs 11 explicit mantissa bits on this fixture, with stochastic
rounding (more on a board that runs 47,000 steps): fp16's 10 is marginal -- the board's NaN -- and
bf16's 7 hopeless. **One side's psi alone tolerates bf16**, a quarter of the psi traffic: on the
board, stochastic bf16 on the H side (`COPPER_CPML_PSI=bf16sr COPPER_CPML_PSI_SIDE=H`) stops at the
reference's steps on all four ports, main paths at the CSVs' resolution, worst path -78.3 dB below
its peak -- but it's only worth ~4% (fp32 fields 4.86 -> 4.63 ms; mixed within run-to-run noise).

### A thinner CPML

With psi as the CPML's only cost, its thickness is the remaining lever: `kiems::constants::pmlDepthCells`
= 16 dedicated cells beyond the board's mesh on every face (33 of CTx1's 87 z-planes). An 8-cell
build (geometry regenerated) shrinks CTx1 to 487 x 508 x 71 = 17.6M cells (-23%) with half the psi:

| CTx1 first port, wall | 16 cells | 8 cells | |
|---|---|---|---|
| fp32 | 4.82 / 4.90 ms, 0.77 GB | **3.51 ms**, 0.54 GB | -28% |
| Mixed | 4.21 / 4.67 ms, 1.13 GB | **3.63 ms**, 0.81 GB | -18% |

Against the 16-cell fp32 reference, three of the four ports stop at the same step and agree to the
CSVs' resolution on the main paths, within -64..-68 dB of every path's own peak. CTx1's first port
reaches -60 dB 1,400 steps sooner (22,200) -- the thinner absorber leaves less ringing behind -- and
its truncated tail shows: main paths -79 dB, the weakest (-54 dB) path only -13 dB below its peak.
Run to the reference's 23,600 steps instead, that port agrees to the CSVs' resolution on its main
paths and to -80.3 dB of every path's peak (median -87.6): the difference was the earlier stop, not
the absorber. So on this board 8 cells absorbs as well as 16 to ~-80 dB. Not adopted here -- it's a
change to grid generation and the absorber's design margin, worth checking on other boards first.

### A grading bug the restructuring exposed

`computeBaseGrading` measured depth as `width - (line(pos) - line(0)) * delta`. Clang contracts that
to an FMA, so at the PML's inner edge (pos = depth) the result was width's own rounding error rather
than exactly 0 -- and `defaultSigmaGrading` returns its full inner-edge value for any depth above 0
(the profile is geometric: 2.5^0 = 1). Wherever `(line(depth) - line(0)) * delta` rounded up, the
plane at the inner edge was graded: on this board the lower x, y and z faces and the upper x and y
faces. Under the per-face shells the lower faces' inner plane was graded only where another face's
shell covered it -- a non-separable stretch, the thing CopperCPML.hpp warns about. Depth is now
measured from the inner edge, `(line(depth) - line(pos)) * delta`, exactly 0 there.
`testCPMLGradesEachAxisOnExactlyItsSlabs` fails with the old formula (uniform 1 mm mesh, depth 9:
9 * 1e-3 rounds up). Its effect here was negligible -- the spurious sigma was 1.4e-5 S/m against
33 S/m at the outer edge, and on the previous version of the board the old per-face shells with
and without the fix agree to -119 dB on CTx1's port probes -- but it's the kind of error that grows
with coarser or more irregular meshes.

## Verification

Unit tests (CopperTests) pass with the suite run in each of: fp32 (default), `COPPER_FIELD_Q16`,
`COPPER_FIELD_MIXED`, `MIXED`+`COPPER_FUSED`, `Q16`+`FUSED`, and `MIXED`+`FUSED`+
`COPPER_FUSED_CORRECTIONS=0` (e.g. `TEST_RUNNER_COPPER_FIELD_MIXED=1 xcodebuild ... test`).
Exact-match parity checks relax to 1e-4 under Q16/MIXED (`fieldParityTolerance`). Under the
superseded `COPPER_FIELD_FP16` two still fail, both on values near the bottom of half precision's
range (probe parity: 28% error on ~7e-5 V) -- one reason Q16 replaced it.

New tests:

- `testQ16TinyCellWritesStayFinite` -- the CPU encoder's subnormal-scale NaN (fails without the fix).
- `testFusedEHKernelMatchesSeparateKernels` -- fused vs separate over a CPML cavity, fp32 and Q16 tiles.
- `testFusedEHKernelAppliesExcitationAndLumpedRLC` -- excitation and lumped RLC inside fused tiles.
- `testEngineLumpedRLCMatchesMidStepCorrection` -- engine-side lumped RLC vs the CPU callback.
- `testCPMLGradesEachAxisOnExactlyItsSlabs` -- each axis graded on exactly its slabs, inner edges
  exactly ungraded, on uniform and graded meshes (fails with the old FMA-prone depth formula).
- `testZOnlyCPMLGradesExactlyLikeTheFullCPMLsZAxis` -- the irregular domain's CPML is the full one's Z axis.
- `testFoldedCPMLMatchesTheCPUBackend` -- Metal's folded CPML vs the CPU's separate pass, all faces and
  Z only, impulses in faces, edges and corners (2e-4 of peak under Q16, which accumulates ~1e-4 here
  with or without a CPML; 6e-7 in fp32). The per-shell CPML tests it replaces are gone with the shells.

Board runs, CTx1 + CRx1 to convergence, against the fp32 reference (CPU lumped RLC):

| Run | Main paths worst / median | Paths at -30..-20 dB | Worst path vs own peak | Steps (4 ports) |
|---|---|---|---|---|
| Mixed, separate kernels (CPU lumped)* | -84.5 / -100.0 dB | -84.7 dB | -28.0 dB | 23,723 / 47,180 / 32,799 / 28,476 |
| Mixed + fused + GPU lumped | -96.0 / -110.6 dB | -88.1 dB | -32.6 dB | 23,887 / 47,126 / 32,921 / 28,455 |
| fp32 + GPU lumped | -69.5 / -86.2 dB | -65.9 dB | -16.8 dB | 23,709 / 47,287 / 31,078 / 28,346 |

\* Run before mixed mode's performance fixes, which change nothing computed except that the all-time
peak a promotion is judged against may lag by up to 8 steps.

The fp32 + GPU lumped row is worse than either mixed run, and the cause isn't the GPU correction:
its fields match the CPU-corrected run to 7e-7 relative at step 3000 (CRx1 snapshots). It is the
**stop criterion**. CRx1's first port spends thousands of steps beating between 52 and 61 dB of
energy decay, and the runner checks the -60 dB criterion only when it prints progress, every 4
seconds of wall-clock time -- so where a run stops depends on how fast the machine is going. That
run happened to sample a 60.15 dB peak at step 31,078 and stopped; the reference sampled 59.4 and
58.9 dB either side and ran on to 33,094. Truncating the probe series 2,000 steps apart accounts for
CRx1's -70 dB-level differences (CTx1, which decays smoothly, agrees to -96..-117 dB on its thru and
return-loss paths). The mixed + fused run stopped close to the reference by chance, which flatters
its CRx1 numbers somewhat.

## Limitations and next steps

- **CPML is psi traffic now.** ~0.85 ms of a 4.2 ms fp32 step is psi read-modify-write
  (186 MB per side). 16-bit psi isn't stable (see [Reduced-precision psi](#reduced-precision-psi)).
  The CPML is 16 cells deep on every face -- 33 of CTx1's 87 z-planes are Z slabs, holding 75% of
  all psi -- so its thickness is the lever left: 8 cells is 28% faster again, see
  [A thinner CPML](#a-thinner-cpml).
- **The fused kernel needs a bigger footprint to pay.** A 16x16-cell threadgroup (4x4 tiles, 288
  threads, neighbours' E exchanged through threadgroup memory) would cost ~2.25 lane-slots per cell
  against the separate kernels' 2 while still halving field reads. It would also have to take the
  CPML in to cover this board (half of it) -- easier now it's part of the update -- and doesn't
  support irregular domains (falls back to the separate kernels with a warning).
- Mixed precision's thresholds (50 dB promote, 10 dB hysteresis, retile every 8 steps) were chosen
  from one board's snapshots; untested elsewhere.
- GPU lumped RLC state is float (the CPU's was double); agreement is checked on a single-element
  fixture and through the board S-parameters, not on long-running stiff RLC combinations.
- Ping-pong doubles field memory (2.83 GB vs 2.00 GB mixed). The CPU-side field accessors follow
  whichever set is live, including mid-step for a MidStepCorrection.
- <a id="end-criterion"></a>**The end criterion is checked on wall-clock time** (every 4 s, at the
  progress print), so on a board whose energy decay beats around -60 dB the stop step -- and the
  S-parameters, at the ~-70 dB level -- depend on machine speed and load. `COPPER_END_CHECK_STEPS=N`
  checks it every N steps instead (with its own peak, so the 4 s ticks can't influence it), which
  makes runs reproducible: the fp32 GPU path is deterministic run to run. Worth making the default.
- The run stops on energy decay only: a run that goes NaN (as `fp16` psi did) runs to max_steps.
- Nothing here is committed.
