# bash/lib/changelog.sh
# ------------------------------------------------------------------------------
# Changelog gates for alpha releases
#   • gate_changelog_top_block_matches_version(PV, TAG)
#       -> Ensures the FIRST block between '---' separators corresponds to PV/TAG
#          and has content. This enforces "newest at the top" discipline.
#   • ensure_alpha_changelog_updated(PV, TAG)
#       -> Ensures a non-empty entry for PV/TAG exists (anywhere) AND the file
#          was part of the last commit.
#   • step_tag_and_changelog_prechecks()
#       -> Derives TAG from PV, runs the top-block gate, then the strict check.
# ------------------------------------------------------------------------------

# Extract the FIRST block delimited by lines that are exactly '---' (ignoring
# surrounding whitespace). Returns the block contents *without* the '---' lines.
_extract_first_block_between_dashes() {
  awk '
    BEGIN { sep_count=0; in_block=0 }
    /^[[:space:]]*---[[:space:]]*$/ {
      sep_count++
      if (sep_count==1) { in_block=1; next }   # start of first block
      if (sep_count==2) { exit }               # end of first block
    }
    in_block { print }
  ' "$ALPHA_CHANGELOG"
}

# Normalize: trim trailing spaces, remove leading spaces, drop blank lines
_normalize_lines() { sed -e 's/[[:space:]]\+$//' -e 's/^[[:space:]]\+//' -e '/^$/d'; }

# Given a header line, extract a version token in any accepted form:
#  - v?X.Y.ZaN
#  - v?X.Y.Z-alpha.N
_extract_version_token_from_header() {
  grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+(-alpha\.[0-9]+|a[0-9]+)'
}

# Build all acceptable header forms for the given PV/TAG:
#  - $PV              e.g., 0.1.1a5
#  - v$PV             e.g., v0.1.1a5
#  - $TAG             e.g., v0.1.1-alpha.5
#  - ${TAG#v}         e.g., 0.1.1-alpha.5
_build_accept_list() {
  local pv="$1" tag="$2"
  printf '%s\n' \
    "$pv" \
    "v$pv" \
    "$tag" \
    "${tag#v}"
}

# ------------------------------------------------------------------------------
# Gate 1: FIRST block must be the version we are releasing (and non-empty).
# ------------------------------------------------------------------------------
gate_changelog_top_block_matches_version() {
  local version="$1"  # e.g., 0.1.1a5
  local tag="$2"      # e.g., v0.1.1-alpha.5

  [[ -n "$ALPHA_CHANGELOG" ]] || die "ALPHA_CHANGELOG is empty; set it in bash/config/alpha.sh."
  [[ -f "$ALPHA_CHANGELOG" ]] || die "Changelog '$ALPHA_CHANGELOG' not found."

  # Get first block between '---'
  local block
  block="$(_extract_first_block_between_dashes)"
  [[ -n "$block" ]] || die "Changelog '$ALPHA_CHANGELOG' has no first entry block delimited by '---'."

  # The first non-empty header line in the block must start with '##'
  local header
  header="$(printf '%s\n' "$block" | sed -n '/^##[[:space:]]\+/{s///;p;q}')"
  [[ -n "$header" ]] || die "Top changelog block lacks a '## <version>' header."

  # Extract version-like token from header
  local header_ver
  header_ver="$(printf '%s\n' "$header" | _extract_version_token_from_header || true)"
  [[ -n "$header_ver" ]] || die "Could not parse a version token from top block header: '## $header'."

  # Acceptable forms for this release
  local accept
  accept="$(_build_accept_list "$version" "$tag")"

  # Must match one of the acceptable tokens
  local ok=false
  while IFS= read -r tok; do
    if [[ "$header_ver" == "$tok" ]]; then ok=true; break; fi
  done <<<"$accept"

  if [[ "$ok" != true ]]; then
    die "Top changelog block header version '$header_ver' does not match this release ($version / $tag). Update the FIRST block to the new version."
  fi

  # Ensure the block contains some content lines beyond the header (non-empty)
  local body
  body="$(printf '%s\n' "$block" | sed '1{/^##[[:space:]]\+/!q};1d' | _normalize_lines)"
  [[ -n "$body" ]] || die "Top changelog block for $version ($tag) is empty. Add release notes."

  info "Top changelog block matches $version ($tag) and has content."
}

# ------------------------------------------------------------------------------
# Gate 2: file must contain a non-empty section for PV/TAG and be in HEAD commit.
# ------------------------------------------------------------------------------
ensure_alpha_changelog_updated() {
  local version="$1"  # e.g., 0.1.1a5
  local tag="$2"      # e.g., v0.1.1-alpha.5

  [[ -n "$ALPHA_CHANGELOG" ]] || die "ALPHA_CHANGELOG is empty; set it in bash/config/alpha.sh."
  [[ -f "$ALPHA_CHANGELOG" ]] || die "Alpha changelog '$ALPHA_CHANGELOG' not found."

  local header_pattern="(^##[[:space:]]+${version}\\b)|(^##[[:space:]]+${tag}\\b)"
  if ! grep -Eq "$header_pattern" "$ALPHA_CHANGELOG"; then
    die "Alpha changelog '$ALPHA_CHANGELOG' does not contain a header for ${version} (${tag})."
  fi

  local section
  section="$(awk -v ver="$version" -v tag="$tag" '
    BEGIN { found=0 }
    match($0, "^##[[:space:]]+(" ver "|" tag ")") { found=1; next }
    found && /^##[[:space:]]+/ { exit }
    found { print }
  ' "$ALPHA_CHANGELOG" | sed '/^[[:space:]]*$/d')"

  [[ -n "$section" ]] || die "Changelog entry for ${version} (${tag}) is empty. Add release notes under its header."

  # Mandatory: ensure changelog file was part of the most recent commit
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    if ! git diff --name-only HEAD~1..HEAD -- "$ALPHA_CHANGELOG" | grep -qx "$ALPHA_CHANGELOG"; then
      die "Changelog '$ALPHA_CHANGELOG' was not included in the last commit. Commit the changelog update for this release."
    fi
  fi

  info "Changelog contains a non-empty entry for ${version} (${tag}) and was in the last commit."
}

# ------------------------------------------------------------------------------
# Step: derive TAG and run both gates
# ------------------------------------------------------------------------------
step_tag_and_changelog_prechecks() {
  TAG="$(pep440_to_tag "$PV")" || die "Cannot derive tag from $PV"
  echo "Proposed tag: ${BLU}${TAG}${NC} (derived from ${PV})"

  export TAG
  # 1) FIRST block between '---' must match this release and have content
  gate_changelog_top_block_matches_version "$PV" "$TAG"
  # 2) Structural/commit enforcement (exists anywhere, non-empty, in last commit)
  ensure_alpha_changelog_updated "$PV" "$TAG"
}
