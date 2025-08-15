#!/usr/bin/env bash
# ==============================================================================
# ALPHA_RELEASE_TOOL.sh
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 🔧 CONFIGURATION
# ------------------------------------------------------------------------------
PYPROJECT="./pyproject.toml"
INIT_FILE="./src/scripts/__init__.py"
RC_BRANCH="alpha-rc"                     # target branch for alpha releases
REMOTE="origin"
SIGN_TAG_DEFAULT="n"

# State flags
DID_PUSH_BRANCH=false
DID_PUSH_TAG=false

# Changelog
ALPHA_CHANGELOG="${ALPHA_CHANGELOG:-changelogs/alpha.md}"

# Optional features
ENFORCE_MONOTONIC_VERSION="${ENFORCE_MONOTONIC_VERSION:-true}"
GPG_PREPARE="${GPG_PREPARE:-true}"

# Python selector
if [[ -n "${VIRTUAL_ENV:-}" && -x "${VIRTUAL_ENV}/bin/python" ]]; then
  PYTHON_CMD="${VIRTUAL_ENV}/bin/python"
else
  PYTHON_CMD="python3"
fi

# ------------------------------------------------------------------------------
# 🎨 UI HELPERS
# ------------------------------------------------------------------------------
RED="$(printf '\033[31m')"; GRN="$(printf '\033[32m')"; YEL="$(printf '\033[33m')"; BLU="$(printf '\033[34m')"; NC="$(printf '\033[0m')"
ask()      { local q="$1"; local d="${2:-}"; read -r -p "$(printf "${BLU}?${NC} %s %s " "$q" "${d:+[$d]}")" ans || true; echo "${ans:-$d}"; }
confirm()  { local q="$1"; local d="${2:-y}"; local ans; ans="$(ask "$q" "$d")"; [[ "$ans" =~ ^[Yy]$ ]]; }
die()      { echo -e "${RED}✖ $*${NC}"; exit 1; }
info()     { echo -e "${GRN}✔${NC} $*"; }
warn()     { echo -e "${YEL}!${NC} $*"; }
require_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

clean_artifacts() {
  echo "Removing build artifacts: dist/, build/, *.egg-info"
  rm -rf dist build *.egg-info
  info "Cleanup complete."
}

# ------------------------------------------------------------------------------
# 🔎 Tag safety
# ------------------------------------------------------------------------------
ensure_tag_available() {
  local tag="$1" remote="$2"
  if git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
    warn "Tag '$tag' already exists locally."
    local exists_remote=false
    if git ls-remote --exit-code --tags "$remote" "refs/tags/$tag" >/dev/null 2>&1; then
      exists_remote=true; warn "Tag '$tag' also exists on remote '$remote'."
    fi
    local release_exists="unknown"
    if command -v gh >/dev/null 2>&1; then
      if gh release view "$tag" >/dev/null 2>&1; then release_exists="yes"; else release_exists="no"; fi
    fi
    if [[ "$release_exists" == "yes" ]]; then die "A GitHub Release for '$tag' exists. Bump version instead."; fi
    if [[ "$exists_remote" == true ]]; then
      if [[ "$release_exists" == "unknown" ]]; then warn "Cannot verify release state (gh not installed)."; die "Refusing to delete remote tag without checks."; fi
      if confirm "Delete tag '$tag' from remote '$remote' and locally (no release found)?" "n"; then
        git push "$remote" ":refs/tags/$tag"; git tag -d "$tag"; info "Deleted tag '$tag' on remote and locally."
      else die "Tag '$tag' exists. Aborting."; fi
    else
      if confirm "Delete local tag '$tag' (no remote tag)?" "y"; then git tag -d "$tag"; info "Deleted local tag '$tag'."; else die "Tag exists locally. Aborting."; fi
    fi
  fi
}

# ------------------------------------------------------------------------------
# 🧩 Version IO
# ------------------------------------------------------------------------------
get_pyproject_version(){ awk -F '"' '/^\s*version\s*=\s*"/ {print $2; exit}' "$PYPROJECT"; }
get_init_version()    { awk -F '"' '/__version__\s*=\s*"/ {print $2; exit}' "$INIT_FILE"; }

