"""Engine behind each repository's Scripts/check_dependencies.py.

Identical copies of this file live in every repository that uses it (kiems, Copper); change them
together. A repository's check_dependencies.py only declares what that repository needs -- its
Homebrew formulas, its git submodules, and an optional configure step -- and hands them to main().

Repositories cooperate through their check_dependencies.py command line, not by importing each
other, so a submodule pinned at an older revision (with an older copy of this file) keeps working:

  check_dependencies.py [--yes]
      Full check, as a person runs it. Checks out this repository's submodules, then asks every
      submodule that has its own Scripts/check_dependencies.py what *it* needs (recursively), and
      checks or installs the union of all the Homebrew formulas in one go. Finally configures each
      repository, deepest first. To the user this looks like one script that fetches everything.

  check_dependencies.py --manifest
      Prints this repository's own requirements as JSON and exits:
        {"protocol": 1, "name": str,
         "homebrew": [{"formula": str, "version": str, "used_by": str}, ...],
         "submodules": [path relative to the repository root, ...]}

  check_dependencies.py --configure [--yes]
      Run by a parent once the formulas and submodules are in place: verifies this repository's
      own formulas and submodules (installing nothing), runs its configure step, and writes or
      deletes its build stamp. Exit status 0 = ok, 3 = ok with warnings, anything else = failed.

The build stamp is an untracked header whose presence the repository's Xcode build checks for, so
compiles fail with one clear error until the dependency check has passed on this machine.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Optional

PROTOCOL = 1
SCRIPT = Path("Scripts/check_dependencies.py")
EXIT_WARNINGS = 3


@dataclass(frozen=True)
class Formula:
    """A Homebrew formula. `version` is a prefix: "9.6" accepts 9.6, 9.6.2 and 9.6.2_1 but not 9.7."""
    formula: str
    version: str
    used_by: str


@dataclass
class Repository:
    """What a repository's check_dependencies.py declares about itself."""
    name: str
    homebrew: list[Formula]
    submodules: list[str]
    # Untracked header the repository's build requires; written once every check has passed.
    stamp: str
    # Runs once formulas and submodules are in place; reports problems through ctx.fail().
    configure: Optional[Callable[["Context"], None]] = None


# --- Output -----------------------------------------------------------------------------------------

if sys.stdout.isatty():
    RED, YELLOW, GREEN, BOLD, RESET = "\033[31m", "\033[33m", "\033[32m", "\033[1m", "\033[0m"
else:
    RED = YELLOW = GREEN = BOLD = RESET = ""


def heading(text: str) -> None:
    print(f"\n{BOLD}{text}{RESET}", flush=True)


