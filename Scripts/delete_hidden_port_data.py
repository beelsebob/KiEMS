#!/usr/bin/env python3
"""Deletes the raw U/I time series of absorb-only ports from a KiEMS document's saved runs.

Runs from before absorb-only terminations stopped being probed wrote port_ut_N/port_it_N for every
port. A port whose role in its run's ports.txt is exactly "absorbing,hidden" -- absorbs, isn't
excited, isn't shown -- is never displayed, and a build that no longer probes such ports doesn't
read its files back when rerunning postprocessing either. Results and the report load from the
Sx*.csv/Probe*.csv files, which this leaves alone, as it does every other port's data (the excited
port's port_ut_N also gives the run's duration).

An older KiEMS build still reads every port's files to rerun postprocessing, so only run this once
the app includes that change. Quit KiEMS (or close the document) first: an open document's scratch
copy is written back over the package on save, restoring the files.

    scripts/delete_hidden_port_data.py ~/Documents/HorizonPC/Simulations.g2esim [--dry-run]
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

HIDDEN_ABSORBER_ROLE = "absorbing,hidden"


def hidden_absorbers(ports_txt: Path) -> set[int]:
    ports = set()
    for line in ports_txt.read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) >= 4 and fields[3].strip() == HIDDEN_ABSORBER_ROLE:
            ports.add(int(fields[0]))
    return ports


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("document", type=Path, help="the .g2esim document package")
    parser.add_argument("--dry-run", action="store_true", help="only report what would be deleted")
    args = parser.parse_args()

    if not args.dry_run and subprocess.run(["pgrep", "-x", "KiEMS"], capture_output=True).returncode == 0:
        print("KiEMS is running; quit it first (an open document's save would undo this).", file=sys.stderr)
        return 1

    simulation_root = args.document / "ems" / "simulation"
    if not simulation_root.is_dir():
        print(f"{simulation_root} doesn't exist", file=sys.stderr)
        return 1

    series = re.compile(r"^port_[ui]t_([0-9]+)$")
    total_files = total_bytes = 0
    for ports_txt in sorted(simulation_root.glob("*/*/ports.txt")):
        run_dir = ports_txt.parent
        hidden = hidden_absorbers(ports_txt)
        doomed = [p for p in run_dir.iterdir()
                  if (m := series.match(p.name)) and int(m.group(1)) in hidden and p.is_file()]
        if not doomed:
            continue
        size = sum(p.stat().st_size for p in doomed)
        print(f"[{run_dir.parent.name}/{run_dir.name}] {len(doomed)} files, {size / 1e9:.2f} GB")
        total_files += len(doomed)
        total_bytes += size
        if not args.dry_run:
            for path in doomed:
                path.unlink()

    verb = "Would delete" if args.dry_run else "Deleted"
    print(f"{verb} {total_files} files, {total_bytes / 1e9:.1f} GB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
