#!/usr/bin/env bash
# ==============================================================================
# ALPHA_RELEASE_TOOL.sh
#
# Purpose:
#   Interactive helper to cut an **alpha** prerelease for this repo.
#   - Verifies branch & workspace state
#   - Reads & validates versions in pyproject.toml and __init__.py
#   - Lets you bump/choose a new alpha version (PEP 440: X.Y.ZaN)
#   - Builds the package (sdist + wheel) and validates metadata
#   - Creates and (optionally) pushes a Git tag `vX.Y.Z-alpha.N`
#     that triggers your GitHub Actions workflow to:
#       • publish to TestPyPI
#       • create a GitHub pre-release with artifacts
#
# Usage:
#   chmod +x bash/ALPHA_RELEASE_TOOL.sh
#   bash bash/ALPHA_RELEASE_TOOL.sh
#
# Notes:
#   - Adjust INIT_FILE and smoke test import if your package path/name differs.
#   - This script uses system `python3`. If you prefer a venv, activate it first
#     or adapt PYTHON_CMD below to point to your venv’s python.
# ==============================================================================

set -euo pipefail  # safer bash: fail on errors/undefined vars; pipefail propagates failures

# ------------------------------------------------------------------------------
# 🔧 CONFIGURATION — tailor these to your repository layout
# ------------------------------------------------------------------------------
PYPROJECT="./pyproject.toml"             # Path to pyproject.toml
INIT_FILE="./src/scripts/__init__.py"    # Path to __init__.py containing __version__
TARGET_BRANCH="develop-alpha"            # Branch that alpha releases should come from
REMOTE="origin"                          # Remote to push branch/tag to
SIGN_TAG_DEFAULT="n"                     # Default for "sign git tag?" prompt: 'y' or 'n'

# Optional: prefer venv python if active; fallback to system python3
if [[ -n "${VIRTUAL_ENV:-}" && -x "${VIRTUAL_ENV}/bin/python" ]]; then
  PYTHON_CMD="${VIRTUAL_ENV}/bin/python"
else
  PYTHON_CMD="python3"
fi

# ------------------------------------------------------------------------------
# 🎨 COLORS & PROMPT HELPERS — pretty output + interactive prompts
# ------------------------------------------------------------------------------
RED="$(printf '\033[31m')"; GRN="$(printf '\033[32m')"; YEL="$(printf '\033[33m')"; BLU="$(printf '\033[34m')"; NC="$(printf '\033[0m')"

ask() {
  # ask "Question" "default" -> echoes answer (or default if empty)
  local q="$1"; local d="${2:-}"
  read -r -p "$(printf "${BLU}?${NC} %s %s " "$q" "${d:+[$d]}")" ans || true
  echo "${ans:-$d}"
}

confirm() {
  # confirm "Question" "default(y/n)" -> returns 0 for yes, 1 for no
  local q="$1"; local d="${2:-y}"
  local ans; ans="$(ask "$q" "$d")"
  [[ "$ans" =~ ^[Yy]$ ]]
}

die()  { echo -e "${RED}✖ $*${NC}"; exit 1; }
info() { echo -e "${GRN}✔${NC} $*"; }
warn() { echo -e "${YEL}!${NC} $*"; }

