#!/usr/bin/env python3
"""Print, optionally install, and validate Linux packages required by KiEMS.

This script deliberately does not treat a package manager as the dependency source of truth.
Dependencies are declared in Dependencies/linux-packages.json as logical component groups, while
the final check is CMake's own configure step.  That way an unfamiliar distro can still use the
generic dependency names from the manifest and receive an accurate CMake diagnostic.

Usage:
  Scripts/check_dependencies_linux.py [--component NAME]... [--install [--yes]] [--no-configure]

By default it initializes the repository's Git submodules, prints the commands for the detected
distribution, and runs CMake configuration. It never installs system packages unless --install is
supplied. Nix users should enter the development shell with `nix develop` instead.  --component
may be build, kiems, copper, or libkicad; omit it to select all components.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "Dependencies" / "linux-packages.json"
SUPPORTED_MANAGERS = {"apt", "dnf", "pacman", "zypper"}


def os_release() -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        for line in Path("/etc/os-release").read_text().splitlines():
            if "=" not in line or line.startswith("#"):
                continue
            key, value = line.split("=", 1)
            values[key] = value.strip().strip('"')
    except OSError:
        pass
    return values


def detect_manager(release: dict[str, str]) -> str | None:
    identifiers = {release.get("ID", ""), *release.get("ID_LIKE", "").split()}
    preferred = (("apt", {"debian", "ubuntu"}), ("dnf", {"fedora", "rhel", "centos"}),
                 ("zypper", {"suse", "opensuse"}), ("pacman", {"arch"}))
    for manager, families in preferred:
        if identifiers & families and shutil.which(manager):
            return manager
    return next((manager for manager in SUPPORTED_MANAGERS if shutil.which(manager)), None)


def install_command(manager: str, packages: list[str]) -> list[str]:
    if manager == "apt":
        return ["sudo", "apt", "install", *packages]
    if manager == "dnf":
        return ["sudo", "dnf", "install", *packages]
    if manager == "pacman":
        return ["sudo", "pacman", "-S", "--needed", *packages]
    return ["sudo", "zypper", "install", *packages]


def confirm(question: str, assume_yes: bool) -> bool:
    if assume_yes:
        return True
    try:
        return input(f"{question} [y/N] ").strip().lower() in {"y", "yes"}
    except EOFError:
        return False


def configure() -> int:
    if not shutil.which("cmake"):
        print("\nCMake is required to validate this build, but it is not installed or not on PATH.",
              file=sys.stderr)
        print("Install the build component first, then rerun this checker:", file=sys.stderr)
        print("  Scripts/check_dependencies_linux.py --component build --install", file=sys.stderr)
        return 2

    build_directory = ROOT / "build" / "cmake" / "linux-dependency-check"
    command = [
        "cmake", "-S", str(ROOT), "-B", str(build_directory), "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=Debug", "-DCOPPER_ENABLE_METAL=OFF", "-DKIEMS_BUILD_TESTS=OFF",
    ]
    print("\nValidating with CMake:")
    print("  " + " ".join(command))
    return subprocess.run(command).returncode


def update_submodules() -> int:
    if not shutil.which("git"):
        print("\nGit is required to initialize KiEMS submodules, but it is not installed or not on PATH.",
              file=sys.stderr)
        print("Install Git, then rerun this checker.", file=sys.stderr)
        return 2

    command = ["git", "-C", str(ROOT), "submodule", "update", "--init", "--recursive"]
    print("\nInitializing Git submodules:")
    print("  " + " ".join(command))
    result = subprocess.run(command)
    if result.returncode:
        print("Git could not initialize the required submodules. Resolve the Git error above and rerun "
              "this checker.", file=sys.stderr)
    return result.returncode


def kicad_build_is_current() -> bool:
    source_directory = ROOT / "submodules" / "libkicad" / "submodules" / "kicad"
    build_directory = ROOT / "submodules" / "libkicad" / "build" / "kicad"
    stamp = build_directory / ".built-commit"
    required_artifacts = [
        build_directory / "compile_commands.json",
        # libkicad's Linux link interface consumes an archive of KiCad's pcbnew objects.
        build_directory / "pcbnew" / "libpcbnew_kiface_objects.a",
    ]
    if not (source_directory / "CMakeLists.txt").is_file() or not all(path.is_file() for path in required_artifacts):
        return False
    try:
        source_commit = subprocess.run(
            ["git", "-C", str(source_directory), "rev-parse", "HEAD"],
            check=True, capture_output=True, text=True).stdout.strip()
        return stamp.read_text().strip() == source_commit
    except (OSError, subprocess.CalledProcessError):
        return False


def build_kicad() -> int:
    if kicad_build_is_current():
        print("\nKiCad build is current.")
        return 0
    if not shutil.which("cmake"):
        print("\nCMake is required to build KiCad, but it is not installed or not on PATH.", file=sys.stderr)
        print("Install the build component first, then rerun this checker:", file=sys.stderr)
        print("  Scripts/check_dependencies_linux.py --component build --install", file=sys.stderr)
        return 2

    script = ROOT / "submodules" / "libkicad" / "Scripts" / "build_kicad.sh"
    if not script.is_file():
        print("KiCad build helper is missing after submodule initialization.", file=sys.stderr)
        return 2
    print("\nBuilding KiCad libraries required by libkicad:")
    print(f"  {script}")
    return subprocess.run([str(script)]).returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--component", action="append", choices=["build", "kiems", "copper", "libkicad"])
    parser.add_argument("--install", action="store_true", help="install packages after confirmation")
    parser.add_argument("--yes", action="store_true", help="answer yes to the install prompt; requires --install")
    parser.add_argument("--no-configure", action="store_true", help="skip the final CMake validation")
    args = parser.parse_args()
    if args.yes and not args.install:
        parser.error("--yes requires --install")
    if sys.platform != "linux":
        parser.error("this checker is for Linux; use Scripts/check_dependencies.py on macOS")

    release = os_release()
    if release.get("ID") == "nixos" and not os.environ.get("IN_NIX_SHELL"):
        if args.install:
            parser.error("NixOS dependencies are declared in flake.nix; run `nix develop` instead")
        print("NixOS detected. Enter the project development shell first:")
        print("  nix develop")
        print("Then rerun this command to validate CMake discovery.")
        return 0 if args.no_configure else 2

    manifest = json.loads(MANIFEST.read_text())
    requested = args.component or list(manifest["components"])
    manager = detect_manager(release)
    if manager is None:
        print("No supported package manager was detected.", file=sys.stderr)
        print("Install the packages listed for each selected component in "
              f"{MANIFEST.relative_to(ROOT)} and rerun without --no-configure.", file=sys.stderr)
        return 2

    packages: list[str] = []
    print(f"Detected package manager: {manager}")
    for component in requested:
        entry = manifest["components"][component]
        mapping = entry.get(manager)
        if not mapping:
            print(f"No {manager} mapping for {component}: {entry['description']}", file=sys.stderr)
            return 2
        print(f"  {component}: {entry['description']}")
        if isinstance(mapping, list):
            packages.extend(mapping)
        else:
            packages.extend(mapping["packages"])
            for note in mapping.get("notes", []):
                print(f"    note: {note}")
    packages = list(dict.fromkeys(packages))
    command = install_command(manager, packages)
    print("\nSuggested install command:")
    print("  " + " ".join(command))

    if args.install:
        if not confirm("Install these packages?", args.yes):
            print("Not installed.")
            return 1
        if subprocess.run(command).returncode:
            return 1

    if update_submodules():
        return 1

    if not args.no_configure and build_kicad():
        return 1

    return 0 if args.no_configure else configure()


if __name__ == "__main__":
    sys.exit(main())
