#!/bin/bash
# Checks that every third-party library kiems builds against is installed through Homebrew, at the
# versions the Xcode project expects. Missing formulas are errors; version mismatches are warnings.
# Offers to install Homebrew itself, and any missing formulas, after asking.
#
# Usage: Scripts/check_dependencies.sh [--yes]
#   --yes   answer "yes" to every install prompt (for unattended setup)
#
# On success writes the untracked libkicad/DependenciesChecked.generated.h; until it exists every
# Xcode compile stops with an #error from libkicad/DependencyCheck.h. The script never runs from Xcode.
#
# Exit status: 0 when nothing is missing (warnings allowed), 1 otherwise.
set -uo pipefail

ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# formula  expected-version-prefix  used-by
# A prefix of "9.6" accepts 9.6, 9.6.2, 9.6.2_1, ... but not 9.7. Where the project hard-codes a
# version (vtk's -9.6 library suffixes, wx-3.2 include paths, hdf5 2.x's API) a mismatch will
# break the build; elsewhere it is the version the project was last verified with.
DEPENDENCIES="
geos             3.15  libkiems (polygon geometry)
matplotplusplus  1.2   libkiems (plots)
gnuplot          6.0   libkiems (matplot++ rendering backend, runtime)
nlohmann-json    3     libkiems
hdf5             2.2   Copper, CSXCAD
c-blosc2         3     Copper (field-frame compression)
cgal             6.2   CSXCAD
boost            1.90  CSXCAD, KiCad headers
gmp              6.3   CSXCAD
mpfr             4.2   CSXCAD
vtk              9     CSXCAD (VTK_VERSION build setting follows the installed version)
wxwidgets@3.2    3.2   KiCad headers (wx-3.2 include paths)
glm              1.0   KiCad headers
cairo            1.18  KiCad headers
pixman           0.46  KiCad headers
freetype         2.14  KiCad headers
harfbuzz         14    KiCad headers
opencascade      7.9   KiCad link (libTK*.dylib)
cmake            4     KiCad build (Scripts/build_kicad.sh)
ninja            1.13  KiCad build
pkgconf          3     KiCad build
libngspice       46    KiCad build
libgit2          1.9   KiCad build
nng              1.12  KiCad build
zstd             1.5   KiCad build
protobuf         35    KiCad build
fontconfig       2.18  KiCad build
unixodbc         2.3   KiCad build
"

SUBMODULES="submodules/Copper submodules/CSXCAD submodules/fparser submodules/tinyxml submodules/kicad"

if [ -t 1 ]; then
  RED=$'\033[31m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=; YELLOW=; GREEN=; BOLD=; RESET=
fi
ok()    { echo "  ${GREEN}ok${RESET}       $*"; }
warn()  { echo "  ${YELLOW}warning${RESET}  $*"; }
fail()  { echo "  ${RED}error${RESET}    $*"; }

confirm() {
  if [ "$ASSUME_YES" -eq 1 ]; then return 0; fi
  local reply
  # No controlling terminal (Xcode build phase, CI): never prompt, treat as "no".
  { printf '%s [y/N] ' "$1" > /dev/tty; } 2> /dev/null || { echo "  (no terminal to ask; rerun in a terminal, or with --yes)"; return 1; }
  read -r reply < /dev/tty || return 1
  case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

find_brew() {
  if command -v brew > /dev/null 2>&1; then command -v brew; return; fi
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$candidate" ]; then echo "$candidate"; return; fi
  done
}

# --- Homebrew -------------------------------------------------------------------------------------
echo "${BOLD}Homebrew${RESET}"
BREW="$(find_brew)"
if [ -z "$BREW" ]; then
  fail "Homebrew is not installed (https://brew.sh)"
  if confirm "Install Homebrew now?"; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
      fail "Homebrew installation failed"; exit 1; }
    BREW="$(find_brew)"
  fi
  if [ -z "$BREW" ]; then
    echo; echo "${RED}Cannot check libraries without Homebrew.${RESET}"; exit 1
  fi
fi
BREW_PREFIX="$("$BREW" --prefix)"
ok "$BREW (prefix $BREW_PREFIX)"