require_cmd() {
  # require_cmd <name> -> exits if command is missing
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

# ------------------------------------------------------------------------------
# 🧩 VERSION IO HELPERS — read/update versions in files
# ------------------------------------------------------------------------------
get_pyproject_version() {
  # Extracts: version = "X.Y.ZaN" from pyproject.toml (first occurrence)
  awk -F '"' '/^\s*version\s*=\s*"/ {print $2; exit}' "$PYPROJECT"
}

get_init_version() {
  # Extracts: __version__ = "X.Y.ZaN" from __init__.py
  awk -F '"' '/__version__\s*=\s*"/ {print $2; exit}' "$INIT_FILE"
}

set_versions() {
  local new="$1"
  "$PYTHON_CMD" - "$PYPROJECT" "$INIT_FILE" "$new" <<'PY'
import sys, re, pathlib
pyproject = pathlib.Path(sys.argv[1])
initf     = pathlib.Path(sys.argv[2])
new       = sys.argv[3]

def sub_file(p: pathlib.Path, pattern: str):
    text = p.read_text(encoding='utf-8')
    # use \g<1> / \g<3> to avoid \1 + digits being parsed as group 10, etc.
    new_text, n = re.subn(pattern, r'\g<1>'+new+r'\g<3>', text, flags=re.M)
    if n == 0:
        print(f"[WARN] No match for version in {p}", file=sys.stderr)
    p.write_text(new_text, encoding='utf-8')

# pyproject.toml: version = "X" or 'X'
sub_file(pyproject, r'(?m)^(\s*version\s*=\s*[\'"])([^\'"]+)([\'"])')

# __init__.py: __version__ = "X" or 'X'
sub_file(initf,     r'(?m)^(#__version__\b.*|(__version__\s*=\s*[\'"]))([^\'"]+)([\'"])')
PY
}


# ------------------------------------------------------------------------------
# 🔢 VERSION MATH (ALPHA ONLY) — validate/bump/convert
# ------------------------------------------------------------------------------
is_alpha_pep440() {
  # Validates PEP 440 alpha: X.Y.ZaN (e.g., 0.1.0a4)
  [[ "$1" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)a([0-9]+)$ ]]
}

pep440_to_tag() {
  # Converts PEP 440 alpha -> git tag used by workflow:
  #   0.1.0a4  -> v0.1.0-alpha.4
  local v="$1"
  [[ "$v" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)a([0-9]+)$ ]] || return 1
  echo "v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}-alpha.${BASH_REMATCH[4]}"
}

bump_alpha() {
  # 0.1.0a4 -> 0.1.0a5
  local v="$1"
  is_alpha_pep440 "$v" || die "Not an alpha version: $v"
  local M="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}" p="${BASH_REMATCH[3]}" a="${BASH_REMATCH[4]}"
  echo "${M}.${m}.${p}a$((a+1))"
}

bump_patch_alpha() {
  # 0.1.0a4 -> 0.1.1a1  (increment PATCH, reset alpha counter)
  local v="$1"
  is_alpha_pep440 "$v" || die "Not an alpha version: $v"
  local M="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}" p="${BASH_REMATCH[3]}"
  echo "${M}.${m}.$((p+1))a1"
}

bump_minor_alpha() {
  # 0.1.0a4 -> 0.2.0a1  (increment MINOR, reset PATCH & alpha)
  local v="$1"
  is_alpha_pep440 "$v" || die "Not an alpha version: $v"
  local M="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}"
  echo "${M}.$((m+1)).0a1"
}

# ------------------------------------------------------------------------------
# 🚦 PREFLIGHT — environment, repo, branch, cleanliness
# ------------------------------------------------------------------------------
require_cmd git
require_cmd "$PYTHON_CMD"
require_cmd sed
require_cmd awk

# Verify pip is available for chosen Python
if ! "$PYTHON_CMD" -m pip >/dev/null 2>&1; then
  die "pip not available for $($PYTHON_CMD -V 2>/dev/null || echo python). Activate your venv or install pip."
fi

# Ensure we are in a git repo
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not in a git repository."