set_versions() {
  local new="$1"
  "$PYTHON_CMD" - "$PYPROJECT" "$INIT_FILE" "$new" <<'PY'
import sys, re, pathlib
pyproject = pathlib.Path(sys.argv[1]); initf = pathlib.Path(sys.argv[2]); new = sys.argv[3]
pat_v = re.compile(r'(?m)^(\s*version\s*=\s*)(["\'])([^"\']+)(\2)')
txt = pyproject.read_text(encoding='utf-8'); txt, _ = pat_v.subn(lambda m: f'{m.group(1)}{m.group(2)}{new}{m.group(2)}', txt, 1); pyproject.write_text(txt, encoding='utf-8')
pat_i = re.compile(r'(?m)^(\s*__version__\s*=\s*)(["\'])([^"\']*)(\2)')
txt = initf.read_text(encoding='utf-8'); txt, _ = pat_i.subn(lambda m: f'{m.group(1)}{m.group(2)}{new}{m.group(2)}', txt, 1); initf.write_text(txt, encoding='utf-8')
PY
}

# ------------------------------------------------------------------------------
# 🔢 Version math (alpha only)
# ------------------------------------------------------------------------------
is_alpha_pep440(){ [[ "$1" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)a([0-9]+)$ ]]; }
pep440_to_tag(){ [[ "$1" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)a([0-9]+)$ ]] || return 1; echo "v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}-alpha.${BASH_REMATCH[4]}"; }
bump_alpha(){ is_alpha_pep440 "$1" || die "Not alpha: $1"; local M="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}" p="${BASH_REMATCH[3]}" a="${BASH_REMATCH[4]}"; echo "${M}.${m}.${p}a$((a+1))"; }
bump_patch_alpha(){ is_alpha_pep440 "$1" || die "Not alpha: $1"; local M="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}" p="${BASH_REMATCH[3]}"; echo "${M}.${m}.$((p+1))a1"; }
bump_minor_alpha(){ is_alpha_pep440 "$1" || die "Not alpha: $1"; local M="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}"; echo "${M}.$((m+1)).0a1"; }

# ------------------------------------------------------------------------------
# 🔐 GPG prep
# ------------------------------------------------------------------------------
prepare_gpg() {
  [[ "$GPG_PREPARE" == "true" ]] || return 0
  if command -v gpg >/dev/null 2>&1; then
    [[ -t 1 ]] && export GPG_TTY="$(tty)"
    gpg --list-secret-keys --keyid-format=long >/dev/null 2>&1 || die "No GPG secret keys found. Configure git user.signingkey."
    git config --get user.signingkey >/dev/null || {
      warn "git config user.signingkey is not set."
      local kid; kid="$(gpg --list-secret-keys --keyid-format=long | awk '/^sec/{print $2}' | sed 's|.*/||' | head -n1)"
      [[ -n "$kid" ]] && confirm "Set user.signingkey to $kid?" "y" && git config --local user.signingkey "$kid" || die "No signing key configured."
      info "Configured user.signingkey=$kid (local)."
    }
  else die "gpg not found. Install GnuPG."; fi
}

# ------------------------------------------------------------------------------
# 📝 Changelog content check
# ------------------------------------------------------------------------------
ensure_alpha_changelog_updated() {
  local version="$1" tag="$2"
  [[ -n "$ALPHA_CHANGELOG" ]] || return 0
  [[ -f "$ALPHA_CHANGELOG" ]] || die "Alpha changelog '$ALPHA_CHANGELOG' not found."

  local header_pattern="(^##\s+${version}\b)|(^##\s+${tag}\b)"
  grep -Eq "$header_pattern" "$ALPHA_CHANGELOG" || die "Changelog missing entry for ${version} (${tag})."

  local section
  section="$(awk -v ver="$version" -v tag="$tag" '
    BEGIN { found=0 }
    match($0, "^##[[:space:]]+(" ver "|" tag ")") { found=1; next }
    found && /^##[[:space:]]+/ { exit }
    found { print }
  ' "$ALPHA_CHANGELOG" | sed '/^[[:space:]]*$/d')"
  [[ -n "$section" ]] || die "Changelog entry for ${version} (${tag}) is empty."

  if ! git diff --name-only HEAD~1..HEAD | grep -qx "$ALPHA_CHANGELOG"; then
    warn "Changelog '$ALPHA_CHANGELOG' not updated in the last commit."
    confirm "Proceed anyway?" "n" || die "Aborting: changelog not updated."
  fi
}

