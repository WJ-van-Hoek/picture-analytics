step_branch_and_prechecks() {
  require_cmd git; require_cmd "$PYTHON_CMD"; require_cmd sed; require_cmd awk
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not in a git repository."

  CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  export CURRENT_BRANCH

  if [[ "$CURRENT_BRANCH" != "$RC_BRANCH" ]]; then
    warn "You are on branch '$CURRENT_BRANCH', but workflow targets '$RC_BRANCH'."
    if confirm "Switch to '$RC_BRANCH' now?" "y"; then
      # Offer WIP commit first
      if [[ -n "$(git status --porcelain)" ]]; then
        warn "You have uncommitted changes on '$CURRENT_BRANCH'."
        if confirm "Commit these changes on '$CURRENT_BRANCH' before switching?" "y"; then
          _commit_wip_before_switch
        else
          warn "Proceeding without committing changes."
        fi
      fi
      if git show-ref --verify --quiet "refs/heads/$RC_BRANCH"; then
        git checkout "$RC_BRANCH"
      elif git ls-remote --exit-code --heads "$REMOTE" "$RC_BRANCH" >/dev/null 2>&1; then
        git fetch "$REMOTE" "$RC_BRANCH"; git checkout "$RC_BRANCH"
      else
        die "Branch '$RC_BRANCH' does not exist locally or on '$REMOTE'."
      fi
      CURRENT_BRANCH="$RC_BRANCH"; export CURRENT_BRANCH
      info "Switched to '$CURRENT_BRANCH'."; git status -sb || true
    else
      confirm "Continue on '$CURRENT_BRANCH' anyway?" "n" || exit 1
    fi
  fi

  # Warn if uncommitted changes remain
  if [[ -n "$(git status --porcelain)" ]]; then
    warn "You have uncommitted changes."
    confirm "Continue (script may commit version bump)?" "y" || exit 1
  fi

  [[ -f "$PYPROJECT" ]] || die "Cannot find $PYPROJECT"
  [[ -f "$INIT_FILE"  ]] || die "Cannot find $INIT_FILE"
}

_commit_wip_before_switch() {
  if git diff --quiet && git diff --cached --quiet && [[ -z "$(git ls-files --others --exclude-standard)" ]]; then
    info "No changes to commit on '$CURRENT_BRANCH'."; return 0; fi
  echo; echo "Working tree on '$CURRENT_BRANCH':"; git -c color.status=always status -sb || true; echo
  if confirm "Add ALL changes including untracked (git add -A)?" "y"; then git add -A; else git add -u; fi
  if git diff --cached --quiet; then warn "No staged changes after add; skipping commit."; else
    local msg; msg="$(ask "Commit message" "chore: WIP before switching to $RC_BRANCH")"; git commit -m "$msg"; info "Committed WIP on '$CURRENT_BRANCH'."; fi
  if confirm "Push '$CURRENT_BRANCH' to '$REMOTE' now?" "n"; then git push "$REMOTE" "$CURRENT_BRANCH"; info "Pushed branch."; fi
}

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
