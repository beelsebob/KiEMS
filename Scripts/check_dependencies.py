#!/usr/bin/env python3
"""Checks everything kiems builds against, on macOS or Linux, and optionally installs what is
missing.

Usage: Scripts/check_dependencies.py [--component NAME]... [--install [--yes]] [--no-configure] [--ssh]
  --component   check only build, kiems, copper or libkicad; repeatable; omit to check everything
  --install     install missing packages, after asking
  --yes         answer "yes" to the install prompt (for unattended setup); requires --install
  --no-configure  skip the setup and validation that follow the package check
  --ssh         (macOS) fetch GitHub submodules over ssh (git@github.com:) instead of https; this is
                recorded in the clone's local git config, and a later run without --ssh switches back

Both platforms check out the git submodules, check the packages of the selected components, print
the command that installs the missing ones (running it only with --install), then set up and
validate the build unless --no-configure is given.

On macOS the packages are Homebrew formulas, at the versions the Xcode project expects; version
mismatches are warnings. Copper and libkicad declare their own formulas in their own
Scripts/check_dependencies.py, and their setup steps run as part of configuring; see
dependency_tool.py for how repositories cooperate. When every component has been checked and set
up, writes the untracked Config/DependenciesChecked.generated.h; until it exists every Xcode
compile stops with an #error from Config/DependencyCheck.h. The script never runs from Xcode.

On Linux the work is done by linux_dependencies.py, from Dependencies/linux-packages.json.
"""
import argparse
import subprocess
import sys
from pathlib import Path
from typing import Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dependency_tool as tool  # noqa: E402
from dependency_tool import Context, Formula, Repository  # noqa: E402

COMPONENTS = ["build", "kiems", "copper", "libkicad"]

# Tools for the optional CMake build; Xcode itself comes from the App Store.
BUILD_HOMEBREW = [
    Formula("cmake", "4", "CMake build"),
    Formula("ninja", "1", "CMake build"),
]

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

# Which --component each submodule's dependency tree belongs to.
SUBMODULE_COMPONENTS = {"submodules/Copper": "copper", "submodules/libkicad": "libkicad"}


def configure(ctx: Context) -> None:
    # Config/BuildPaths.xcconfig holds machine-specific settings; make its untracked override
    # match this machine.
    ctx.set_build_setting("Config/BuildPaths.xcconfig", "HOMEBREW_PREFIX", str(ctx.brew_prefix))


REPOSITORY = Repository(
    name="kiems",
    homebrew=HOMEBREW,
    submodules=SUBMODULES,
    stamp="Config/DependenciesChecked.generated.h",
    configure=configure,
)


def check_build_tools(ctx: Context, install: bool) -> bool:
    """Xcode's command-line tools and Homebrew. Returns whether Homebrew is usable."""
    if subprocess.run(["xcode-select", "-p"], capture_output=True).returncode == 0:
        ctx.ok("Xcode command-line tools")
    else:
        ctx.fail("Xcode command-line tools are not installed; run: xcode-select --install", "Xcode")
    if install:
        return tool.check_homebrew(ctx)
    tool.heading("Homebrew")
    tool.attach_brew(ctx)
    if ctx.brew is None:
        ctx.fail("Homebrew is not installed (https://brew.sh); --install installs it", "Homebrew")
        return False
    ctx.ok(f"{ctx.brew} (prefix {ctx.brew_prefix})")
    return True


def macos_main(args: argparse.Namespace) -> int:
    sys.stdout.reconfigure(line_buffering=True)  # keep our lines in order with git's and brew's
    requested = set(args.component or COMPONENTS)
    ctx = Context(root=Path(__file__).resolve().parent.parent, assume_yes=args.yes, ssh=args.ssh)
    complete = requested == set(COMPONENTS) and not args.no_configure
    tool.stamp_path(ctx, REPOSITORY).unlink(missing_ok=True)

    tool.heading("Build tools")
    have_brew = check_build_tools(ctx, args.install)

    # Every submodule is checked out, as on Linux: the components' requirements are read from them.
    tool.heading("Git submodules")
    me = tool.Child(ctx.root, REPOSITORY.name, HOMEBREW, SUBMODULES)
    consent: list[Optional[bool]] = [True]
    level = [me]
    while level:
        tool.check_submodules(ctx, [tool.Submodule(c.root, p) for c in level for p in c.submodules], consent)
        next_level = []
        for c in level:
            for p in c.submodules:
                nested = tool.read_manifest(c.root / p)
                if nested:
                    c.children.append(nested)
                    next_level.append(nested)
        level = next_level

    selected = [child for child in me.children
                if SUBMODULE_COMPONENTS.get(str(child.root.relative_to(ctx.root))) in requested]
    formulas = (BUILD_HOMEBREW if "build" in requested else []) + \
               (HOMEBREW if "kiems" in requested else []) + \
               [f for child in selected for c in tool.walk(child) for f in c.homebrew]

    if have_brew and formulas:
        tool.heading("Homebrew libraries")
        tool.check_formulas(ctx, formulas, install=args.install)
        missing = sorted({f.formula for f in formulas if ctx.linked_version(f.formula) is None})
        if missing and not args.install:
            print("\nSuggested install command (or rerun with --install):")
            print(f"  {ctx.brew} install {' '.join(missing)}")

    if args.no_configure:
        pass
    elif ctx.errors:
        print(f"\nSkipped setting up {REPOSITORY.name} until the errors above are fixed.")
    else:
        for child in selected:
            for c in tool.walk(child):
                tool.run_child_configure(ctx, c)
        if complete:
            tool.configure(ctx, REPOSITORY)
        else:
            print(f"\n{REPOSITORY.stamp} is only written once every component is checked and set up.")

    print()
    if ctx.errors:
        print(f"{tool.RED}Missing dependencies: {' '.join(e for e in ctx.errors if e) or 'see the errors above'}{tool.RESET}")
        return 1
    if ctx.warnings:
        print(f"{tool.YELLOW}All dependencies present, with warnings above.{tool.RESET}")
    else:
        print(f"{tool.GREEN}All dependencies present.{tool.RESET}")
    return 0


def main() -> int:
    # A parent repository's script talks to this one through dependency_tool's protocol.
    if "--manifest" in sys.argv[1:] or "--configure" in sys.argv[1:]:
        return tool.main(__file__, REPOSITORY)

    parser = argparse.ArgumentParser(description="Checks everything kiems builds against, and optionally "
                                     "installs what is missing.")
    parser.add_argument("--component", action="append", choices=COMPONENTS,
                        help="check only this component (repeatable); omit to check everything")
    parser.add_argument("--install", action="store_true", help="install missing packages after confirmation")
    parser.add_argument("-y", "--yes", action="store_true", help="answer yes to the install prompt; requires --install")
    parser.add_argument("--no-configure", action="store_true", help="skip setup and validation after the package check")
    parser.add_argument("--ssh", action="store_true",
                        help="(macOS) fetch GitHub submodules over ssh rather than https; "
                             "a later run without it switches them back")
    args = parser.parse_args()
    if args.yes and not args.install:
        parser.error("--yes requires --install")

    if sys.platform.startswith("linux"):
        import linux_dependencies
        return linux_dependencies.main(args, parser)
    if sys.platform != "darwin":
        parser.error(f"unsupported platform {sys.platform}; KiEMS builds on macOS and Linux")
    return macos_main(args)


if __name__ == "__main__":
    sys.exit(main())