@dataclass
class Context:
    """Passed to a repository's configure step."""
    root: Path
    assume_yes: bool
    # Fetch GitHub submodules over ssh (git@github.com:...) instead of the https URLs .gitmodules gives.
    ssh: bool = False
    brew: Optional[Path] = None
    brew_prefix: Optional[Path] = None
    warnings: int = 0
    errors: list[str] = field(default_factory=list)

    def ok(self, message: str) -> None:
        print(f"  {GREEN}ok{RESET}       {message}", flush=True)

    def warn(self, message: str) -> None:
        print(f"  {YELLOW}warning{RESET}  {message}", flush=True)
        self.warnings += 1

    def fail(self, message: str, summary: Optional[str] = None) -> None:
        """Report an error. `summary` names what is missing in the closing "Missing dependencies"
        line; errors without one (a failed install, say) are followed by one that has it."""
        print(f"  {RED}error{RESET}    {message}", flush=True)
        self.errors.append(summary or "")

    def confirm(self, question: str) -> bool:
        if self.assume_yes:
            return True
        # No controlling terminal (Xcode build phase, CI): never prompt, treat as "no".
        # Separate handles: Python refuses "r+" on a terminal, which can't seek.
        try:
            with open("/dev/tty", "w") as out, open("/dev/tty") as tty:
                out.write(f"{question} [y/N] ")
                out.flush()
                reply = tty.readline().strip().lower()
        except OSError:
            print("  (no terminal to ask; rerun in a terminal, or with --yes)")
            return False
        return reply in ("y", "yes")

    def linked_version(self, formula: str) -> Optional[str]:
        """The version of the keg $prefix/opt/<formula> points at -- i.e. the one builds link."""
        if self.brew_prefix is None:
            return None
        try:
            return Path(os.readlink(self.brew_prefix / "opt" / formula)).name
        except OSError:
            return None

    def set_build_setting(self, xcconfig: str, name: str, value: str) -> None:
        """Makes `name` resolve to `value` in the repository's xcconfig `xcconfig`, writing an untracked
        override next to it (Foo.xcconfig -> Foo.local.xcconfig, which Foo.xcconfig #include?s) only
        when the checked-in default differs."""
        default_file = self.root / xcconfig
        local_file = default_file.with_suffix(".local.xcconfig")
        default = _xcconfig_value(default_file, name)
        configured = _xcconfig_value(local_file, name)
        shown = local_file.relative_to(self.root)
        if configured is not None:
            if configured != value:
                lines = local_file.read_text().splitlines()
                lines = [f"{name} = {value}" if _xcconfig_name(line) == name else line for line in lines]
                local_file.write_text("\n".join(lines) + "\n")
                self.ok(f"{name} updated from {configured} to {value} in {shown}")
        elif value != default:
            with local_file.open("a") as f:
                f.write(f"{name} = {value}\n")
            self.ok(f"{name} set to {value} in {shown}")


def _xcconfig_name(line: str) -> Optional[str]:
    name, sep, _ = line.partition("=")
    return name.strip() if sep and not line.lstrip().startswith("//") else None


def _xcconfig_value(path: Path, name: str) -> Optional[str]:
    if not path.exists():
        return None
    values = [line.partition("=")[2].strip() for line in path.read_text().splitlines()
              if _xcconfig_name(line) == name]
    return values[-1] if values else None


def version_matches(version: str, prefix: str) -> bool:
    return version == prefix or version.startswith(prefix + ".") or version.startswith(prefix + "_")


# --- Homebrew ---------------------------------------------------------------------------------------

def find_brew() -> Optional[Path]:
    found = shutil.which("brew")
    if found:
        return Path(found)
    for candidate in ("/opt/homebrew/bin/brew", "/usr/local/bin/brew"):
        if os.access(candidate, os.X_OK):
            return Path(candidate)
    return None


def attach_brew(ctx: Context) -> None:
    ctx.brew = find_brew()
    if ctx.brew:
        ctx.brew_prefix = Path(subprocess.run([str(ctx.brew), "--prefix"], capture_output=True,
                                              text=True, check=True).stdout.strip())


def check_homebrew(ctx: Context) -> bool:
    heading("Homebrew")
    attach_brew(ctx)
    if ctx.brew is None:
        ctx.fail("Homebrew is not installed (https://brew.sh)", "Homebrew")
        if ctx.confirm("Install Homebrew now?"):
            installer = subprocess.run(["curl", "-fsSL", "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"],
                                       capture_output=True, text=True)
            if installer.returncode == 0 and subprocess.run(["/bin/bash", "-c", installer.stdout]).returncode == 0:
                attach_brew(ctx)
                if ctx.brew:
                    ctx.errors.remove("Homebrew")
            else:
                ctx.fail("Homebrew installation failed")
        if ctx.brew is None:
            return False
    ctx.ok(f"{ctx.brew} (prefix {ctx.brew_prefix})")
    return True


