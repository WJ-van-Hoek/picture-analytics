#!/usr/bin/env bash
# ==============================================================================
# ALPHA_RELEASE_TOOL.sh
#
# Purpose:
#   Interactive helper to cut an **alpha** prerelease for this repo.
#   - Verifies branch & workspace state
#   - Confirms which alpha version to release (PEP 440: X.Y.ZaN)
#   - Builds the package (sdist + wheel) and validates metadata
#   - Creates and (optionally) pushes a Git tag `vX.Y.Z-alpha.N`
#     that triggers your GitHub Actions workflow to:
#       • publish to TestPyPI
#       • create a GitHub pre-release with artifacts
# ==============================================================================

set -euo pipefail  # safer bash

# ------------------------------------------------------------------------------
# 🔧 CONFIGURATION — tailor these to your repository layout
# ------------------------------------------------------------------------------
PYPROJECT="./pyproject.toml"             # Path to pyproject.toml
INIT_FILE="./src/scripts/__init__.py"    # Path to __init__.py containing __version__
RC_BRANCH="rc-alpha"                     # Branch that alpha releases should come from
REMOTE="origin"                          # Remote to push branch/tag to
SIGN_TAG_DEFAULT="n"                     # Default for "sign git tag?" prompt: 'y' or 'n'

# --- state flags so we can report whether a release actually ran ---
DID_PUSH_BRANCH=false
DID_PUSH_TAG=false

# Alpha-changelog path (set to "" to disable the changelog check)
ALPHA_CHANGELOG="${ALPHA_CHANGELOG:-changelogs/alpha.md}"

# Enforce that version only moves forward (reserved for future use)
ENFORCE_MONOTONIC_VERSION="${ENFORCE_MONOTONIC_VERSION:-true}"

# Require GPG checks before allowing signed tag; auto-export GPG_TTY
GPG_PREPARE="${GPG_PREPARE:-true}"

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
  local q="$1"; local d="${2:-}"
  read -r -p "$(printf "${BLU}?${NC} %s %s " "$q" "${d:+[$d]}")" ans || true
  echo "${ans:-$d}"
}

confirm() {
  local q="$1"; local d="${2:-y}"
  local ans; ans="$(ask "$q" "$d")"
  [[ "$ans" =~ ^[Yy]$ ]]
}

