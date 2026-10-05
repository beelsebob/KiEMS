# Board-load timing

Record an app launch and document open with Time Profiler and the os_signpost
instrument (Points of Interest). Filter signposts to subsystem `com.kiems`,
category `BoardLoad`. Use the same board and build configuration for comparisons.

Swift stages have individual interval names. C++ stages use `Board load phase`
with the phase name in the interval metadata. Each invocation has a unique ID,
so overlapping queries and parallel copper groups remain separate intervals.

Useful boundaries:

- Source list refresh: includes queue delay and installing the resulting rows.
  Its nested queries-and-nodes interval measures background work.
- KiCad lock wait, file validation, cold load, project parse, board parse, and
  footprint pad walk distinguish listing cost from loading and contention.
- Board geometry extraction includes KiCad text/artwork expansion, reported
  separately for front and back silkscreen.
- Copper parallel pass contains per-group intervals with layer/group identity,
  input polygon count, and input vertex count. Sort by duration to locate the
  tail, then inspect those intervals in Time Profiler.
- Component export snapshot measures input copying, path resolution and embedded-file
  materialisation while holding the board lock. Component exporter lock wait measures
  contention between exports on the separate OCCT lock. Component export without board
  lock covers model construction, output and triangle extraction after releasing the
  board lock; ordinary queries can run during this interval.
- Component export measures background work; component export remaining wait
  measures only the time the preview caller still waits after other work.
- Copper Cocoa objects, solder mask geometry, silkscreen geometry, and component
  Cocoa objects cover the subsequent preview construction stages.
- Geometry chunks (including uncached layer chunks), merge and remap, and Metal
  buffers break down assembly. Cached chunks do not emit a layer-build interval.
- Geometry main queue delivery measures the delay between completed assembly
  and the main-thread callback. Install board geometry includes activity updates.
- Geometry view and pipelines covers view setup, including synchronous pipeline
  creation; use its samples to distinguish shader compilation from other setup.
- Board installed to presentation ends in the drawable's presented callback;
  First board frame submitted marks CPU submission within that interval. This
  measures the first draw after installation, not every steady-state frame.
  Multiple installs before a draw share the earliest pending interval. A hidden
  view that never draws leaves that interval open.

Intervals overlap: do not sum their durations as total document-open time.
Group identities are recorded as public metadata, including net and footprint
names, so they remain readable in exported traces.
