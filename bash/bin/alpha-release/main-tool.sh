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
req() { [[ -f "$1" ]] || { echo "✖ missing: $1" >&2; exit 2; }; }

req "bash/config/alpha.sh";                      source "bash/config/alpha.sh"

req "bash/lib/common.sh";                        source "bash/lib/common.sh"
req "bash/lib/git.sh";                           source "bash/lib/git.sh"
req "bash/lib/version.sh";                       source "bash/lib/version.sh"
req "bash/lib/changelog.sh";                     source "bash/lib/changelog.sh"
req "bash/lib/venv.sh";                          source "bash/lib/venv.sh"
req "bash/lib/gpg.sh";                           source "bash/lib/gpg.sh"
req "bash/lib/build_and_validate.sh";            source "bash/lib/build_and_validate.sh"
req "bash/lib/tag_and_push.sh";                  source "bash/lib/tag_and_push.sh"
req "bash/lib/finalize.sh";                      source "bash/lib/finalize.sh"

# --- Execution order (unchanged) ---
step_branch_and_prechecks          # 1) RC branch check (+ optional WIP commit), key files
step_version_select                # 2) Choose/confirm alpha version, commit bump if changed
step_tag_and_changelog_prechecks   # 3) Derive TAG from PV, then changelog gates
confirm_release_version "$PV" "$TAG" || die ...
step_env_prepare
step_build_and_validate            # 6) Build + twine check (+ optional smoke test)
step_tag_and_push                  # 7) Tag safety, create (optional GPG), push
step_finalize                      # 8) Cleanup + final status