def check_formulas(ctx: Context, formulas: list[Formula], install: bool) -> None:
    """Checks every requirement (several repositories may each list the same formula), offering to
    install the missing ones in one `brew install` when `install` is set."""
    def check(f: Formula, after_install: bool = False) -> bool:
        version = ctx.linked_version(f.formula)
        if version is None:
            return False
        if version_matches(version, f.version):
            ctx.ok(f"{f.formula} {version}")
        elif after_install:
            ctx.warn(f"{f.formula} {version} installed, expected {f.version}.x (Homebrew's current release differs)")
        else:
            ctx.warn(f"{f.formula} {version} installed, expected {f.version}.x -- used by {f.used_by}")
        return True

    merged: dict[str, Formula] = {}
    for f in formulas:
        if f.formula in merged and merged[f.formula].version != f.version:
            merged[f.formula + "@" + f.version] = f  # conflicting prefixes: check both
        elif f.formula in merged:
            old = merged[f.formula]
            users = old.used_by if f.used_by in old.used_by else f"{old.used_by}; {f.used_by}"
            merged[f.formula] = Formula(f.formula, f.version, users)
        else:
            merged[f.formula] = f

    missing = [f for f in merged.values() if not check(f)]
    names = sorted({f.formula for f in missing})
    if missing and install and ctx.brew:
        for f in missing:
            print(f"  {RED}missing{RESET}  {f.formula} (expected {f.version}.x) -- used by {f.used_by}")
        print(f"\nMissing: {' '.join(names)}")
        if ctx.confirm(f"Install them with 'brew install {' '.join(names)}'?"):
            if subprocess.run([str(ctx.brew), "install", *names]).returncode != 0:
                ctx.fail("brew install failed")
            missing = [f for f in missing if not check(f, after_install=True)]
    for f in missing:
        ctx.fail(f"{f.formula} missing (expected {f.version}.x) -- used by {f.used_by}", f.formula)


# --- Git submodules ---------------------------------------------------------------------------------

@dataclass
class Submodule:
    owner: Path  # repository that records it
    path: str    # relative to owner

    @property
    def full(self) -> Path:
        return self.owner / self.path


def git(repo: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)


def submodule_state(sub: Submodule) -> tuple[str, str, str]:
    """('ok' | 'empty' | 'stale', recorded commit, checked-out commit)."""
    status = git(sub.owner, "submodule", "status", "--", sub.path).stdout
    entry = git(sub.owner, "ls-files", "--stage", "--", sub.path).stdout.split()
    recorded = entry[1][:10] if len(entry) >= 2 else "?"
    if not status or status[0] == "-" or not sub.full.is_dir() or not any(sub.full.iterdir()):
        return "empty", recorded, ""
    if status[0] in "+U":
        return "stale", recorded, git(sub.full, "rev-parse", "--short=10", "HEAD").stdout.strip()
    return "ok", recorded, recorded


def submodule_name(sub: Submodule) -> str:
    """The name .gitmodules files `sub` under (usually, but not necessarily, its path)."""
    for line in git(sub.owner, "config", "-f", ".gitmodules", "--get-regexp", r"^submodule\..*\.path$").stdout.splitlines():
        key, _, path = line.partition(" ")
        if path == sub.path:
            return key[len("submodule."):-len(".path")]
    return sub.path


def wanted_url(ctx: Context, sub: Submodule) -> str:
    url = git(sub.owner, "config", "-f", ".gitmodules", f"submodule.{submodule_name(sub)}.url").stdout.strip()
    if ctx.ssh and url.startswith("https://github.com/"):
        url = "git@github.com:" + url[len("https://github.com/"):].removesuffix(".git") + ".git"
    return url


def use_url(ctx: Context, sub: Submodule) -> None:
    """Points `sub` at https or ssh as this run asks, in the owner's local config and, once it is
    cloned, in the clone's origin. Nothing in .gitmodules changes."""
    name, url = submodule_name(sub), wanted_url(ctx, sub)
    configured = git(sub.owner, "config", f"submodule.{name}.url").stdout.strip()
    if configured and configured != url:
        git(sub.owner, "config", f"submodule.{name}.url", url)
        if (sub.full / ".git").exists():
            git(sub.full, "remote", "set-url", "origin", url)
        ctx.ok(f"{sub.full.relative_to(ctx.root)} now fetches from {url}")