# ------------------------------------------------------------------------------
# 💾 Commit WIP before switching (optional)
# ------------------------------------------------------------------------------
commit_wip_before_switch() {
  if git diff --quiet && git diff --cached --quiet && [[ -z "$(git ls-files --others --exclude-standard)" ]]; then
    info "No changes to commit on '$CURRENT_BRANCH'."; return 0; fi
  echo; echo "Working tree on '$CURRENT_BRANCH':"; git -c color.status=always status -sb || true; echo
  if confirm "Add ALL changes including untracked (git add -A)?" "y"; then git add -A; else git add -u; fi
  if git diff --cached --quiet; then warn "No staged changes after add; skipping commit."; else
    local msg; msg="$(ask "Commit message" "chore: WIP before switching to $RC_BRANCH")"; git commit -m "$msg"; info "Committed WIP on '$CURRENT_BRANCH'."; fi
  if confirm "Push '$CURRENT_BRANCH' to '$REMOTE' now?" "n"; then git push "$REMOTE" "$CURRENT_BRANCH"; DID_PUSH_BRANCH=true; info "Pushed branch."; fi
}

# ------------------------------------------------------------------------------
# ✅ Final confirmation before building
# ------------------------------------------------------------------------------
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
# 🚦 PREFLIGHT — required cmds
# ------------------------------------------------------------------------------
require_cmd git; require_cmd "$PYTHON_CMD"; require_cmd sed; require_cmd awk

# ------------------------------------------------------------------------------
# 1) BRANCH CHECK (first)
# ------------------------------------------------------------------------------
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not in a git repository."
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" != "$RC_BRANCH" ]]; then
  warn "You are on branch '$CURRENT_BRANCH', but workflow targets '$RC_BRANCH'."
  if confirm "Switch to '$RC_BRANCH' now?" "y"; then
    if [[ -n "$(git status --porcelain)" ]]; then
      warn "You have uncommitted changes on '$CURRENT_BRANCH'."
      if confirm "Commit these changes on '$CURRENT_BRANCH' before switching?" "y"; then commit_wip_before_switch; else warn "Proceeding without committing changes."; fi
    fi
    if git show-ref --verify --quiet "refs/heads/$RC_BRANCH"; then
      git checkout "$RC_BRANCH"
    elif git ls-remote --exit-code --heads "$REMOTE" "$RC_BRANCH" >/dev/null 2>&1; then
      git fetch "$REMOTE" "$RC_BRANCH"; git checkout "$RC_BRANCH"
    else
      die "Branch '$RC_BRANCH' does not exist locally or on '$REMOTE'."
    fi
    CURRENT_BRANCH="$RC_BRANCH"; info "Switched to '$CURRENT_BRANCH'."; git status -sb || true
  else
    confirm "Continue on '$CURRENT_BRANCH' anyway?" "n" || exit 1
  fi
fi

# Warn if uncommitted changes remain
if [[ -n "$(git status --porcelain)" ]]; then
  warn "You have uncommitted changes."; confirm "Continue (script may commit version bump)?" "y" || exit 1
fi

# Ensure key files exist
[[ -f "$PYPROJECT" ]] || die "Cannot find $PYPROJECT"
[[ -f "$INIT_FILE"  ]] || die "Cannot find $INIT_FILE"