# Check branch; offer to switch to TARGET_BRANCH
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" != "$TARGET_BRANCH" ]]; then
  warn "You are on branch '$CURRENT_BRANCH', but workflow targets '$TARGET_BRANCH'."
  if confirm "Switch to '$TARGET_BRANCH' now?" "y"; then
    # If local branch exists, checkout; else try fetching remote branch
    if git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
      git checkout "$TARGET_BRANCH"
    elif git ls-remote --exit-code --heads "$REMOTE" "$TARGET_BRANCH" >/dev/null 2>&1; then
      git fetch "$REMOTE" "$TARGET_BRANCH"
      git checkout "$TARGET_BRANCH"
    else
      die "Branch '$TARGET_BRANCH' does not exist locally or on '$REMOTE'."
    fi
    CURRENT_BRANCH="$TARGET_BRANCH"
    info "Switched to branch '$CURRENT_BRANCH'."
    git status -sb || true
  else
    confirm "Continue on '$CURRENT_BRANCH' anyway?" "n" || exit 1
  fi
fi

# Warn on uncommitted changes (script may commit version bump)
if [[ -n "$(git status --porcelain)" ]]; then
  warn "You have uncommitted changes."
  confirm "Continue (script may commit version bump)?" "y" || exit 1
fi

# Ensure key files exist
[[ -f "$PYPROJECT" ]] || die "Cannot find $PYPROJECT"
[[ -f "$INIT_FILE"  ]] || die "Cannot find $INIT_FILE"

# ------------------------------------------------------------------------------
# 🔍 READ CURRENT VERSIONS — from pyproject & __init__
# ------------------------------------------------------------------------------
PV="$(get_pyproject_version || true)"
IV="$(get_init_version || true)"

echo "Detected versions:"
echo "  $PYPROJECT version:     ${PV:-<none>}"
echo "  $INIT_FILE __version__: ${IV:-<none>}"

# ------------------------------------------------------------------------------
# 🧭 CHOOSE VERSION — fix mismatches or offer bumps even if consistent
# ------------------------------------------------------------------------------
if [[ -z "${PV:-}" || -z "${IV:-}" || "$PV" != "$IV" ]] || ! is_alpha_pep440 "$PV"; then
  # If missing/mismatched/not-alpha: ask explicitly for a correct alpha version
  warn "Version mismatch or not an alpha version (expected PEP 440 like X.Y.ZaN)."
  NEWV="$(ask "Enter alpha version (e.g., 0.1.0a4)" "${PV:-0.1.0a1}")"
  is_alpha_pep440 "$NEWV" || die "Version '$NEWV' is not alpha (expected X.Y.ZaN)."
  echo "Updating versions to $NEWV ..."
  set_versions "$NEWV"
  git add "$PYPROJECT" "$INIT_FILE"
  git commit -m "chore(release): bump version to $NEWV [alpha]"
  PV="$NEWV"; IV="$NEWV"
  info "Versions updated and committed."
else
  # Versions are consistent alpha; offer a menu for bump strategies
  info "Versions are consistent and alpha: $PV"
  echo
  echo "Choose a version action:"
  echo "  1) Keep current                -> $PV"
  echo "  2) Bump alpha (aN + 1)         -> $(bump_alpha "$PV")"
  echo "  3) New PATCH alpha (Z+1 a1)    -> $(bump_patch_alpha "$PV")"
  echo "  4) New MINOR alpha (Y+1.0 a1)  -> $(bump_minor_alpha "$PV")"
  echo "  5) Enter custom (X.Y.ZaN)"
  choice="$(ask "Select [1-5]" "1")"
  case "$choice" in
    1) NEWV="$PV" ;;
    2) NEWV="$(bump_alpha "$PV")" ;;
    3) NEWV="$(bump_patch_alpha "$PV")" ;;
    4) NEWV="$(bump_minor_alpha "$PV")" ;;
    5) NEWV="$(ask "Enter alpha version (X.Y.ZaN)" "$PV")"; is_alpha_pep440 "$NEWV" || die "Not alpha: $NEWV" ;;
    *) die "Invalid choice";;
  esac

  if [[ "$NEWV" != "$PV" ]]; then
    echo "Updating versions to $NEWV …"
    set_versions "$NEWV"
    git add "$PYPROJECT" "$INIT_FILE"
    git commit -m "chore(release): bump version to $NEWV [alpha]"
    PV="$NEWV"; IV="$NEWV"
    info "Versions updated and committed."
  fi