def check_submodules(ctx: Context, subs: list[Submodule], consent: list[Optional[bool]]) -> None:
    """Reports `subs`, offering to check out the ones that are missing or at another commit than
    their owner records. `consent` carries the user's answer between levels of nesting, so a
    "yes" for the top-level submodules also covers the ones that appear inside them."""
    def report() -> list[tuple[Submodule, str]]:
        outdated = []
        for sub in subs:
            state, recorded, actual = submodule_state(sub)
            shown = sub.full.relative_to(ctx.root)
            if state == "empty":
                print(f"  {RED}missing{RESET}  {shown} is not checked out")
            elif state == "stale":
                print(f"  {YELLOW}warning{RESET}  {shown} is at {actual}, the repository expects {recorded}")
            else:
                ctx.ok(f"{shown} ({recorded})")
            if state != "ok":
                outdated.append((sub, state))
        return outdated

    for sub in subs:
        use_url(ctx, sub)
    outdated = report()
    if outdated:
        if consent[0] is None:
            shown = " ".join(str(s.full.relative_to(ctx.root)) for s, _ in outdated)
            consent[0] = ctx.confirm(f"Check out {shown} at the commits the repository records "
                                     "(git submodule update --init), along with any submodules inside them?")
        if consent[0]:
            for sub, _ in outdated:
                print(f"  fetching {sub.full.relative_to(ctx.root)} from {wanted_url(ctx, sub)}")
                git(sub.owner, "submodule", "init", "--", sub.path)
                use_url(ctx, sub)
                # --recommend-shallow honours `shallow = true` in .gitmodules (KiCad's full history
                # is several gigabytes); --progress shows the transfer even for large clones.
                result = subprocess.run(["git", "-C", str(sub.owner), "submodule", "update", "--init",
                                         "--recommend-shallow", "--progress", "--", sub.path])
                if result.returncode != 0:
                    print(f"  {RED}error{RESET}    git submodule update failed for {sub.full.relative_to(ctx.root)}")
            outdated = report()
    for sub, state in outdated:
        shown = str(sub.full.relative_to(ctx.root))
        if state == "empty":
            ctx.fail(f"{shown} is not checked out", shown)
        else:
            ctx.warn(f"{shown} is not at the commit its repository records")


# --- Nested repositories ----------------------------------------------------------------------------

@dataclass
class Child:
    """A submodule with its own check_dependencies.py, and what it reported needing."""
    root: Path
    name: str
    homebrew: list[Formula]
    submodules: list[str]
    children: list["Child"] = field(default_factory=list)


def read_manifest(repo: Path) -> Optional[Child]:
    script = repo / SCRIPT
    if not script.exists():
        return None
    result = subprocess.run([sys.executable, str(script), "--manifest"], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"{script} --manifest failed:\n{result.stderr}")
    data = json.loads(result.stdout)
    if data.get("protocol") != PROTOCOL:
        raise RuntimeError(f"{script} speaks dependency protocol {data.get('protocol')}, expected {PROTOCOL}")
    return Child(repo, data["name"], [Formula(**f) for f in data["homebrew"]], data["submodules"])


def walk(child: Child):
    """Post-order: deepest repositories first, so each is configured before the ones using it."""
    for c in child.children:
        yield from walk(c)
    yield child


def run_child_configure(ctx: Context, child: Child) -> None:
    args = [sys.executable, str(child.root / SCRIPT), "--configure"] + (["--yes"] if ctx.assume_yes else [])
    status = subprocess.run(args).returncode
    if status == EXIT_WARNINGS:
        ctx.warnings += 1
    elif status != 0:
        shown = child.root.relative_to(ctx.root)
        ctx.errors.append(f"{child.name} ({shown}/{SCRIPT} --configure)")


# --- Entry points -----------------------------------------------------------------------------------

def stamp_path(ctx: Context, repo: Repository) -> Path:
    return ctx.root / repo.stamp