die()  { echo -e "${RED}✖ $*${NC}"; exit 1; }
info() { echo -e "${GRN}✔${NC} $*"; }
warn() { echo -e "${YEL}!${NC} $*"; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

# Remove build artifacts created during this run
clean_artifacts() {
  echo "Removing build artifacts: dist/, build/, *.egg-info"
  rm -rf dist build *.egg-info
  info "Cleanup complete."
}

# ----------------------------------------------------------------------
# 🔎 ensure_tag_available — verify a tag doesn't exist or offer safe cleanup
# ----------------------------------------------------------------------
ensure_tag_available() {
  local tag="$1" remote="$2"
  if git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
    warn "Tag '$tag' already exists locally."
    local exists_remote=false
    if git ls-remote --exit-code --tags "$remote" "refs/tags/$tag" >/dev/null 2>&1; then
      exists_remote=true
      warn "Tag '$tag' also exists on remote '$remote'."
    fi

    local release_exists="unknown"
    if command -v gh >/dev/null 2>&1; then
      if gh release view "$tag" >/dev/null 2>&1; then
        release_exists="yes"
      else
        release_exists="no"
      fi
    fi

    if [[ "$release_exists" == "yes" ]]; then
      die "A GitHub Release for '$tag' exists. Do NOT delete this tag. Please bump version instead."
    fi

    if [[ "$exists_remote" == true ]]; then
      if [[ "$release_exists" == "unknown" ]]; then
        warn "Cannot verify GitHub Release state (gh not installed). Refusing to delete remote tag."
        die "Please bump version or install GitHub CLI (https://cli.github.com/) to allow safe checks."
      fi
      if confirm "Delete tag '$tag' from remote '$remote' and locally (no release found)?" "n"; then
        git push "$remote" ":refs/tags/$tag"
        git tag -d "$tag"
        info "Deleted tag '$tag' on remote and locally."
      else
        die "Tag '$tag' exists. Aborting to avoid accidental overwrite."
      fi
    else
      if confirm "Delete local tag '$tag' (no remote tag found)?" "y"; then
        git tag -d "$tag"
        info "Deleted local tag '$tag'."
      else
        die "Tag '$tag' exists locally. Aborting to avoid accidental overwrite."
      fi
    fi
  fi
}

# ------------------------------------------------------------------------------
# 🧩 VERSION IO HELPERS — read/update versions in files
# ------------------------------------------------------------------------------
get_pyproject_version() { awk -F '"' '/^\s*version\s*=\s*"/ {print $2; exit}' "$PYPROJECT"; }
get_init_version()      { awk -F '"' '/__version__\s*=\s*"/ {print $2; exit}' "$INIT_FILE"; }

set_versions() {
  local new="$1"
  "$PYTHON_CMD" - "$PYPROJECT" "$INIT_FILE" "$new" <<'PY'
import sys, re, pathlib
pyproject = pathlib.Path(sys.argv[1])
initf     = pathlib.Path(sys.argv[2])
new       = sys.argv[3]

def sub_pyproject(p):
    pat = re.compile(r'(?m)^(\s*version\s*=\s*)(["\'])([^"\']+)(\2)')
    txt = p.read_text(encoding='utf-8')
    txt, n = pat.subn(lambda m: f'{m.group(1)}{m.group(2)}{new}{m.group(2)}', txt, count=1)
    if n == 0:
        print(f"[WARN] No version line updated in {p}", file=sys.stderr)
    p.write_text(txt, encoding='utf-8')

def sub_init(p):
    pat = re.compile(r'(?m)^(\s*__version__\s*=\s*)(["\'])([^"\']*)(\2)')
    txt = p.read_text(encoding='utf-8')
    txt, n = pat.subn(lambda m: f'{m.group(1)}{m.group(2)}{new}{m.group(2)}', txt, count=1)
    if n == 0:
        print(f"[WARN] No __version__ line updated in {p}", file=sys.stderr)
    p.write_text(txt, encoding='utf-8')

sub_pyproject(pyproject)
sub_init(initf)
PY
}

# ------------------------------------------------------------------------------
# 🔢 VERSION MATH (ALPHA ONLY)
# ------------------------------------------------------------------------------
is_alpha_pep440() { [[ "$1" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)a([0-9]+)$ ]]; }
pep440_to_tag()   { [[ "$1" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)a([0-9]+)$ ]] || return 1; echo "v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}-alpha.${BASH_REMATCH[4]}"; }
bump_alpha()      { is_alpha_pep440 "$1" || die "Not an alpha version: $1"; local M="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}" p="${BASH_REMATCH[3]}" a="${BASH_REMATCH[4]}"; echo "${M}.${m}.${p}a$((a+1))"; }
bump_patch_alpha(){ is_alpha_pep440 "$1" || die "Not an alpha version: $1"; local M="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}" p="${BASH_REMATCH[3]}"; echo "${M}.${m}.$((p+1))a1"; }
bump_minor_alpha(){ is_alpha_pep440 "$1" || die "Not an alpha version: $1"; local M="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}"; echo "${M}.$((m+1)).0a1"; }

