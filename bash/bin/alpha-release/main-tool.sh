#!/usr/bin/env bash
# ==============================================================================
#  Alpha Release Orchestrator — main-tool.sh (extensively documented)
# ==============================================================================
# PURPOSE
#   This script is the *thin orchestrator* for your alpha release flow. It wires
#   together the individual step libraries under bash/lib/ and runs them in the
#   exact sequence you designed:
#
#     1) Branch check (with optional WIP commit)                        [git.sh]
#     2) Version selection / confirmation                               [version.sh]
#     3) Derive tag + changelog gates                                   [changelog.sh]
#     4) Final "Proceed with this version?"                             [gpg.sh]
#     5) Environment prep (venv & tooling)                              [venv.sh]
#     6) Build & validate (sdist+wheel, twine check, optional smoke)    [build_and_validate.sh]
#     7) Tag safety + create tag (+ optional GPG) + push                [tag_and_push.sh]
#     8) Finalize (optional cleanup, status, post‑publish hints)        [finalize.sh]
#
#   The goal: keep *all business logic* in small, focused libs. This file only
#   resolves paths, loads config/libs, and invokes step_* functions in order.
#
# USAGE
#   $ bash/bin/alpha-release/main-tool.sh
#   (from anywhere inside the repo; the script resolves the repository root)
#
# EXPECTED LAYOUT
#   <repo>/
#     ├─ bash/
#     │   ├─ bin/alpha-release/main-tool.sh          # this file
#     │   ├─ config/alpha.sh                         # configuration & env defaults
#     │   └─ lib/                                    # step libraries
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
# KEY ENV VARS (override via environment or in config/alpha.sh)
#   PYPROJECT, INIT_FILE          – paths to project version sources
#   RC_BRANCH                     – required source branch for alpha releases
#   REMOTE                        – git remote for pushing branch & tag
#   SIGN_TAG_DEFAULT              – default answer for GPG signing prompt (y/n)
#   ALPHA_CHANGELOG               – path to your alpha changelog file
#   VENV_DIR, VENV_PIP_INSTALL    – venv location & what to install into it
#   ENFORCE_MONOTONIC_VERSION     – reserved for future guard logic (true/false)
#   GPG_PREPARE                   – preflight checks before signed tags
#   PYTHON_CMD                    – preferred Python (auto‑set by venv.sh)
#
# EXIT CODES
#   0 – success; tag pushed and workflow triggered
#   2 – non‑fatal early exit (e.g., user declined, tag not pushed)
#   >0 – fatal error (missing files, failed checks, build errors)
#
# NOTES
#   • This script uses bash "strict mode" (set -euo pipefail) to fail fast.
#   • *Do not* put business logic here; keep it in libs to retain readability.
#   • All prompts and heavy lifting occur in the step_* functions.
# ==============================================================================
set -euo pipefail

# ----------------------------------------------------------------------------
# Resolve repository root – works both inside and outside Git clones.
# 1) Try Git's toplevel detection.
# 2) Fallback to path math relative to this script: ../../.. from bin/alpha-release/.
# ----------------------------------------------------------------------------
if REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  :  # success; REPO_ROOT set by git
else
  # main-tool.sh is at <repo>/bash/bin/alpha-release/main-tool.sh -> repo root is ../../..
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fi
cd "$REPO_ROOT"

# ----------------------------------------------------------------------------
# Load configuration and libraries.
# We deliberately check each file's presence for clearer diagnostics when paths
# drift (e.g., when running from subdirectories or CI).
# ----------------------------------------------------------------------------
req() { [[ -f "$1" ]] || { echo "✖ missing: $1" >&2; exit 2; }; }

# Config (defines defaults and honors environment overrides)
req "bash/config/alpha.sh";                      source "bash/config/alpha.sh"

# Core helpers: colors, prompts, die/info/warn, require_cmd, clean_artifacts
req "bash/lib/common.sh";                        source "bash/lib/common.sh"

# Git/branch orchestration: step_branch_and_prechecks, _commit_wip_before_switch,
#                           ensure_tag_available
req "bash/lib/git.sh";                           source "bash/lib/git.sh"

# Version I/O and selection: get_pyproject_version, get_init_version,
#                            set_versions, is_alpha_pep440, pep440_to_tag,
#                            bump_* helpers, step_version_select (sets PV/IV)
req "bash/lib/version.sh";                       source "bash/lib/version.sh"

# Changelog logic: recent_changes_gate (light), ensure_alpha_changelog_updated
#                  (strict), step_tag_and_changelog_prechecks (sets TAG)
req "bash/lib/changelog.sh";                     source "bash/lib/changelog.sh"

# Environment prep: step_env_prepare (creates/activates venv, installs tooling,
# ensures PYTHON_CMD points into the venv)
req "bash/lib/venv.sh";                          source "bash/lib/venv.sh"

# GPG/signing helpers and the final confirmation UI (confirm_release_version)
req "bash/lib/gpg.sh";                           source "bash/lib/gpg.sh"

# Build & validate: step_build_and_validate (build, twine check, smoke test)
req "bash/lib/build_and_validate.sh";            source "bash/lib/build_and_validate.sh"

# Tag & push: step_tag_and_push (safety checks, create tag, sign optionally, push)
req "bash/lib/tag_and_push.sh";                  source "bash/lib/tag_and_push.sh"

# Finalization: step_finalize (cleanup prompt, final status, post‑publish hints)
req "bash/lib/finalize.sh";                      source "bash/lib/finalize.sh"

# ----------------------------------------------------------------------------
# Execution order – this is the *single source of truth* for the flow.
# Keep the steps minimal and readable here; implement behavior inside libs.
# ----------------------------------------------------------------------------

# 1) Ensure we're on the correct RC branch, offer to commit WIP before switching,
#    verify required files exist.
step_branch_and_prechecks

# 2) Choose/confirm the exact alpha version to release (sets PV, optionally
#    commits a version bump if you changed it). No build occurs yet.
step_version_select

# 3) Derive the Git tag from PV (TAG), then run changelog gates (light touch
#    first; strict content/version check second). Both checks operate on PV/TAG
#    so you validate *exactly* what you'll release.
step_tag_and_changelog_prechecks

# 4) Final pre-build confirmation. Shows Version/Tag/Branch/Changelog and asks
#    for a yes/no before any build work or side effects.
confirm_release_version "$PV" "$TAG" || die "Release cancelled by user."

# 5) Prepare the build environment (create/activate venv, install pip tools and
#    your package per VENV_PIP_INSTALL). This keeps builds reproducible and
#    isolated from the system Python.
step_env_prepare

# 6) Build artifacts (sdist + wheel), run twine check, optionally perform a
#    smoke import test in a throwaway venv to catch packaging issues early.
step_build_and_validate

# 7) Tag safety, create tag (optionally GPG-signed), push branch & tag to REMOTE
#    to trigger your CI release workflow.
step_tag_and_push

# 8) Final status/cleanup. Optionally remove build artifacts; emit post-publish
#    hints (e.g., how to install from TestPyPI).
step_finalize
