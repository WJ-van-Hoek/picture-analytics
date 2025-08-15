#!/usr/bin/env bash
set -euo pipefail

# Resolve repo root (…/bin/alpha-release/main-tool.sh -> repo root)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Load config first
source "config/alpha.sh"

# Load libs
source "lib/common.sh"
source "lib/git.sh"
source "lib/version.sh"
source "lib/changelog.sh"
source "lib/venv.sh"
source "lib/gpg.sh"
source "lib/build_and_validate.sh"
source "lib/tag_and_push.sh"
source "lib/finalize.sh"

# ---- Execution order (keep this as the source of truth) ----
step_branch_and_prechecks          # 1) RC branch check (+ optional WIP commit), key files
step_env_prepare                   # 2) Venv/tooling only (no build)
step_version_select                # 3) Choose/confirm alpha version, commit bump if changed
step_tag_and_changelog_prechecks   # 4) Derive TAG from PV, then changelog gates
confirm_release_version "$PV" "$TAG" || die "Release cancelled by user."  # 5) Final confirm
step_build_and_validate            # 6) Build + twine check (+ optional smoke test)
step_tag_and_push                  # 7) Tag safety, create (optional GPG), push
step_finalize                      # 8) Cleanup + final status