def write_stamp(ctx: Context, repo: Repository) -> None:
    path = stamp_path(ctx, repo)
    path.write_text(
        f"// Generated by Scripts/check_dependencies.py on {datetime.datetime.now():%Y-%m-%d %H:%M}. Do not commit.\n"
        f"// Its presence lets the build's dependency check pass; rerun the script to regenerate it.\n"
        "#pragma once\n")


def configure(ctx: Context, repo: Repository) -> None:
    heading(f"{repo.name} setup")
    if repo.configure:
        repo.configure(ctx)
    if not ctx.errors:
        write_stamp(ctx, repo)
        ctx.ok(f"{repo.stamp} written")


def main(script: str, repo: Repository) -> int:
    parser = argparse.ArgumentParser(description=f"Checks the dependencies {repo.name} builds against, "
                                     "and those of the repositories it includes as submodules.")
    parser.add_argument("-y", "--yes", action="store_true", help='answer "yes" to every prompt (unattended setup)')
    parser.add_argument("--ssh", "-ssh", action="store_true",
                        help="fetch GitHub submodules over ssh (git@github.com:) rather than https; "
                             "a later run without it switches them back")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--manifest", action="store_true", help="print this repository's own requirements as JSON")
    mode.add_argument("--configure", action="store_true",
                      help="verify and configure this repository only (used by a parent repository's script)")
    args = parser.parse_args()
    sys.stdout.reconfigure(line_buffering=True)  # keep our lines in order with git's and brew's

    ctx = Context(root=Path(script).resolve().parent.parent, assume_yes=args.yes, ssh=args.ssh)
    if args.manifest:
        json.dump({"protocol": PROTOCOL, "name": repo.name,
                   "homebrew": [f.__dict__ for f in repo.homebrew], "submodules": repo.submodules},
                  sys.stdout, indent=2)
        print()
        return 0

    stamp_path(ctx, repo).unlink(missing_ok=True)

    if args.configure:
        # Run by a parent which has already reported on, and offered to fix, everything below.
        # Recheck quietly, so a failure here names the repository that needs it.
        attach_brew(ctx)
        missing = [f.formula for f in repo.homebrew if ctx.linked_version(f.formula) is None]
        empty = [p for p in repo.submodules if submodule_state(Submodule(ctx.root, p))[0] == "empty"]
        if missing or empty:
            heading(f"{repo.name} setup")
            ctx.fail(f"{repo.name} is missing {' '.join(missing + empty)}", repo.name)
            return 1
        configure(ctx, repo)
        return 1 if ctx.errors else (EXIT_WARNINGS if ctx.warnings else 0)

    have_brew = check_homebrew(ctx)

    heading("Git submodules")
    me = Child(ctx.root, repo.name, repo.homebrew, repo.submodules)
    consent: list[Optional[bool]] = [None]
    level = [me]
    while level:
        subs = [Submodule(c.root, p) for c in level for p in c.submodules]
        check_submodules(ctx, subs, consent)
        next_level = []
        for c in level:
            for p in c.submodules:
                nested = read_manifest(c.root / p)
                if nested:
                    c.children.append(nested)
                    next_level.append(nested)
        level = next_level

    if have_brew:
        heading("Homebrew libraries")
        check_formulas(ctx, [f for c in walk(me) for f in c.homebrew], install=True)

    if ctx.errors:
        # Configuring needs every formula and submodule; skip it, but say what was skipped.
        children = [c for c in walk(me) if c is not me]
        if children:
            print(f"\nSkipped setting up {', '.join(c.name for c in children)} and {repo.name} until the errors above are fixed.")
    else:
        for child in walk(me):
            if child is not me:
                run_child_configure(ctx, child)
        configure(ctx, repo)

    print()
    if ctx.errors:
        print(f"{RED}Missing dependencies: {' '.join(e for e in ctx.errors if e) or 'see the errors above'}{RESET}")
        return 1
    if ctx.warnings:
        print(f"{YELLOW}All dependencies present, with warnings above.{RESET}")
    else:
        print(f"{GREEN}All dependencies present.{RESET}")
    return 0
