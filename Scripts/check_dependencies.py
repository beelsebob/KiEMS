#!/usr/bin/env python3
"""Checks everything kiems builds against: the Homebrew formulas, at the versions the Xcode project
expects; and the git submodules. Offers to install anything missing, after asking.
Missing formulas are errors; version mismatches are warnings.

Usage: Scripts/check_dependencies.py [--yes] [--ssh]
  --yes   answer "yes" to every prompt (for unattended setup)
  --ssh   fetch GitHub submodules over ssh (git@github.com:) instead of https; this is recorded in
          the clone's local git config, and a later run without --ssh switches back to https

Submodules that have their own Scripts/check_dependencies.py (Copper, libkicad) declare their own
requirements; this script gathers and installs them along with kiems' own, and runs each one's
setup, so one run sets up everything. See dependency_tool.py for how repositories cooperate.

On success writes the untracked Config/DependenciesChecked.generated.h; until it exists every
Xcode compile stops with an #error from Config/DependencyCheck.h. The script never runs from Xcode.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dependency_tool import Context, Formula, Repository, main  # noqa: E402

# kiems' own needs; Copper's (CSXCAD, HDF5, VTK, ...) come from submodules/Copper and KiCad's from
# submodules/libkicad. A prefix of "1.2" accepts 1.2, 1.2.8, 1.2.8_1, ... but not 1.3; it is the
# version last verified with.
HOMEBREW = [
    Formula("geos",            "3.15", "kiems executables (link CopperUtils)"),
    Formula("matplotplusplus", "1.2",  "libkiems (plots)"),
    Formula("gnuplot",         "6.0",  "libkiems (matplot++ rendering backend, runtime)"),
    Formula("nlohmann-json",   "3",    "libkiems"),
]

SUBMODULES = ["submodules/Copper", "submodules/RememberRemember", "submodules/libkicad"]


def configure(ctx: Context) -> None:
    # Config/BuildPaths.xcconfig holds machine-specific settings; make its untracked override
    # match this machine.
    ctx.set_build_setting("Config/BuildPaths.xcconfig", "HOMEBREW_PREFIX", str(ctx.brew_prefix))


if __name__ == "__main__":
    sys.exit(main(__file__, Repository(
        name="kiems",
        homebrew=HOMEBREW,
        submodules=SUBMODULES,
        stamp="Config/DependenciesChecked.generated.h",
        configure=configure,
    )))