# ----------------------------------------------------------------------
# 🔐 GPG helpers — make signed tagging reliable in TTY/CI
# ----------------------------------------------------------------------
prepare_gpg() {
  [[ "$GPG_PREPARE" == "true" ]] || return 0
  if command -v gpg >/dev/null 2>&1; then
    [[ -t 1 ]] && export GPG_TTY="$(tty)"
    if ! gpg --list-secret-keys --keyid-format=long >/dev/null 2>&1; then
      die "No GPG secret keys found. Generate/import a key, then set git config user.signingkey <KEYID>."
    fi
    if ! git config --get user.signingkey >/dev/null; then
      warn "git config user.signingkey is not set."
      local kid
      kid="$(gpg --list-secret-keys --keyid-format=long | awk '/^sec/{print $2}' | sed 's|.*/||' | head -n1)"
      if [[ -n "$kid" ]] && confirm "Set user.signingkey to $kid?" "y"; then
        git config --local user.signingkey "$kid"
        info "Configured user.signingkey=$kid (local)."
      else
        die "No signing key configured. Set one with: git config --local user.signingkey <KEYID>"
      fi
    fi
  else
    die "gpg not found. Install GnuPG to create signed tags."
  fi
}

# ----------------------------------------------------------------------
# 📝 Ensure alpha changelog is updated for this release (content check)
# ----------------------------------------------------------------------
ensure_alpha_changelog_updated() {
  local version="$1"   # e.g., 0.1.0a4
  local tag="$2"       # e.g., v0.1.0-alpha.4

  [[ -n "$ALPHA_CHANGELOG" ]] || return 0
  [[ -f "$ALPHA_CHANGELOG" ]] || die "Alpha changelog '$ALPHA_CHANGELOG' not found."

  local header_pattern="(^##\s+${version}\b)|(^##\s+${tag}\b)"
  if ! grep -Eq "$header_pattern" "$ALPHA_CHANGELOG"; then
    die "Alpha changelog '$ALPHA_CHANGELOG' does not contain an entry for ${version} (${tag}). Please update it."
  fi

  local section
  section="$(awk -v ver="$version" -v tag="$tag" '
    BEGIN { found=0 }
    match($0, "^##[[:space:]]+(" ver "|" tag ")") { found=1; next }
    found && /^##[[:space:]]+/ { exit }
    found { print }
  ' "$ALPHA_CHANGELOG")"

  section="$(echo "$section" | sed '/^[[:space:]]*$/d')"
  if [[ -z "$section" ]]; then
    die "Alpha changelog entry for ${version} (${tag}) is empty. Please add release notes."
  fi

  # Warn if not touched recently; allow override
  if ! git diff --name-only HEAD~1..HEAD | grep -qx "$ALPHA_CHANGELOG"; then
    warn "Changelog '$ALPHA_CHANGELOG' not updated in the last commit."
    confirm "Proceed anyway?" "n" || die "Aborting: changelog not updated."
  fi
}

# ----------------------------------------------------------------------
# 💾 Commit WIP before switching branches (optional)
# ----------------------------------------------------------------------
commit_wip_before_switch() {
  # If truly nothing to commit (tracked, staged, or untracked), just return
  if git diff --quiet && git diff --cached --quiet && [[ -z "$(git ls-files --others --exclude-standard)" ]]; then
    info "No changes to commit on '$CURRENT_BRANCH'."
    return 0
  fi

  echo
  echo "Current working tree on '$CURRENT_BRANCH':"
  git -c color.status=always status -sb || true
  echo

  # Include untracked files too?
  if confirm "Add ALL changes including untracked files (git add -A)?" "y"; then
    git add -A
  else
    git add -u
  fi

  # If nothing actually got staged, skip commit
  if git diff --cached --quiet; then
    warn "No staged changes after add; skipping commit."
  else
    local msg
    msg="$(ask "Commit message" "chore: WIP before switching to $RC_BRANCH")"
    git commit -m "$msg"
    info "Committed WIP on '$CURRENT_BRANCH'."
  fi

  # Optional push
  if confirm "Push '$CURRENT_BRANCH' to '$REMOTE' now?" "n"; then
    git push "$REMOTE" "$CURRENT_BRANCH"
    DID_PUSH_BRANCH=true
    info "Pushed branch '$CURRENT_BRANCH' to '$REMOTE'."
  fi
}

