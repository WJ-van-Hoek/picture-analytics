#!/usr/bin/env bash
# ============================================================================
#  Release Orchestrator — general + alpha-aware (single entrypoint)
# ============================================================================
# PURPOSE
#   A thin, mode-aware orchestrator for your release flow. It wires together
#   small step libraries under bash/lib/ and runs them in a clear, linear order.
#   Unlike the previous alpha-only tool, this script supports multiple release
#   modes and contains an explicit branch where the alpha-specific steps are
#   orchestrated.
#
#   Supported modes (via --mode or RELEASE_MODE):
#     • alpha   – pre-release / canary channel (alpha-only checks enabled)
#     • beta    – pre-release (stabilization)
#     • rc      – release candidate
#     • stable  – general availability
#
#   All business logic still lives in libs; this file only resolves paths, loads
#   config/libs, chooses the mode, and invokes step_* functions in order. Where
#   alpha-specific functions exist (from your current libs), we call them only
#   when MODE=alpha; otherwise we prefer generic counterparts if present.
#
# USAGE
#   $ bash/bin/release-orchestrator.sh --mode <alpha|beta|rc|stable>
#   (run from anywhere in the repo; the script resolves the repository root)
#
# EXPECTED LAYOUT (unchanged)
#   <repo>/
#     ├─ bash/
#     │   ├─ bin/release-orchestrator.sh            # this file
#     │   ├─ config/release.sh                      # general config & defaults (NEW)
#     │   ├─ config/alpha.sh                        # alpha-specific defaults (kept)
#     │   └─ lib/
#     │       ├─ common.sh
#     │       ├─ git.sh
#     │       ├─ version.sh
#     │       ├─ changelog.sh
#     │       ├─ venv.sh
#     │       ├─ gpg.sh
#     │       ├─ build_and_validate.sh
#     │       ├─ tag_and_push.sh
#     │       └─ finalize.sh
#
# KEY ENV VARS (generalized)
#   RELEASE_MODE                – one of alpha|beta|rc|stable (default: stable)
#   RELEASE_BRANCH              – required branch for this mode (falls back to RC_BRANCH when MODE=alpha for backcompat)
#   REMOTE                      – git remote for pushing branch & tag
#   SIGN_TAG_DEFAULT            – default answer for GPG signing prompt (y/n)
#   CHANGELOG_FILE              – path to the changelog for this mode
#   ALPHA_CHANGELOG             – legacy variable; used when MODE=alpha and set
#   VENV_DIR, VENV_PIP_INSTALL  – venv location & what to install into it
#   PYPROJECT, INIT_FILE        – paths to project version sources
#   PYTHON_CMD                  – preferred Python (auto-set by venv.sh)
#
# EXIT CODES
#   0 – success; tag pushed and workflow triggered
#   2 – non-fatal early exit (e.g., user declined, tag not pushed)
#   >0 – fatal error (missing files, failed checks, build errors)
#
# NOTES
#   • Bash strict mode is enabled. Fail fast; keep logic in libs.
#   • Generic function names are tried first; alpha-legacy fallbacks are used
#     when MODE=alpha to preserve your current library surface.
# ============================================================================
set -euo pipefail

# ---------------------------------------------
# Helpers
# ---------------------------------------------
fn_exists() { declare -F "$1" >/dev/null 2>&1; }
req() { [[ -f "$1" ]] || { echo "✖ missing: $1" >&2; exit 2; }; }
info() { echo "[info] $*"; }
warn() { echo "[warn] $*" >&2; }
die()  { echo "✖ $*" >&2; exit 1; }

# ---------------------------------------------
# Parse args
# ---------------------------------------------
RELEASE_MODE="${RELEASE_MODE:-}"
while [[ ${1:-} ]]; do
  case "$1" in
    --mode)
      RELEASE_MODE="${2:-}"; shift 2;;
    --mode=*)
      RELEASE_MODE="${1#*=}"; shift;;
    -h|--help)
      cat <<EOF
Usage: $0 [--mode alpha|beta|rc|stable]
EOF
      exit 0;;
    *)
      warn "Unknown argument: $1"; shift;;
  esac
done

# Default mode
RELEASE_MODE="${RELEASE_MODE:-stable}"
case "$RELEASE_MODE" in
  alpha|beta|rc|stable) :;;
  *) die "Invalid --mode '$RELEASE_MODE' (expected alpha|beta|rc|stable)";;
esac

# ---------------------------------------------
# Resolve repository root
# ---------------------------------------------
if REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then :; else
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fi
cd "$REPO_ROOT"

# ---------------------------------------------
# Load configuration and libraries
# ---------------------------------------------
# General config first (NEW). If absent, fall back to legacy alpha config to avoid breakage.
if [[ -f bash/config/release.sh ]]; then
  source bash/config/release.sh
else
  warn "bash/config/release.sh not found; falling back to alpha config only"
fi

# Legacy alpha config remains available for MODE=alpha
if [[ "$RELEASE_MODE" == "alpha" ]]; then
  if [[ -f bash/config/alpha.sh ]]; then
    source bash/config/alpha.sh
  else
    warn "alpha mode selected but bash/config/alpha.sh not found"
  fi
fi

# Core libs (required)
req "bash/lib/common.sh";               source "bash/lib/common.sh"
req "bash/lib/git.sh";                  source "bash/lib/git.sh"
req "bash/lib/version.sh";              source "bash/lib/version.sh"
req "bash/lib/venv.sh";                 source "bash/lib/venv.sh"
req "bash/lib/gpg.sh";                  source "bash/lib/gpg.sh"
req "bash/lib/build_and_validate.sh";   source "bash/lib/build_and_validate.sh"
req "bash/lib/tag_and_push.sh";         source "bash/lib/tag_and_push.sh"
req "bash/lib/finalize.sh";             source "bash/lib/finalize.sh"

