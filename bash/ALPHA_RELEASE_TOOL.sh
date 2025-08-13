#!/usr/bin/env bash
# ==============================================================
# Alpha Release Script for picture_analytics
#
# This script guides you through creating an alpha release:
#  - Verifies branch, working tree, and required files
#  - Reads and cross-checks version numbers in pyproject.toml & __init__.py
#  - Prompts to update them if mismatched or not alpha
#  - Builds and validates the package
#  - Creates and pushes the git tag that triggers GitHub Actions release workflow
# ==============================================================

set -euo pipefail  # Exit on error, undefined var is error, pipeline errors propagate

# --- CONFIGURATION ---
PYPROJECT="./pyproject.toml"                    # Path to pyproject.toml
INIT_FILE="./src/scripts/__init__.py"           # Path to __init__.py with __version__
TARGET_BRANCH="develop-alpha"                   # Branch intended for alpha releases
REMOTE="origin"                                 # Git remote name to push to
SIGN_TAG_DEFAULT="n"                            # Default answer for signing tags ('y' or 'n')
# ---------------------

# ANSI colors for output
RED="$(printf '\033[31m')"
GRN="$(printf '\033[32m')"
YEL="$(printf '\033[33m')"
BLU="$(printf '\033[34m')"
NC="$(printf '\033[0m')"  # Reset

# --- UTILITY FUNCTIONS ---
ask() {
  # Prompt user with optional default answer
  local q="$1"; local d="${2:-}"
  read -r -p "$(printf "${BLU}?${NC} %s %s " "$q" "${d:+[$d]}")" ans || true
  echo "${ans:-$d}"
}

confirm() {
  # Prompt user for y/n confirmation (default 'y')
  local q="$1"
  local d="${2:-y}"
  local ans
  ans="$(ask "$q" "$d")"
  [[ "$ans" =~ ^[Yy]$ ]]
}

die() { echo -e "${RED}✖ $*${NC}"; exit 1; }
info(){ echo -e "${GRN}✔${NC} $*"; }
warn(){ echo -e "${YEL}!${NC} $*"; }

require_cmd() {
  # Ensure a required command is available
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

# --- PREFLIGHT CHECKS ---

# Check we have required commands
require_cmd git
require_cmd python3
require_cmd sed
require_cmd awk

# Verify pip exists for python3
if ! python3 -m pip >/dev/null 2>&1; then
  die "pip not available for python3"
fi

# Verify inside a Git repo
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not in a git repository"

# Check current branch
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" != "$TARGET_BRANCH" ]]; then
  warn "You are on branch '$CURRENT_BRANCH', but workflow targets '$TARGET_BRANCH'."
  if confirm "Switch to '$TARGET_BRANCH' now?" "y"; then
    # Check if target branch exists locally or remotely
    if git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
      git checkout "$TARGET_BRANCH"
    elif git ls-remote --exit-code --heads "$REMOTE" "$TARGET_BRANCH" >/dev/null 2>&1; then
      git fetch "$REMOTE" "$TARGET_BRANCH"
      git checkout "$TARGET_BRANCH"
    else
      die "Branch '$TARGET_BRANCH' does not exist locally or on remote '$REMOTE'."
    fi
    CURRENT_BRANCH="$TARGET_BRANCH"
    info "Switched to branch '$CURRENT_BRANCH'."
  else
    if ! confirm "Continue on '$CURRENT_BRANCH' anyway?" "n"; then
      exit 1
    fi
  fi
fi

# Check for uncommitted changes
if [[ -n "$(git status --porcelain)" ]]; then
  warn "You have uncommitted changes."
  if ! confirm "Continue (may commit version bump)?" "y"; then exit 1; fi
fi

# --- VERSION HANDLING ---

# Read version from pyproject.toml (first match of version = "...")
get_pyproject_version() {
  awk -F '"' '/^\s*version\s*=\s*"/ {print $2; exit}' "$PYPROJECT"
}

# Read __version__ from __init__.py
get_init_version() {
  awk -F '"' '/__version__\s*=\s*"/ {print $2; exit}' "$INIT_FILE"
}

# Update version in both pyproject.toml and __init__.py using Python (safe replace)
set_versions() {
  local new="$1"
  python3 - "$PYPROJECT" "$INIT_FILE" "$new" <<'PY'
import sys, re, pathlib
pyproject, initf, new = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]

def sub_file(p: pathlib.Path, pattern: str, repl: str):
    txt = p.read_text(encoding='utf-8')
    new_txt, n = re.subn(pattern, repl, txt, flags=re.M)
    if n == 0:
        print(f"[WARN] No match in {p} for pattern: {pattern}", file=sys.stderr)
    p.write_text(new_txt, encoding='utf-8')

# pyproject: version = "X"
sub_file(pyproject, r'(?m)^(\s*version\s*=\s*")([^"]+)(")', r'\1'+new+r'\3')
# __init__.py: __version__ = "X"
sub_file(initf, r'(?m)^(__version__\s*=\s*")([^"]+)(")', r'\1'+new+r'\3')
PY
}

