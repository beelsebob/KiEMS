#!/bin/bash
# Checks that every third-party library kiems builds against is installed through Homebrew, at the
# versions the Xcode project expects. Missing formulas are errors; version mismatches are warnings.
# Offers to install Homebrew itself, and any missing formulas, after asking.
#
# Usage: Scripts/check_dependencies.sh [--yes]
#   --yes   answer "yes" to every install prompt (for unattended setup)
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
vtk              9.6   CSXCAD (links -9.6 suffixed libraries)
wxwidgets@3.2    3.2   KiCad headers (wx-3.2 include paths)
glm              1.0   KiCad headers
cairo            1.18  KiCad headers
pixman           0.46  KiCad headers
freetype         2.14  KiCad headers
harfbuzz         14    KiCad headers
opencascade      7.9   KiCad link (libTK*.dylib)
"

SUBMODULES="submodules/CSXCAD submodules/fparser submodules/tinyxml"

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
  { printf '%s [y/N] ' "$1" > /dev/tty; } 2> /dev/null || { echo "  (no terminal; rerun with --yes to install)"; return 1; }
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

# The Xcode project reads HOMEBREW_PREFIX from libkicad/BuildPaths.xcconfig (default /opt/homebrew),
# overridable by the untracked BuildPaths.local.xcconfig. Point it at this machine's Homebrew.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_XCCONFIG="$REPO_ROOT/libkicad/BuildPaths.local.xcconfig"
DEFAULT_PREFIX="$(sed -n 's/^HOMEBREW_PREFIX *= *//p' "$REPO_ROOT/libkicad/BuildPaths.xcconfig")"
CONFIGURED_PREFIX="$(sed -n 's/^HOMEBREW_PREFIX *= *//p' "$LOCAL_XCCONFIG" 2>/dev/null | tail -1)"
if [ -n "$CONFIGURED_PREFIX" ]; then
  if [ "$CONFIGURED_PREFIX" != "$BREW_PREFIX" ]; then
    sed -i '' "s|^HOMEBREW_PREFIX *=.*|HOMEBREW_PREFIX = $BREW_PREFIX|" "$LOCAL_XCCONFIG"
    ok "HOMEBREW_PREFIX updated from $CONFIGURED_PREFIX to $BREW_PREFIX in ${LOCAL_XCCONFIG#"$REPO_ROOT"/}"
  fi
elif [ "$BREW_PREFIX" != "$DEFAULT_PREFIX" ]; then
  echo "HOMEBREW_PREFIX = $BREW_PREFIX" >> "$LOCAL_XCCONFIG"
  ok "HOMEBREW_PREFIX set to $BREW_PREFIX in ${LOCAL_XCCONFIG#"$REPO_ROOT"/}"
fi

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

# --- Git submodules -------------------------------------------------------------------------------
echo; echo "${BOLD}Git submodules${RESET}"
EMPTY_SUBMODULES=""
for path in $SUBMODULES; do
  if [ -n "$(ls -A "$REPO_ROOT/$path" 2>/dev/null)" ]; then
    ok "$path"
  else
    fail "$path is not checked out"
    EMPTY_SUBMODULES="$EMPTY_SUBMODULES $path"
  fi
done
if [ -n "$EMPTY_SUBMODULES" ] && confirm "Run 'git submodule update --init${EMPTY_SUBMODULES}'?"; then
  # shellcheck disable=SC2086
  git -C "$REPO_ROOT" submodule update --init $EMPTY_SUBMODULES && EMPTY_SUBMODULES=""
fi

# --- Summary --------------------------------------------------------------------------------------
echo
if [ -n "$MISSING" ] || [ -n "$EMPTY_SUBMODULES" ]; then
  echo "${RED}Missing dependencies:${MISSING}${EMPTY_SUBMODULES}${RESET}"
  exit 1
fi
if [ "$WARNINGS" -gt 0 ]; then
  echo "${YELLOW}All dependencies present, with $WARNINGS version warning(s).${RESET}"
else
  echo "${GREEN}All dependencies present.${RESET}"
fi
exit 0
