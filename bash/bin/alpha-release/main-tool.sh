#!/usr/bin/env bash
set -euo pipefail

# --- Resolve repo root (prefer Git; fallback to path math) ---
if REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  # main-tool.sh is at <repo>/bash/bin/alpha-release/main-tool.sh -> repo root is ../../..
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fi
cd "$REPO_ROOT"

# --- Load config & libs from bash/ ---
source "bash/config/alpha.sh"

source "bash/lib/common.sh"
source "bash/lib/git.sh"
source "bash/lib/version.sh"
source "bash/lib/changelog.sh"
source "bash/lib/venv.sh"
source "bash/lib/gpg.sh"
source "bash/lib/build_and_validate.sh"
source "bash/lib/tag_and_push.sh"
source "bash/lib/finalize.sh"

# --- Execution order ---
step_branch_and_prechecks          # 1) RC branch check (+ optional WIP commit), key files
step_env_prepare                   # 2) Venv/tooling only (no build)
step_version_select                # 3) Choose/confirm alpha version, commit bump if changed
step_tag_and_changelog_prechecks   # 4) Derive TAG from PV, then changelog gates
confirm_release_version "$PV" "$TAG" || die "Release cancelled by user."  # 5) Final confirm
step_build_and_validate            # 6) Build + twine check (+ optional smoke test)
step_tag_and_push                  # 7) Tag safety, create (optional GPG), push
step_finalize                      # 8) Cleanup + final status