# Validate PEP 440 alpha version (e.g., 1.2.3a4)
is_alpha_pep440() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+a[0-9]+$ ]]
}

# Convert PEP 440 alpha to Git tag format (0.1.0a4 -> v0.1.0-alpha.4)
pep440_to_tag() {
  local v="$1"
  local base="${v%%a*}"
  local a="${v##*a}"
  echo "v${base}-alpha.${a}"
}

# Ensure files exist
[[ -f "$PYPROJECT" ]] || die "Cannot find $PYPROJECT"
[[ -f "$INIT_FILE" ]] || die "Cannot find $INIT_FILE"

# Read current versions
PV="$(get_pyproject_version || true)"
IV="$(get_init_version || true)"

echo "Detected versions:"
echo "  $PYPROJECT version:     ${PV:-<none>}"
echo "  $INIT_FILE __version__: ${IV:-<none>}"

# If mismatch, missing, or not alpha, prompt to update
if [[ -z "${PV:-}" || -z "${IV:-}" || "$PV" != "$IV" ]] || ! is_alpha_pep440 "$PV"; then
  warn "Version mismatch or not an alpha version."
  NEWV="$(ask "Enter alpha version (PEP 440, e.g., 0.1.0a4)" "${PV:-0.1.0a1}")"
  is_alpha_pep440 "$NEWV" || die "Version '$NEWV' is not alpha (expected like 0.1.0a4)."
  echo "Updating versions to $NEWV ..."
  set_versions "$NEWV"
  git add "$PYPROJECT" "$INIT_FILE"
  git commit -m "chore(release): bump version to $NEWV [alpha]"
  PV="$NEWV"; IV="$NEWV"
  info "Versions updated and committed."
else
  info "Versions are consistent and alpha: $PV"
fi

# Derive Git tag name
TAG="$(pep440_to_tag "$PV")"
echo "Proposed tag: ${BLU}${TAG}${NC} (derived from ${PV})"

# --- BUILD AND VALIDATE PACKAGE ---

# Install build tools if missing
if ! python3 -c "import build" >/dev/null 2>&1; then
  info "Installing build tooling (build, twine)…"
  python3 -m pip install --upgrade pip >/dev/null
  python3 -m pip install build twine >/dev/null
fi

# Clean previous build artifacts
info "Cleaning dist/ …"
rm -rf dist build *.egg-info

# Build package (sdist + wheel)
info "Building sdist & wheel …"
python3 -m build

# Validate metadata with twine
info "Validating metadata with twine …"
python3 -m twine check dist/*

# Optional: local smoke test install from built wheel
if confirm "Run local smoke install from built wheel?" "y"; then
  WHEEL="$(ls dist/*.whl | head -n1)"
  python3 -m pip install --no-deps --force-reinstall "$WHEEL"
  python3 - <<'PY'
try:
    import analytics
    print("✓ Imported 'analytics' successfully")
except Exception as e:
    print("Import failed:", e)
    raise SystemExit(1)
PY
  info "Smoke install OK."
fi

# --- PUSH BRANCH AND TAG ---

# Push current branch (if not already up to date)
if confirm "Push current branch '$CURRENT_BRANCH' to $REMOTE?" "y"; then
  git push "$REMOTE" "$CURRENT_BRANCH"
fi

# Create signed or unsigned tag
SIGN="$(ask "Sign tag with GPG? (y/n)" "$SIGN_TAG_DEFAULT")"
if [[ "$SIGN" =~ ^[Yy]$ ]]; then
  git tag -s "$TAG" -m "Alpha release $PV"
else
  git tag "$TAG" -m "Alpha release $PV"
fi

echo "Created tag: $TAG"

# Push tag to remote to trigger GitHub Actions workflow
if confirm "Push tag '$TAG' to $REMOTE and trigger workflow?" "y"; then
  git push "$REMOTE" "$TAG"
  info "Tag pushed. GitHub Actions will build, create a pre-release, and publish to TestPyPI."
else
  warn "Tag not pushed. You can push later with: git push $REMOTE $TAG"
fi

# --- FINAL VALIDATION INSTRUCTIONS ---
PKG_NAME_PIP="picture-analytics"   # pip normalizes underscores to hyphens
echo
echo "Validation (after workflow publishes to TestPyPI):"
echo "  pip install --index-url https://test.pypi.org/simple/ --no-deps ${PKG_NAME_PIP}==${PV}"
echo
info "Alpha release script complete."