# The Xcode project reads machine-specific settings (HOMEBREW_PREFIX, VTK_VERSION) from
# libkicad/BuildPaths.xcconfig, overridable by the untracked BuildPaths.local.xcconfig. Make the
# override match this machine, writing it only when it differs from the checked-in default.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_XCCONFIG="$REPO_ROOT/libkicad/BuildPaths.local.xcconfig"
set_build_setting() {  # name value
  local name="$1" value="$2" default configured
  default="$(sed -n "s/^$name *= *//p" "$REPO_ROOT/libkicad/BuildPaths.xcconfig")"
  configured="$(sed -n "s/^$name *= *//p" "$LOCAL_XCCONFIG" 2>/dev/null | tail -1)"
  if [ -n "$configured" ]; then
    if [ "$configured" != "$value" ]; then
      sed -i '' "s|^$name *=.*|$name = $value|" "$LOCAL_XCCONFIG"
      ok "$name updated from $configured to $value in ${LOCAL_XCCONFIG#"$REPO_ROOT"/}"
    fi
  elif [ "$value" != "$default" ]; then
    echo "$name = $value" >> "$LOCAL_XCCONFIG"
    ok "$name set to $value in ${LOCAL_XCCONFIG#"$REPO_ROOT"/}"
  fi
}
set_build_setting HOMEBREW_PREFIX "$BREW_PREFIX"

# The version of the keg $BREW_PREFIX/opt/<formula> points at -- i.e. the one the build links.
linked_version() {
  local target
  target="$(readlink "$BREW_PREFIX/opt/$1" 2>/dev/null)" || return 1
  basename "$target"
}

version_matches() {  # version prefix
  case "$1" in "$2"|"$2".*|"$2"_*) return 0 ;; *) return 1 ;; esac
}

# --- Formulas -------------------------------------------------------------------------------------
echo; echo "${BOLD}Homebrew libraries${RESET}"
MISSING=""
WARNINGS=0
while read -r formula expected used_by; do
  [ -z "$formula" ] && continue
  if version="$(linked_version "$formula")"; then
    if version_matches "$version" "$expected"; then
      ok "$formula $version"
    else
      warn "$formula $version installed, expected $expected.x -- used by $used_by"
      WARNINGS=$((WARNINGS + 1))
    fi
  else
    fail "$formula missing (expected $expected.x) -- used by $used_by"
    MISSING="$MISSING $formula"
  fi
done <<< "$DEPENDENCIES"

if [ -n "$MISSING" ]; then
  echo
  echo "Missing:${MISSING}"
  if confirm "Install them with 'brew install${MISSING}'?"; then
    # shellcheck disable=SC2086
    if "$BREW" install $MISSING; then
      STILL_MISSING=""
      for formula in $MISSING; do
        if version="$(linked_version "$formula")"; then
          expected="$(echo "$DEPENDENCIES" | awk -v f="$formula" '$1 == f { print $2 }')"
          if version_matches "$version" "$expected"; then
            ok "$formula $version"
          else
            warn "$formula $version installed, expected $expected.x (Homebrew's current release differs)"
            WARNINGS=$((WARNINGS + 1))
          fi
        else
          STILL_MISSING="$STILL_MISSING $formula"
        fi
      done
      MISSING="$STILL_MISSING"
    else
      fail "brew install failed"
    fi
  fi
fi

# Homebrew's VTK names its header directory and libraries after its major.minor version.
if version="$(linked_version vtk)"; then
  set_build_setting VTK_VERSION "$(echo "$version" | cut -d. -f1-2)"
fi

# --- Git submodules -------------------------------------------------------------------------------
# Uninitialised submodules are errors. One checked out at a different commit from the one this
# repository records (typically after a pull) is a warning, since it may be deliberate work in
# progress inside the submodule; either way, offer to update them.
echo; echo "${BOLD}Git submodules${RESET}"
EMPTY_SUBMODULES=""
STALE_SUBMODULES=""
check_submodules() {
  EMPTY_SUBMODULES=""; STALE_SUBMODULES=""
  local path line state recorded actual
  for path in $SUBMODULES; do
    line="$(git -C "$REPO_ROOT" submodule status -- "$path" 2>/dev/null)"
    state="${line:0:1}"
    recorded="$(git -C "$REPO_ROOT" ls-tree HEAD "$path" | awk '{ print substr($3, 1, 10) }')"
    if [ "$state" = "-" ] || [ -z "$(ls -A "$REPO_ROOT/$path" 2>/dev/null)" ]; then
      fail "$path is not checked out"
      EMPTY_SUBMODULES="$EMPTY_SUBMODULES $path"
    elif [ "$state" = "+" ] || [ "$state" = "U" ]; then
      actual="$(git -C "$REPO_ROOT/$path" rev-parse --short=10 HEAD 2>/dev/null)"
      warn "$path is at $actual, the repository expects $recorded"
      STALE_SUBMODULES="$STALE_SUBMODULES $path"
    else
      ok "$path ($recorded)"
    fi
  done
}
check_submodules
OUTDATED_SUBMODULES="$EMPTY_SUBMODULES$STALE_SUBMODULES"
if [ -n "$OUTDATED_SUBMODULES" ] && \
   confirm "Run 'git submodule update --init${OUTDATED_SUBMODULES}'?"; then
  # shellcheck disable=SC2086
  git -C "$REPO_ROOT" submodule update --init $OUTDATED_SUBMODULES
  check_submodules