# ------------------------------------------------------------------------------
# 2) VENV (environment only; no build yet)
# ------------------------------------------------------------------------------
VENV_DIR="${VENV_DIR:-.venv}" ; VENV_PIP_INSTALL="${VENV_PIP_INSTALL:-.}"
command -v deactivate >/dev/null 2>&1 && deactivate || true
[[ -d "$VENV_DIR" ]] || { echo "Creating Python virtual environment in $VENV_DIR …"; python3 -m venv "$VENV_DIR"; }
# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"
PYTHON_CMD="$VENV_DIR/bin/python"
"$PYTHON_CMD" -m pip install --upgrade pip
"$PYTHON_CMD" -m pip install --upgrade setuptools wheel build twine
pip install "${VENV_PIP_INSTALL:-.}"
"$PYTHON_CMD" -m pip >/dev/null 2>&1 || die "pip not available for $("$PYTHON_CMD" -V 2>/dev/null || echo python)."

# ------------------------------------------------------------------------------
# 3) VERSION SELECTION (confirm what we are releasing)
# ------------------------------------------------------------------------------
PV="$(get_pyproject_version || true)"
IV="$(get_init_version || true)"
echo "Detected versions:"; echo "  $PYPROJECT version:     ${PV:-<none>}"; echo "  $INIT_FILE __version__: ${IV:-<none>}"

if [[ -z "${PV:-}" || -z "${IV:-}" || "$PV" != "$IV" ]] || ! is_alpha_pep440 "$PV"; then
  warn "Version mismatch or not an alpha version (expected X.Y.ZaN)."
  NEWV="$(ask "Enter alpha version (e.g., 0.1.0a4)" "${PV:-0.1.0a1}")"
  is_alpha_pep440 "$NEWV" || die "Version '$NEWV' is not alpha (expected X.Y.ZaN)."
  echo "Updating versions to $NEWV ..."; set_versions "$NEWV"
  git add "$PYPROJECT" "$INIT_FILE"; git commit -m "chore(release): bump version to $NEWV [alpha]"
  PV="$NEWV"; IV="$NEWV"; info "Versions updated and committed."
else
  info "Versions are consistent and alpha: $PV"
  echo; echo "Choose a version action:"
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
    *) die "Invalid choice" ;;
  esac
  if [[ "$NEWV" != "$PV" ]]; then
    echo "Updating versions to $NEWV …"; set_versions "$NEWV"
    git add "$PYPROJECT" "$INIT_FILE"; git commit -m "chore(release): bump version to $NEWV [alpha]"
    PV="$NEWV"; IV="$NEWV"; info "Versions updated and committed."
  fi
fi

# ------------------------------------------------------------------------------
# 4) DERIVE TAG (from selected version)
# ------------------------------------------------------------------------------
TAG="$(pep440_to_tag "$PV")" || die "Cannot derive tag from $PV"
echo "Proposed tag: ${BLU}${TAG}${NC} (derived from ${PV})"

# ------------------------------------------------------------------------------
# 5) CHANGELOG CHECKS (after version is selected)
# ------------------------------------------------------------------------------
# Lightweight "recent changes" gate
if [[ -n "$ALPHA_CHANGELOG" ]]; then
  if [[ ! -f "$ALPHA_CHANGELOG" ]]; then
    warn "Changelog '$ALPHA_CHANGELOG' not found."; confirm "Proceed anyway?" "n" || die "Aborting: changelog missing."
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

# ------------------------------------------------------------------------------
# 6) FINAL VERSION CONFIRMATION (right before build)
# ------------------------------------------------------------------------------
if ! confirm_release_version "$PV" "$TAG"; then
  die "Release cancelled by user."
fi

# ------------------------------------------------------------------------------
# 7) BUILD & VALIDATE (only now)
# ------------------------------------------------------------------------------
if ! "$PYTHON_CMD" -c "import build" >/dev/null 2>&1; then
  info "Installing build tooling (build, twine)…"
  "$PYTHON_CMD" -m pip install --upgrade pip >/dev/null
  "$PYTHON_CMD" -m pip install build twine >/dev/null