# ----------------------------------------------------------------------
# ✅ Final confirmation before building
# ----------------------------------------------------------------------
confirm_release_version() {
  local v="$1" t="$2"
  echo
  echo "About to build and release:"
  echo "  Version: $v"
  echo "  Tag:     $t"
  echo "  Branch:  $CURRENT_BRANCH"
  [[ -n "$ALPHA_CHANGELOG" ]] && echo "  Changelog: $ALPHA_CHANGELOG"
  confirm "Proceed with building this version?" "y"
}

# ------------------------------------------------------------------------------
# 🚦 PREFLIGHT — REQUIRED CMDS
# ------------------------------------------------------------------------------
require_cmd git
require_cmd "$PYTHON_CMD"
require_cmd sed
require_cmd awk

# ------------------------------------------------------------------------------
# ✅ STEP 1: REPO & BRANCH CHECK — RUN FIRST
# ------------------------------------------------------------------------------
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not in a git repository."

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" != "$RC_BRANCH" ]]; then
  warn "You are on branch '$CURRENT_BRANCH', but workflow targets '$RC_BRANCH'."
  if confirm "Switch to '$RC_BRANCH' now?" "y"; then

    # Offer to commit before switching if there are changes
    if [[ -n "$(git status --porcelain)" ]]; then
      warn "You have uncommitted changes on '$CURRENT_BRANCH'."
      if confirm "Commit these changes on '$CURRENT_BRANCH' before switching?" "y"; then
        commit_wip_before_switch
      else
        warn "Proceeding without committing changes."
      fi
    fi

    # Checkout/pull target branch
    if git show-ref --verify --quiet "refs/heads/$RC_BRANCH"; then
      git checkout "$RC_BRANCH"
    elif git ls-remote --exit-code --heads "$REMOTE" "$RC_BRANCH" >/dev/null 2>&1; then
      git fetch "$REMOTE" "$RC_BRANCH"
      git checkout "$RC_BRANCH"
    else
      die "Branch '$RC_BRANCH' does not exist locally or on '$REMOTE'."
    fi
    CURRENT_BRANCH="$RC_BRANCH"
    info "Switched to branch '$CURRENT_BRANCH'."
    git status -sb || true
  else
    confirm "Continue on '$CURRENT_BRANCH' anyway?" "n" || exit 1
  fi
fi

# ------------------------------------------------------------------------------
# Warn on uncommitted changes (script may commit version bump)
# ------------------------------------------------------------------------------
if [[ -n "$(git status --porcelain)" ]]; then
  warn "You have uncommitted changes."
  confirm "Continue (script may commit version bump)?" "y" || exit 1
fi

# Ensure key files exist
[[ -f "$PYPROJECT" ]] || die "Cannot find $PYPROJECT"
[[ -f "$INIT_FILE"  ]] || die "Cannot find $INIT_FILE"

# ------------------------------------------------------------------------------
# 🐍 ALWAYS-ON VENV — reuse if exists, create if missing
# ------------------------------------------------------------------------------
VENV_DIR="${VENV_DIR:-.venv}"
VENV_PIP_INSTALL="${VENV_PIP_INSTALL:-.}"  # default installs local project in editable mode

command -v deactivate >/dev/null 2>&1 && deactivate || true
if [[ ! -d "$VENV_DIR" ]]; then
  echo "Creating Python virtual environment in $VENV_DIR …"
  python3 -m venv "$VENV_DIR"
fi
# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"
PYTHON_CMD="$VENV_DIR/bin/python"
"$PYTHON_CMD" -m pip install --upgrade pip
"$PYTHON_CMD" -m pip install --upgrade setuptools wheel build twine
pip install "${VENV_PIP_INSTALL:-.}"

# Verify pip is available for chosen Python
if ! "$PYTHON_CMD" -m pip >/dev/null 2>&1; then
  die "pip not available for $($PYTHON_CMD -V 2>/dev/null || echo python). Activate your venv or install pip."
fi

