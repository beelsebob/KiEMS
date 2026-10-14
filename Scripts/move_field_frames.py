#!/usr/bin/env python3
"""Moves field-frame series stored inside a KiEMS document into external `.kemsf` packages.

Documents run before Settings gained a field-frame directory kept each simulation's frames as
`ems/simulation/<sim>/field_frames_port_<N>_<S>.h5` inside the package. This moves each one to
`<frame dir>/<document> - <sim>.kemsf/port_<N>_<S>.h5` -- the layout a run writes today -- and
points the simulation's field_frames_current.txt at it, so the Field Viewer keeps working.

A file is deleted only once its copy has been verified and the manifest rewritten. A loose file
no manifest references (its frames already live elsewhere) is just deleted, with --delete-orphans.

Quit KiEMS (or close the document) first: an open document's scratch copy is written back over
the package on save, restoring the files and old manifests.

The moved packages hold only the frames; series.json and board.kemsg, which let a `.kemsf` open on
its own, are written only by a run.

    scripts/move_field_frames.py ~/Documents/HorizonPC/Simulations.g2esim \\
        "/Volumes/Personal-Drive/EMS Data" [--dry-run] [--delete-orphans]
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

MANIFEST = "field_frames_current.txt"
LOOSE = re.compile(r"^field_frames_port_([0-9]+)_([01])\.h5$")


def read_manifest(sim_dir: Path) -> list[tuple[int, Path]]:
    path = sim_dir / MANIFEST
    if not path.exists():
        return []
    entries = []
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        port, _, entry = line.strip().partition(" ")
        target = Path(entry)
        entries.append((int(port), target if target.is_absolute() else sim_dir / target))
    return entries


def write_manifest(sim_dir: Path, entries: list[tuple[int, Path]]) -> None:
    temporary = sim_dir / (MANIFEST + ".tmp")
    temporary.write_text("".join(f"{port} {path}\n" for port, path in entries))
    os.replace(temporary, sim_dir / MANIFEST)


def copy_verified(source: Path, destination: Path) -> None:
    partial = destination.with_name(destination.name + ".partial")
    # rsync resumes an interrupted copy of a very large file instead of starting over.
    subprocess.run(["rsync", "--partial", "--inplace", "--progress", str(source), str(partial)], check=True)
    if partial.stat().st_size != source.stat().st_size:
        raise RuntimeError(f"size mismatch copying {source} -> {partial}")
    os.replace(partial, destination)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("document", type=Path, help="the .g2esim document package")
    parser.add_argument("frame_dir", type=Path, help="the field-frame directory chosen in Settings")
    parser.add_argument("--dry-run", action="store_true", help="only print what would happen")
    parser.add_argument("--delete-orphans", action="store_true",
                        help="delete loose frame files no manifest references")
    args = parser.parse_args()

    if not args.dry_run and subprocess.run(["pgrep", "-x", "KiEMS"], capture_output=True).returncode == 0:
        print("KiEMS is running; quit it first (an open document's save would undo this).", file=sys.stderr)
        return 1

    document_name = args.document.name.rsplit(".", 1)[0]
    simulation_root = args.document / "ems" / "simulation"
    if not simulation_root.is_dir() or not args.frame_dir.is_dir():
        print("document's ems/simulation or the frame directory doesn't exist", file=sys.stderr)
        return 1

    for sim_dir in sorted(p for p in simulation_root.iterdir() if p.is_dir()):
        loose = sorted(p for p in sim_dir.iterdir() if LOOSE.match(p.name))
        if not loose:
            continue
        manifest = read_manifest(sim_dir)
        referenced = {path.resolve() for _, path in manifest}
        package = args.frame_dir / f"{document_name} - {sim_dir.name}.kemsf"
        changed = False
        for source in loose:
            if source.resolve() not in referenced:
                if args.delete_orphans:
                    print(f"[{sim_dir.name}] delete orphan {source.name}")
                    if not args.dry_run:
                        source.unlink()
                else:
                    print(f"[{sim_dir.name}] skip {source.name}: no manifest references it (see --delete-orphans)")
                continue
            port, slot = LOOSE.match(source.name).groups()
            destination = package / f"port_{port}_{slot}.h5"
            print(f"[{sim_dir.name}] {source.name} ({source.stat().st_size / 1e9:.0f} GB) -> {destination}")
            if args.dry_run:
                continue
            if destination.exists() and destination.stat().st_size == source.stat().st_size:
                print("    already copied")
            else:
                if destination.exists():
                    raise RuntimeError(f"{destination} exists with a different size; not overwriting")
                package.mkdir(parents=True, exist_ok=True)
                copy_verified(source, destination)
            manifest = [(p, destination if path.resolve() == source.resolve() else path) for p, path in manifest]
            write_manifest(sim_dir, manifest)
            changed = True
            source.unlink()
        if changed:
            print(f"    manifest: {(sim_dir / MANIFEST).read_text().strip()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
