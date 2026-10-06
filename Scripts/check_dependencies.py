#!/usr/bin/env python3
"""Checks everything kiems builds against: the Homebrew formulas, at the versions the Xcode project
expects; the git submodules; and the KiCad build. Offers to install anything missing, after asking.
Missing formulas are errors; version mismatches are warnings.

Usage: Scripts/check_dependencies.py [--yes] [--ssh]
  --yes   answer "yes" to every prompt (for unattended setup)
  --ssh   fetch GitHub submodules over ssh (git@github.com:) instead of https; this is recorded in
          the clone's local git config, and a later run without --ssh switches back to https

Submodules that have their own Scripts/check_dependencies.py (Copper) declare their own
requirements; this script gathers and installs them along with kiems' own, and runs each one's
setup, so one run sets up everything. See dependency_tool.py for how repositories cooperate.

On success writes the untracked Config/DependenciesChecked.generated.h; until it exists every
Xcode compile stops with an #error from Config/DependencyCheck.h. The script never runs from Xcode.
"""
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dependency_tool import Context, Formula, Repository, main  # noqa: E402

# kiems' own needs; Copper's (CSXCAD, HDF5, VTK, ...) come from submodules/Copper. A prefix of "3.2"
# accepts 3.2, 3.2.8, 3.2.8_1, ... but not 3.3. Where the project hard-codes a version (wx-3.2
# include paths) a mismatch will break the build; elsewhere it is the version last verified with.
HOMEBREW = [
    Formula("geos",            "3.15", "kiems executables (link CopperUtils)"),
    Formula("matplotplusplus", "1.2",  "libkiems (plots)"),
    Formula("gnuplot",         "6.0",  "libkiems (matplot++ rendering backend, runtime)"),
    Formula("nlohmann-json",   "3",    "libkiems"),
    Formula("boost",           "1.90", "KiCad headers"),
    Formula("wxwidgets@3.2",   "3.2",  "KiCad headers (wx-3.2 include paths)"),
    Formula("glm",             "1.0",  "KiCad headers"),
    Formula("cairo",           "1.18", "KiCad headers"),
    Formula("pixman",          "0.46", "KiCad headers"),
    Formula("freetype",        "2.14", "KiCad headers"),
    Formula("harfbuzz",        "14",   "KiCad headers"),
    Formula("opencascade",     "7.9",  "KiCad link (libTK*.dylib)"),
    Formula("cmake",           "4",    "KiCad build (Scripts/build_kicad.sh)"),
    Formula("ninja",           "1.13", "KiCad build"),
    Formula("pkgconf",         "3",    "KiCad build"),
    Formula("libngspice",      "46",   "KiCad build"),
    Formula("libgit2",         "1.9",  "KiCad build"),
    Formula("nng",             "1.12", "KiCad build"),
    Formula("zstd",            "1.5",  "KiCad build"),
    Formula("protobuf",        "35",   "KiCad build"),
    Formula("fontconfig",      "2.18", "KiCad build"),
    Formula("unixodbc",        "2.3",  "KiCad build"),
]

SUBMODULES = ["submodules/Copper", "submodules/RememberRemember", "submodules/kicad", "submodules/libkicad"]

# libkicad links pieces of the KiCad submodule built by Scripts/build_kicad.sh (too slow to run from
# Xcode), which records the submodule commit it built; a build from another commit is out of date.
KICAD_PRODUCTS = [
    "common/libcommon.a", "common/libpcbcommon.a",
    "kicad/KiCad.app/Contents/Frameworks/libkicommon.dylib",
    "kicad/KiCad.app/Contents/Frameworks/libkigal.dylib",
    "kicad/KiCad.app/Contents/Frameworks/libkiapi.dylib",
]


def kicad_build_problem(root: Path) -> str:
    build = root / "build/kicad"
    if not all((build / product).exists() for product in KICAD_PRODUCTS):
        return "build/kicad is missing or incomplete"
    stamp = build / ".built-commit"
    built = stamp.read_text().strip() if stamp.exists() else ""
    current = subprocess.run(["git", "-C", str(root / "submodules/kicad"), "rev-parse", "HEAD"],
                             capture_output=True, text=True).stdout.strip()
    if not built:
        return "build/kicad doesn't record which KiCad commit it was built from"
    if built != current:
        return f"build/kicad was built from {built[:10]}, submodules/kicad is at {current[:10]}"
    return ""


def configure(ctx: Context) -> None:
    # Config/BuildPaths.xcconfig holds machine-specific settings; make its untracked override
    # match this machine.
    ctx.set_build_setting("Config/BuildPaths.xcconfig", "HOMEBREW_PREFIX", str(ctx.brew_prefix))

    problem = kicad_build_problem(ctx.root)
    if problem and ctx.confirm(f"{problem}. Run Scripts/build_kicad.sh now?"):
        if subprocess.run([str(ctx.root / "Scripts/build_kicad.sh")]).returncode == 0:
            problem = kicad_build_problem(ctx.root)
    if problem:
        ctx.fail(problem, "build/kicad")
    else:
        ctx.ok("build/kicad")


if __name__ == "__main__":
    sys.exit(main(__file__, Repository(
        name="kiems",
        homebrew=HOMEBREW,
        submodules=SUBMODULES,
        stamp="Config/DependenciesChecked.generated.h",
        configure=configure,
    )))