# Changelog lib (required but tolerant)
if [[ -f bash/lib/changelog.sh ]]; then
  source bash/lib/changelog.sh
else
  warn "bash/lib/changelog.sh missing; changelog gates will be skipped"
fi

# ---------------------------------------------
# Derived / legacy compatibility
# ---------------------------------------------
MODE_UPPER=$(printf %s "$RELEASE_MODE" | tr '[:lower:]' '[:upper:]')

# Branch rule: prefer RELEASE_BRANCH; alpha falls back to RC_BRANCH if set
: "${RELEASE_BRANCH:=${RELEASE_BRANCH:-${RC_BRANCH:-}}}"

# Changelog path: prefer CHANGELOG_FILE; alpha respects ALPHA_CHANGELOG if set
if [[ "${CHANGELOG_FILE:-}" == "" && "$RELEASE_MODE" == "alpha" && -n "${ALPHA_CHANGELOG:-}" ]]; then
  CHANGELOG_FILE="$ALPHA_CHANGELOG"
fi

# Export for libs that rely on these names
export RELEASE_MODE CHANGELOG_FILE RELEASE_BRANCH

# ---------------------------------------------
# Tag derivation wrappers (prefer generic, fall back to alpha-specific)
# ---------------------------------------------
# Expect libs to expose a generic pep440_to_tag; if not, keep simple default.
peptag() {
  local pv="$1"; local mode="$2"
  if fn_exists pep440_to_tag; then
    # Prefer a 2-arg variant if provided, else call with PV only
    if pep440_to_tag "--help" 2>/dev/null | grep -qi mode; then
      pep440_to_tag "$pv" "$mode"
    else
      pep440_to_tag "$pv"
    fi
  else
    # Fallback: turn 1.2.3[-pre] into v1.2.3[-pre]
    printf 'v%s' "$pv"
  fi
}

validate_mode_version() {
  local pv="$1"; local mode="$2"
  case "$mode" in
    alpha)
      if fn_exists is_alpha_pep440; then
        is_alpha_pep440 "$pv" || die "Version '$pv' is not a valid alpha per PEP 440"
      fi
      ;;
    *) :;;
  esac
}

# ---------------------------------------------
# Changelog gate wrappers (generic-first, alpha-fallback)
# ---------------------------------------------
changelog_light_gate() {
  if fn_exists recent_changes_gate; then
    recent_changes_gate "$CHANGELOG_FILE" "$PV" "$RELEASE_MODE"
  fi
}

changelog_strict_gate() {
  if fn_exists ensure_changelog_updated; then
    ensure_changelog_updated "$CHANGELOG_FILE" "$PV" "$RELEASE_MODE"
  elif [[ "$RELEASE_MODE" == "alpha" ]] && fn_exists ensure_alpha_changelog_updated; then
    # Backcompat with legacy alpha function name
    ensure_alpha_changelog_updated "$CHANGELOG_FILE" "$PV"
  else
    warn "No strict changelog gate available; skipping"
  fi
}

# ---------------------------------------------
# Execution order — single source of truth for the flow
# ---------------------------------------------

# 1) Ensure we are on the correct branch, offer to commit WIP before switching,
#    verify required files exist.
step_branch_and_prechecks "${RELEASE_BRANCH:-}" "${RELEASE_MODE}" || die "Branch prechecks failed"

# 2) Choose/confirm the exact version to release (sets PV, optionally commits a
#    version bump if you changed it). No build occurs yet.
step_version_select "$RELEASE_MODE"
: "${PV:?step_version_select must set PV}"

# Validate the version against the mode (alpha-only rule today).
validate_mode_version "$PV" "$RELEASE_MODE"

# 3) Derive the Git tag from PV (TAG), then run changelog gates (light then strict)
TAG="$(peptag "$PV" "$RELEASE_MODE")"
export TAG

# Light changelog gate (non-fatal hints)
changelog_light_gate || true

# Strict changelog/content gate (fatal if it enforces correctness)
changelog_strict_gate

# 4) Final pre-build confirmation: show Version/Tag/Branch/Mode/Changelog and ask
#    for a yes/no before any build work or side effects.
confirm_release_version "$PV" "$TAG" "$RELEASE_MODE" "$RELEASE_BRANCH" "$CHANGELOG_FILE" \
  || die "Release cancelled by user."

# 5) Prepare the build environment (create/activate venv, install tooling, ensure PYTHON_CMD)
step_env_prepare "$RELEASE_MODE"

# 6) Build artifacts (sdist + wheel), run twine check, optional smoke import test
step_build_and_validate "$RELEASE_MODE"

# 7) Tag safety + create tag (+ optional GPG) + push branch & tag to REMOTE
step_tag_and_push "$RELEASE_MODE"

# 8) Final status/cleanup. Optionally remove build artifacts; emit post‑publish hints.
step_finalize "$RELEASE_MODE" "$PV" "$TAG" "$RELEASE_BRANCH"

# ---------------------------------------------
# Alpha-specific orchestration note
# ---------------------------------------------
# When --mode alpha, the above flow automatically enables alpha-only behavior via
# the wrappers:
#   • Version validation uses is_alpha_pep440 if available.
#   • Changelog strict gate falls back to ensure_alpha_changelog_updated.
#   • Branch and step_* functions receive the mode, allowing libs to enforce
#     alpha-specific policies (e.g., required branch, CI lanes, publishing to
#     TestPyPI, etc.).
#
# Non-alpha modes should implement their differences inside the libs based on
# the mode argument (e.g., CHANGELOG sections, branch naming, signing rules).
# This keeps the orchestrator generic and future-proof.
# ============================================================================
