# libkiems

`libkiems` is the C++ simulation library behind both KiEMS.app and the `kiems`
command-line tool. It takes a KiCad board and a `simulation.json` configuration
through three pipeline stages:

1. **Geometry** — slice the board into layers and polygons, and place the FDTD grid.
2. **Simulation** — run an FDTD simulation for each excited port and compute
   S-parameters.
3. **Post-processing** — derive impedance, delay, differential-pair, probe and
   eye-diagram data, and save or plot it.

Everything lives in the `kiems` namespace, and the headers are under
[`libkiems/kiems/`](../libkiems/kiems/). The library builds on macOS and Linux.

## Building and linking

The root [`CMakeLists.txt`](../CMakeLists.txt) builds `libkiems` as a static library. To use it from
another CMake target, link the `kiems::libkiems` alias:

```cmake
target_link_libraries(my_tool PRIVATE kiems::libkiems)
```

Include headers by their `kiems/` path:

```cpp
#include "kiems/config.hpp"
#include "kiems/geometry_result.hpp"
```

Building it needs the KiEMS dependencies and the `libkicad` and Copper
submodules; see [Building](../README.md#building).

## Design principles

- **No shared process state.** The library never relies on the current working
  directory, and it has no global state. Every location it reads or writes comes
  from a `PathsConfig`. Configuration and results are plain values that you pass
  around explicitly, so several boards can be open in one process.
- **Errors are values.** Operations that can fail return
  `std::expected<T, std::string>`, with a readable message on failure.
- **Each stage owns its inputs.** A stage's result carries the configuration and
  the previous stage's result forward. Once a run starts, nothing can change the
  configuration underneath it.
- **Each stage can be resumed.** Every stage writes its output to disk and has a
  `load()` that reads it back. A separate process can therefore pick up where an
  earlier one stopped.

## Walkthrough

This is the sequence `kiems --all` runs (see [`kiems-cli/main.cpp`](../kiems-cli/main.cpp)), with error
handling shortened.

### 1. Paths

`PathsConfig::forConfigFile()` derives every working directory from the location
of `simulation.json`:

```cpp
using namespace kiems;

const PathsConfig paths = PathsConfig::forConfigFile(
    "/path/to/simulation.json",
    /* kicadCliPath */ {},
    /* fdtdWorkerPath */ toolDir / "kiems_fdtd_worker",
    /* copperFdtdWorkerPath */ toolDir / "copper_fdtd_worker");
```

| Field | Location |
| --- | --- |
| `fabDir`, `fabBoardFile`, `fabProjectFile` | `fab/`: saved copies of the KiCad board and project |
| `geometryDir` | `ems/geometry/` |
| `simulationDir` | `ems/simulation/` |
| `resultsDir` | `ems/results/` |

The worker paths point to the helper executables that run FDTD in a separate
process. Ship them with your tool. `kicadCliPath` is no longer used.

### 2. Board and configuration

Open the board through `libkicad`, copy it into `fab/`, then parse the
configuration:

```cpp
auto runtime = libkicad::Runtime::create();       // keep alive for as long as any board is

// Use KiCad's autosaved changes if any exist.
KicadSources sources = resolveKicadSources(*runtime, boardPath, paths.fabDir / "kicad-source");
if (auto r = exportKicadPcb(paths, sources.boardPath); !r) { /* r.error() */ }

auto config = EMSConfig::parse(paths.configFile, /* updateConfig */ false);
config->setKicadPcbPath(sources.boardPath);

const libkicad::Board board(*runtime, paths.kicadBoardPaths());
importStackup(board, *config);           // layer thicknesses and dielectric constants
resolveSimulationPorts(*config, board);  // turn net/pin references into ports
```

`EMSConfig` can also be built in code and written out with `save()` or
`toJson()`. `resolveSimulationPorts()` must run in every process that runs a
stage, even when it only loads earlier results, because the later stages need the
resolved ports.

### 3. Run options

```cpp
RunOptions options;
options.backend = FDTDBackend::OpenEMSCPU;   // or FDTDBackend::CopperGPU
options.oversampling = 4;
options.exportField = std::nullopt;          // names of fields to export, if any
options.plotPhase = false;
options.transparent = false;                 // transparent plot backgrounds
```

### 4. Geometry

```cpp
auto geometry = GeometryResult::build(std::move(*config), options, paths, board,
    [](const GeometryProgress& p) {
        // p.simulationName, p.simulationIndex / p.simulationCount, p.phase
    });
```

`build()` processes every simulation in the configuration, keeps the result in
memory and writes it to `geometryDir`. In a later process,
`GeometryResult::load(config, paths)` reads it back.
`simulationData(name)` returns one simulation's sliced board and grid.

### 5. Simulation

```cpp
auto simulation = SimulationResult::run(*geometry, options, board);
```

By default each excited port runs in a separate worker process
(`fdtdWorkerPath`, or `copperFdtdWorkerPath` for the GPU backend). To run a port
some other way, such as Copper's GPU engine inside your own process, pass an
`FDTDPortRunner`:

```cpp
auto simulation = SimulationResult::run(*geometry, options, board,
    [](Simulation& sim, std::int32_t excitedPort) -> std::expected<std::uint32_t, std::string> {
        // sim is already populated, but prepareRunDirectory() has not run:
        // mirror kiems_fdtd_worker/main.cpp or copper_fdtd_worker/main.cpp.
    });
```

`libkiems` never depends on Copper itself, so this is how the CLI and the app run
the GPU backend in-process.

`run()` writes `Sx<port>.csv` files to `simulationDir`. In a later process,
`SimulationResult::load(*geometry, paths.simulationDir)` reads them back. The
results can be read with:

- `getSParam(simulation, outputPort, inputPort)`
- `getProbeVoltage()`, `getProbeCurrent()`, `getProbeTransfer()` and
  `getProbeImpedance()` for passive probe ports
- `sparamToFile()` and `probeToFile()` to write CSVs

### 6. Post-processing

```cpp
auto results = PostprocessResult::compute(*simulation);

auto freqs = results->frequencies("DDR");     // Hz
auto z     = results->getImpedance("DDR", 1);
auto delay = results->getDelay("DDR", 2, 1);

results->saveToFile("DDR", paths.resultsDir / "DDR");
results->renderSParams("DDR", options.plotPhase, options.transparent, paths.resultsDir / "DDR");
results->renderSmith("DDR", options.transparent, paths.resultsDir / "DDR");
```

Each data accessor returns `std::nullopt` when the simulation or port pair
doesn't exist or wasn't simulated. Differential pairs have their own accessors,
`getDiffPairSdd()` and `getDiffPairImpedance()`.

Results are keyed by simulation name, and a single configuration can define
several simulations. Iterate over `config().simulations()` to visit each one.

The render calls write PNGs using Matplot++ with gnuplot. The other render calls
are `renderImpedance()`, `renderDiffPairSParams()`, `renderDiffImpedance()`,
`renderTraceDelays()` and `renderProbes()`.

## Time-domain analysis

- **`ExcitationPostprocessor`** ([`excitation_postprocess.hpp`](../libkiems/kiems/excitation_postprocess.hpp)) rebuilds each
  configured excitation's time-domain response from the S-parameters. It doesn't
  have a result type of its own yet, so it is built from the underlying
  `Postprocessor`, which `PostprocessResult::postprocessorFor(name)` returns.
- **`computeEyeDiagram()`** ([`eye_diagram.hpp`](../libkiems/kiems/eye_diagram.hpp)) builds an eye diagram from a set
  of frequencies, a transfer function (such as an S-parameter or
  `getProbeTransfer()`) and a bit rate. Crosstalk aggressors (`EyeAggressor`),
  noise (`EyeNoiseOptions`) and a mask (`EyeMask`) are optional. It returns the
  eye opening (`EyeOpening`), the mask test (`EyeMaskResult`) and noise
  statistics (`EyeNoiseStatistics`).

## Header overview

| Header | Contents |
| --- | --- |
| [`config.hpp`](../libkiems/kiems/config.hpp) | `EMSConfig`, `SimulationConfig`, `PortConfig`, `RunOptions`, `FDTDBackend` |
| [`paths_config.hpp`](../libkiems/kiems/paths_config.hpp) | `PathsConfig` |
| [`importer.hpp`](../libkiems/kiems/importer.hpp) | Board import: `resolveKicadSources()`, `exportKicadPcb()`, `importStackup()`, vias and holes |
| [`port_resolution.hpp`](../libkiems/kiems/port_resolution.hpp) | `resolveSimulationPorts()` |
| [`geometry_result.hpp`](../libkiems/kiems/geometry_result.hpp) | Stage 1: `GeometryResult` |
| [`simulation_result.hpp`](../libkiems/kiems/simulation_result.hpp) | Stage 2: `SimulationResult` |
| [`postprocess_result.hpp`](../libkiems/kiems/postprocess_result.hpp) | Stage 3: `PostprocessResult` |
| [`postprocess.hpp`](../libkiems/kiems/postprocess.hpp) | `Postprocessor`, which does the per-simulation S-parameter maths and plotting |
| [`excitation_postprocess.hpp`](../libkiems/kiems/excitation_postprocess.hpp), [`fft_postprocess.hpp`](../libkiems/kiems/fft_postprocess.hpp) | Time-domain responses |
| [`eye_diagram.hpp`](../libkiems/kiems/eye_diagram.hpp) | Eye diagrams and mask testing |
| [`simulation.hpp`](../libkiems/kiems/simulation.hpp), [`simulation_data.hpp`](../libkiems/kiems/simulation_data.hpp) | A single FDTD run, and the per-stage simulation data |
| [`board_slicing.hpp`](../libkiems/kiems/board_slicing.hpp), [`grid_gen.hpp`](../libkiems/kiems/grid_gen.hpp), [`gerber_io.hpp`](../libkiems/kiems/gerber_io.hpp) | Geometry and grid internals |
| [`ports.hpp`](../libkiems/kiems/ports.hpp), [`component_sim_model.hpp`](../libkiems/kiems/component_sim_model.hpp), [`component_value.hpp`](../libkiems/kiems/component_value.hpp) | Port and component models |

## Tests

`libkiems_tests` uses XCTest, so it only runs on macOS. Run it with
[`Scripts/run_libkiems_tests.sh`](../Scripts/run_libkiems_tests.sh), or with the `libkiems_tests` scheme in Xcode.