fi

# ------------------------------------------------------------------------------
# 🏷️  DERIVE GIT TAG — from PEP 440 alpha -> vX.Y.Z-alpha.N
# ------------------------------------------------------------------------------
TAG="$(pep440_to_tag "$PV")" || die "Cannot derive tag from $PV"
echo "Proposed tag: ${BLU}${TAG}${NC} (derived from ${PV})"

# ------------------------------------------------------------------------------
# 🧪 BUILD & VALIDATE — sdist+wheel, twine metadata check
# ------------------------------------------------------------------------------
# Ensure build tooling present in the chosen Python environment
if ! "$PYTHON_CMD" -c "import build" >/dev/null 2>&1; then
  info "Installing build tooling (build, twine)…"
  "$PYTHON_CMD" -m pip install --upgrade pip >/dev/null
  "$PYTHON_CMD" -m pip install build twine >/dev/null
fi

# Clean old artifacts to avoid accidentally re-uploading stale files
info "Cleaning dist/ build/ *.egg-info …"
rm -rf dist build *.egg-info

# Create fresh artifacts
info "Building sdist & wheel …"
"$PYTHON_CMD" -m build

# Validate metadata (README rendering, classifiers, etc.)
info "Validating metadata with twine …"
"$PYTHON_CMD" -m twine check dist/*

# Optional local smoke-test: install built wheel and import the package
if confirm "Run local smoke install from built wheel?" "y"; then
  WHEEL="$(ls dist/*.whl | head -n1)"
  "$PYTHON_CMD" -m pip install --no-deps --force-reinstall "$WHEEL"
  # ⚠️ Adjust 'scripts' to your importable top-level package name if different
  "$PYTHON_CMD" - <<'PY'
try:
    import scripts  # change to your real package name if not 'scripts'
    print("✓ Import smoke test OK")
except Exception as e:
    print("Import failed:", e)
    raise SystemExit(1)
PY
  info "Smoke install OK."
fi

# ------------------------------------------------------------------------------
# ⬆️  PUSH BRANCH — ensure remote has the version-bump commit
# ------------------------------------------------------------------------------
if confirm "Push current branch '$CURRENT_BRANCH' to $REMOTE?" "y"; then
  git push "$REMOTE" "$CURRENT_BRANCH"
fi

# ------------------------------------------------------------------------------
# 🔐 CREATE & PUSH TAG — signed (GPG) or unsigned, to trigger workflow
# ------------------------------------------------------------------------------
SIGN="$(ask "Sign tag with GPG? (y/n)" "$SIGN_TAG_DEFAULT")"
if [[ "$SIGN" =~ ^[Yy]$ ]]; then
  git tag -s "$TAG" -m "Alpha release $PV"
else
  git tag    "$TAG" -m "Alpha release $PV"
fi
echo "Created tag: $TAG"

if confirm "Push tag '$TAG' to $REMOTE and trigger workflow?" "y"; then
  git push "$REMOTE" "$TAG"
  info "Tag pushed. GitHub Actions will build, create a pre-release, and publish to TestPyPI."
else
  warn "Tag not pushed. Later, run: git push $REMOTE $TAG"
fi

# ------------------------------------------------------------------------------
# ✅ POST-PUBLISH VALIDATION — easy pip install command (TestPyPI)
# ------------------------------------------------------------------------------
# PyPI normalizes underscores to hyphens for package names in pip install.
# If your distribution name in pyproject is "picture_analytics", the pip name is "picture-analytics".
PKG_NAME_PIP="picture-analytics"
echo
echo "After your workflow publishes to TestPyPI, validate install with:"
echo "  pip install --index-url https://test.pypi.org/simple/ --no-deps ${PKG_NAME_PIP}==${PV}"
echo
info "Alpha release flow complete."
