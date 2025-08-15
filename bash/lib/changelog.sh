# Require that the alpha changelog exists AND has been updated for this release.
# "Updated" means: either unstaged changes, staged changes, or it was part of
# the most recent commit. If none of those, we abort (no override prompt).
recent_changes_gate() {
  [[ -n "$ALPHA_CHANGELOG" ]] || die "ALPHA_CHANGELOG path is empty; set it in bash/config/alpha.sh."
  [[ -f "$ALPHA_CHANGELOG" ]] || die "Changelog '$ALPHA_CHANGELOG' not found. It is mandatory for alpha releases."

  local changed=false

  # Unstaged changes?
  if git diff --name-only -- "$ALPHA_CHANGELOG" | grep -qx "$ALPHA_CHANGELOG"; then
    changed=true
  fi

  # Staged (index) changes?
  if git diff --name-only --cached -- "$ALPHA_CHANGELOG" | grep -qx "$ALPHA_CHANGELOG"; then
    changed=true
  fi

  # Part of the most recent commit?
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    if git diff --name-only HEAD~1..HEAD -- "$ALPHA_CHANGELOG" | grep -qx "$ALPHA_CHANGELOG"; then
      changed=true
    fi
  fi

  if [[ "$changed" != true ]]; then
    die "Changelog '$ALPHA_CHANGELOG' shows no recent updates. Update it for this alpha release and commit the change."
  fi

  info "Changelog '$ALPHA_CHANGELOG' has recent updates."
}

# Ensure the changelog contains a non-empty section for the exact version/tag.
# Also enforce that the changelog was included in the latest commit (mandatory).
ensure_alpha_changelog_updated() {
  local version="$1"  # e.g., 0.1.1a4
  local tag="$2"      # e.g., v0.1.1-alpha.4

  [[ -n "$ALPHA_CHANGELOG" ]] || die "ALPHA_CHANGELOG path is empty; set it in bash/config/alpha.sh."
  [[ -f "$ALPHA_CHANGELOG" ]] || die "Alpha changelog '$ALPHA_CHANGELOG' not found."

  # Require a section header for either PEP 440 version or the tag
  local header_pattern="(^##[[:space:]]+${version}\\b)|(^##[[:space:]]+${tag}\\b)"
  if ! grep -Eq "$header_pattern" "$ALPHA_CHANGELOG"; then
    die "Alpha changelog '$ALPHA_CHANGELOG' does not contain a header for ${version} (${tag})."
  fi

  # Extract section body until the next '##' header and verify it's not empty
  local section
  section="$(awk -v ver="$version" -v tag="$tag" '
    BEGIN { found=0 }
    match($0, "^##[[:space:]]+(" ver "|" tag ")") { found=1; next }
    found && /^##[[:space:]]+/ { exit }
    found { print }
  ' "$ALPHA_CHANGELOG" | sed '/^[[:space:]]*$/d')"

  [[ -n "$section" ]] || die "Changelog entry for ${version} (${tag}) is empty. Add release notes under its header."

  # Mandatory: ensure the changelog file was part of the most recent commit
  if ! git diff --name-only HEAD~1..HEAD -- "$ALPHA_CHANGELOG" | grep -qx "$ALPHA_CHANGELOG"; then
    die "Changelog '$ALPHA_CHANGELOG' was not included in the last commit. Please commit the changelog update for this release."
  fi

  info "Changelog contains a non-empty entry for ${version} (${tag}) and was in the last commit."
}

# Derive TAG and run both strict gates.
step_tag_and_changelog_prechecks() {
  TAG="$(pep440_to_tag "$PV")" || die "Cannot derive tag from $PV"
  echo "Proposed tag: ${BLU}${TAG}${NC} (derived from ${PV})"

  export TAG
  recent_changes_gate               # MUST be updated (no override)
  ensure_alpha_changelog_updated "$PV" "$TAG"   # MUST have content + be in last commit
}