# ------------------------------------------------------------------------------
# 🔍 READ CURRENT VERSIONS — from pyproject & __init__
# ------------------------------------------------------------------------------
PV="$(get_pyproject_version || true)"
IV="$(get_init_version || true)"
echo "Detected versions:"
echo "  $PYPROJECT version:     ${PV:-<none>}"
echo "  $INIT_FILE __version__: ${IV:-<none>}"

# ------------------------------------------------------------------------------
# 🧭 STEP 2: CHOOSE VERSION — confirm which alpha we are releasing
# ------------------------------------------------------------------------------
if [[ -z "${PV:-}" || -z "${IV:-}" || "$PV" != "$IV" ]] || ! is_alpha_pep440 "$PV"; then
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
# 🏷️  STEP 3: DERIVE GIT TAG — from PEP 440 alpha -> vX.Y.Z-alpha.N
# ------------------------------------------------------------------------------
TAG="$(pep440_to_tag "$PV")" || die "Cannot derive tag from $PV"
echo "Proposed tag: ${BLU}${TAG}${NC} (derived from ${PV})"

# ------------------------------------------------------------------------------
# 📝 STEP 4: CHANGELOG CHECKS — run after version is confirmed
#   First: lightweight "recent changes" gate for the changelog file
#   Then : strict content check for the chosen version/tag
# ------------------------------------------------------------------------------
if [[ -n "$ALPHA_CHANGELOG" ]]; then
  if [[ ! -f "$ALPHA_CHANGELOG" ]]; then
    warn "Alpha changelog '$ALPHA_CHANGELOG' not found."
    confirm "Proceed anyway?" "n" || die "Aborting: changelog missing."
  else
    if git diff --name-only | grep -qx "$ALPHA_CHANGELOG" \
       || git diff --name-only --cached | grep -qx "$ALPHA_CHANGELOG" \
       || git diff --name-only HEAD~1..HEAD | grep -qx "$ALPHA_CHANGELOG"; then
      info "Changelog '$ALPHA_CHANGELOG' has recent changes."
    else
      warn "Changelog '$ALPHA_CHANGELOG' shows no recent changes."
      confirm "Proceed anyway?" "n" || die "Aborting: changelog not updated."
    fi
  fi
fi

# Strict content/version check (must contain the new version entry & non-empty body)
ensure_alpha_changelog_updated "$PV" "$TAG"

# Final confirmation before building
if ! confirm_release_version "$PV" "$TAG"; then
  die "Release cancelled by user."
fi

# ------------------------------------------------------------------------------
# 🧪 BUILD & VALIDATE — sdist+wheel, twine metadata check
# ------------------------------------------------------------------------------
if ! "$PYTHON_CMD" -c "import build" >/dev/null 2>&1; then
  info "Installing build tooling (build, twine)…"
  "$PYTHON_CMD" -m pip install --upgrade pip >/dev/null
  "$PYTHON_CMD" -m pip install build twine >/dev/null
fi

info "Cleaning dist/ build/ *.egg-info …"
rm -rf dist build *.egg-info

info "Building sdist & wheel …"
"$PYTHON_CMD" -m build

