recent_changes_gate() {
  [[ -n "$ALPHA_CHANGELOG" ]] || return 0
  if [[ ! -f "$ALPHA_CHANGELOG" ]]; then
    warn "Changelog '$ALPHA_CHANGELOG' not found."
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
}

ensure_alpha_changelog_updated() {
  local version="$1" tag="$2"
  [[ -n "$ALPHA_CHANGELOG" ]] || return 0
  [[ -f "$ALPHA_CHANGELOG" ]] || die "Alpha changelog '$ALPHA_CHANGELOG' not found."

  local header_pattern="(^##\\s+${version}\\b)|(^##\\s+${tag}\\b)"
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

step_tag_and_changelog_prechecks() {
  TAG="$(pep440_to_tag "$PV")" || die "Cannot derive tag from $PV"
  echo "Proposed tag: ${BLU}${TAG}${NC} (derived from ${PV})"
  export TAG
  recent_changes_gate
  ensure_alpha_changelog_updated "$PV" "$TAG"
}