fi
[ -n "$STALE_SUBMODULES" ] && WARNINGS=$((WARNINGS + $(echo $STALE_SUBMODULES | wc -w)))

# --- KiCad build ---------------------------------------------------------------------------------
# libkicad links pieces of the KiCad submodule built by Scripts/build_kicad.sh (too slow to run from
# Xcode), which records the submodule commit it built; a build from another commit is out of date.
echo; echo "${BOLD}KiCad build${RESET}"
KICAD_BUILD="$REPO_ROOT/build/kicad"
KICAD_PRODUCTS="common/libcommon.a common/libpcbcommon.a kicad/KiCad.app/Contents/Frameworks/libkicommon.dylib
  kicad/KiCad.app/Contents/Frameworks/libkigal.dylib kicad/KiCad.app/Contents/Frameworks/libkiapi.dylib"
KICAD_PROBLEM=""
kicad_built() {
  local product built current
  for product in $KICAD_PRODUCTS; do
    [ -e "$KICAD_BUILD/$product" ] || { KICAD_PROBLEM="build/kicad is missing or incomplete"; return 1; }
  done
  built="$(cat "$KICAD_BUILD/.built-commit" 2>/dev/null)"
  current="$(git -C "$REPO_ROOT/submodules/kicad" rev-parse HEAD 2>/dev/null)"
  if [ "$built" != "$current" ]; then
    if [ -z "$built" ]; then
      KICAD_PROBLEM="build/kicad doesn't record which KiCad commit it was built from"
    else
      KICAD_PROBLEM="build/kicad was built from ${built:0:10}, submodules/kicad is at ${current:0:10}"
    fi
    return 1
  fi
}
KICAD_MISSING=""
if kicad_built; then
  ok "build/kicad"
elif [ -n "$MISSING" ] || [ -n "$EMPTY_SUBMODULES" ]; then
  fail "$KICAD_PROBLEM; fix the errors above, then run Scripts/build_kicad.sh"
  KICAD_MISSING=" build/kicad"
else
  fail "$KICAD_PROBLEM"
  if confirm "Run Scripts/build_kicad.sh now?" && \
     "$REPO_ROOT/Scripts/build_kicad.sh" && kicad_built; then
    ok "build/kicad"
  else
    KICAD_MISSING=" build/kicad"
  fi
fi

# --- Summary --------------------------------------------------------------------------------------
# libkicad/DependencyCheck.h (force-included into every compile) #errors until this file exists.
STAMP="$REPO_ROOT/libkicad/DependenciesChecked.generated.h"
rm -f "$STAMP"
echo
if [ -n "$MISSING" ] || [ -n "$EMPTY_SUBMODULES" ] || [ -n "$KICAD_MISSING" ]; then
  echo "${RED}Missing dependencies:${MISSING}${EMPTY_SUBMODULES}${KICAD_MISSING}${RESET}"
  exit 1
fi
{
  echo "// Generated by Scripts/check_dependencies.sh on $(date '+%Y-%m-%d %H:%M'). Do not commit."
  echo "// Its presence lets libkicad/DependencyCheck.h pass; rerun the script to regenerate it."
  echo "#pragma once"
} > "$STAMP"
if [ "$WARNINGS" -gt 0 ]; then
  echo "${YELLOW}All dependencies present, with $WARNINGS version warning(s).${RESET}"
else
  echo "${GREEN}All dependencies present.${RESET}"
fi
exit 0