info "Validating metadata with twine …"
"$PYTHON_CMD" -m twine check dist/*

# ------------------------------------------------------------------------------
# 🧪 OPTIONAL SMOKE TEST — temp venv
# ------------------------------------------------------------------------------
if confirm "Run local smoke install from built wheel (temp venv)?" "y"; then
  WHEEL="$(ls dist/*.whl | head -n1)"
  [[ -n "$WHEEL" ]] || die "No wheel found in dist/"

  MODULE_IMPORT="$(basename "$(dirname "$INIT_FILE")")"
  [[ -n "$MODULE_IMPORT" ]] || die "Could not derive module name from INIT_FILE=$INIT_FILE"

  SMOKE_VENV=".smoke-venv"
  rm -rf "$SMOKE_VENV"
  "$PYTHON_CMD" -m venv "$SMOKE_VENV"

  SMOKE_PY="$SMOKE_VENV/bin/python"
  "$SMOKE_PY" -m pip install -U pip >/dev/null

  echo "Running strict smoke test (no dependencies)…"
  "$SMOKE_PY" -m pip install --no-deps "$WHEEL" >/dev/null

  set +e
  "$SMOKE_PY" - <<PY
import sys
try:
    import ${MODULE_IMPORT}
    print("✓ Import smoke test OK (no deps)")
    sys.exit(0)
except ModuleNotFoundError as e:
    print(f"Dependency missing in strict test: {e}")
    sys.exit(2)
except Exception as e:
    print(f"Import failed in strict test: {e}")
    sys.exit(1)
PY
  STATUS=$?
  set -e

  if [[ $STATUS -eq 2 ]]; then
    echo "Retrying smoke test with dependencies installed…"
    "$SMOKE_PY" -m pip install "$WHEEL" >/dev/null
    "$SMOKE_PY" - <<PY
import sys
try:
    import ${MODULE_IMPORT}
    print("✓ Import smoke test OK (with deps)")
    sys.exit(0)
except Exception as e:
    print(f"Import failed even with deps: {e}")
    sys.exit(1)
PY
  elif [[ $STATUS -ne 0 ]]; then
    rm -rf "$SMOKE_VENV"
    die "Smoke test failed."
  fi

  rm -rf "$SMOKE_VENV"
  info "Smoke test completed and cleaned up."
fi

# Ensure we don't clobber an existing tag; offer safe cleanup if needed
ensure_tag_available "$TAG" "$REMOTE"

# ------------------------------------------------------------------------------
# 🔐 CREATE & PUSH TAG — signed (GPG) or unsigned, to trigger workflow
# ------------------------------------------------------------------------------
SIGN="$(ask "Sign tag with GPG? (y/n)" "$SIGN_TAG_DEFAULT")"
if [[ "$SIGN" =~ ^[Yy]$ ]]; then
  prepare_gpg
  git tag -s "$TAG" -m "Alpha release $PV"
else
  git tag    "$TAG" -m "Alpha release $PV"
fi
echo "Created tag: $TAG"

if confirm "Push tag '$TAG' to $REMOTE and trigger workflow?" "y"; then
  git commit --allow-empty -m "alpha release $PV"
  info "Created empty commit for Alpha release $PV"
  git push "$REMOTE" "$CURRENT_BRANCH"
  git push "$REMOTE" "$TAG"
  DID_PUSH_TAG=true
  info "Tag pushed. GitHub Actions will build, create a pre-release, and publish to TestPyPI."
else
  warn "Tag not pushed. Later, run: git push $REMOTE $TAG"
fi

# Optional cleanup
if [[ "$DID_PUSH_TAG" == true ]]; then
  if confirm "Clean up local build artifacts (dist/, build/, *.egg-info) now?" "y"; then
    clean_artifacts
  else
    info "Skipping artifact cleanup. You can remove them later with: rm -rf dist build *.egg-info"
  fi
fi

# 📣 FINAL STATUS
if [[ "$DID_PUSH_TAG" == true ]]; then
  info "Release EXECUTED: tag '$TAG' was pushed. Workflow should be running on GitHub."
else
  echo
  echo "=============================================================="
  echo "⚠️  Release NOT executed"
  echo "    The alpha tag was created locally but NOT pushed."
  echo "    No GitHub Actions workflow has been triggered."
  echo
  echo "    To execute the release now, run:"
  echo "      git push $REMOTE $TAG"
  echo "=============================================================="
  echo
fi

if [[ "$DID_PUSH_TAG" != true ]]; then
  exit 2  # non-zero indicates no release executed
fi

# ✅ POST-PUBLISH VALIDATION
PKG_NAME_PIP="picture-analytics"
echo
echo "After your workflow publishes to TestPyPI, validate install with:"
echo "  pip install --index-url https://test.pypi.org/simple/ --no-deps ${PKG_NAME_PIP}==${PV}"
echo
info "Alpha release flow complete."