fi
info "Cleaning dist/ build/ *.egg-info …"; rm -rf dist build *.egg-info
info "Building sdist & wheel …"; "$PYTHON_CMD" -m build
info "Validating metadata with twine …"; "$PYTHON_CMD" -m twine check dist/*

# ------------------------------------------------------------------------------
# Optional smoke test
# ------------------------------------------------------------------------------
if confirm "Run local smoke install from built wheel (temp venv)?" "y"; then
  WHEEL="$(ls dist/*.whl | head -n1)"; [[ -n "$WHEEL" ]] || die "No wheel found in dist/"
  MODULE_IMPORT="$(basename "$(dirname "$INIT_FILE")")"; [[ -n "$MODULE_IMPORT" ]] || die "Cannot derive module from INIT_FILE"
  SMOKE_VENV=".smoke-venv"; rm -rf "$SMOKE_VENV"; "$PYTHON_CMD" -m venv "$SMOKE_VENV"
  SMOKE_PY="$SMOKE_VENV/bin/python"; "$SMOKE_PY" -m pip install -U pip >/dev/null
  echo "Running strict smoke test (no deps)…"; "$SMOKE_PY" -m pip install --no-deps "$WHEEL" >/dev/null
  set +e
  "$SMOKE_PY" - <<PY
import sys
try:
    import ${MODULE_IMPORT}
    print("✓ Import smoke test OK (no deps)"); sys.exit(0)
except ModuleNotFoundError as e:
    print(f"Dependency missing in strict test: {e}"); sys.exit(2)
except Exception as e:
    print(f"Import failed: {e}"); sys.exit(1)
PY
  STATUS=$?; set -e
  if [[ $STATUS -eq 2 ]]; then
    echo "Retrying smoke test with dependencies …"; "$SMOKE_PY" -m pip install "$WHEEL" >/dev/null
    "$SMOKE_PY" - <<PY
import sys
try:
    import ${MODULE_IMPORT}
    print("✓ Import smoke test OK (with deps)"); sys.exit(0)
except Exception as e:
    print(f"Import failed even with deps: {e}"); sys.exit(1)
PY
  elif [[ $STATUS -ne 0 ]]; then rm -rf "$SMOKE_VENV"; die "Smoke test failed."; fi
  rm -rf "$SMOKE_VENV"; info "Smoke test completed and cleaned up."
fi

# Tag collision safety
ensure_tag_available "$TAG" "$REMOTE"

# ------------------------------------------------------------------------------
# Create & push tag
# ------------------------------------------------------------------------------
SIGN="$(ask "Sign tag with GPG? (y/n)" "$SIGN_TAG_DEFAULT")"
if [[ "$SIGN" =~ ^[Yy]$ ]]; then prepare_gpg; git tag -s "$TAG" -m "Alpha release $PV"; else git tag "$TAG" -m "Alpha release $PV"; fi
echo "Created tag: $TAG"

if confirm "Push tag '$TAG' to $REMOTE and trigger workflow?" "y"; then
  git commit --allow-empty -m "alpha release $PV"; info "Created empty commit for Alpha release $PV"
  git push "$REMOTE" "$CURRENT_BRANCH"; git push "$REMOTE" "$TAG"; DID_PUSH_TAG=true
  info "Tag pushed. Workflow will publish to TestPyPI & create pre-release."
else warn "Tag not pushed. Later: git push $REMOTE $TAG"; fi

# Cleanup prompt
if [[ "$DID_PUSH_TAG" == true ]]; then
  if confirm "Clean up local build artifacts now?" "y"; then clean_artifacts; else info "Skipping cleanup."; fi
fi

# Final status
if [[ "$DID_PUSH_TAG" == true ]]; then
  info "Release EXECUTED: tag '$TAG' pushed."
else
  echo; echo "=============================================================="
  echo "⚠️  Release NOT executed — tag not pushed."
  echo "To execute now: git push $REMOTE $TAG"
  echo "=============================================================="; echo
fi

if [[ "$DID_PUSH_TAG" != true ]]; then exit 2; fi

# Post-publish hint
PKG_NAME_PIP="picture-analytics"
echo; echo "Validate from TestPyPI with:"
echo "  pip install --index-url https://test.pypi.org/simple/ --no-deps ${PKG_NAME_PIP}==${PV}"
echo; info "Alpha release flow complete."
