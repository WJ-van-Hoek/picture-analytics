# ------------------------------------------------------------------------------
# Changelog gates for alpha releases (strict header style)
#   Header MUST be:  "## vX.Y.ZaN — YYYY-MM-DD"
#   Only the FIRST block between '---' separators is considered "current".
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

# Gate 1: FIRST block must have header: "## vPV — YYYY-MM-DD" and non-empty body
gate_changelog_top_block_matches_version() {
  local pv="$1"   # e.g., 0.1.1a5

  [[ -n "$ALPHA_CHANGELOG" ]] || die "ALPHA_CHANGELOG is empty; set it in bash/config/alpha.sh."
  [[ -f "$ALPHA_CHANGELOG" ]] || die "Changelog '$ALPHA_CHANGELOG' not found."

  local block
  block="$(_extract_first_block_between_dashes)"
  [[ -n "$block" ]] || die "Changelog '$ALPHA_CHANGELOG' has no first entry block delimited by '---'."

  # Strict header regex:
  #   ^##\s+v<digits>.<digits>.<digits>a<digits>\s+—\s+YYYY-MM-DD$
  # NOTE: The dash is a literal em dash (U+2014). To accept hyphen-minus too, replace '—' with '[-—]'.
  local header_re='^##[[:space:]]+v[0-9]+\.[0-9]+\.[0-9]+a[0-9]+[[:space:]]+—[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]*$'
  local header_line
  header_line="$(printf '%s\n' "$block" | sed -n 's/^[[:space:]]*\(##[[:space:]]\+.*\)$/\1/p' | head -n1)"
  [[ -n "$header_line" ]] || die "Top changelog block lacks a '## vX.Y.ZaN — YYYY-MM-DD' header."

  if ! printf '%s\n' "$header_line" | grep -Eq "$header_re"; then
    die "Top changelog header must be '## vX.Y.ZaN — YYYY-MM-DD'. Got: '$header_line'"
  fi

  # Extract version token from the header and compare to pv (must be identical)
  local header_pv
  header_pv="$(printf '%s\n' "$header_line" | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+a[0-9]+' | sed 's/^v//')"
  if [[ "$header_pv" != "$pv" ]]; then
    die "Top changelog header version 'v${header_pv}' does not match selected version 'v${pv}'. Update the FIRST block."
  fi

  # Ensure non-empty body after the header line
  local body
  body="$(printf '%s\n' "$block" | awk 'NR==1 && /^##[[:space:]]+/ {next} {print}' | _normalize_lines)"
  [[ -n "$body" ]] || die "Top changelog block for v${pv} is empty. Add release notes."

  info "Top changelog block matches '## v${pv} — <date>' and contains content."
}

# Gate 2: file must contain a non-empty section for PV (anywhere) and be in HEAD
ensure_alpha_changelog_updated() {
  local pv="$1"    # e.g., 0.1.1a5

  [[ -n "$ALPHA_CHANGELOG" ]] || die "ALPHA_CHANGELOG is empty; set it in bash/config/alpha.sh."
  [[ -f "$ALPHA_CHANGELOG" ]] || die "Alpha changelog '$ALPHA_CHANGELOG' not found."

  # Look for a header for this PV in the strict form (anywhere in the file).
  local strict_header_re="^##[[:space:]]+v${pv}[[:space:]]+—[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]*$"
  if ! grep -Eq "$strict_header_re" "$ALPHA_CHANGELOG"; then
    die "Alpha changelog '$ALPHA_CHANGELOG' does not contain a header '## v${pv} — YYYY-MM-DD'."
  fi

  # Extract that section's body until the next '##'
  local section
  section="$(awk -v pv="$pv" '
    BEGIN { found=0 }
    match($0, "^##[[:space:]]+v" pv "[[:space:]]+—[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]*$") { found=1; next }
    found && /^##[[:space:]]+/ { exit }
    found { print }
  ' "$ALPHA_CHANGELOG" | sed '/^[[:space:]]*$/d')"

  [[ -n "$section" ]] || die "Changelog entry body for v${pv} is empty. Add release notes under its header."

  # Mandatory: ensure changelog file was part of the most recent commit
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    if ! git diff --name-only HEAD~1..HEAD -- "$ALPHA_CHANGELOG" | grep -qx "$ALPHA_CHANGELOG"; then
      die "Changelog '$ALPHA_CHANGELOG' was not included in the last commit. Commit the changelog update for this release."
    fi
  fi

  info "Changelog contains a non-empty entry for v${pv} and was in the last commit."
}

# Step: derive TAG (still needed elsewhere) and run both gates
step_tag_and_changelog_prechecks() {
  TAG="$(pep440_to_tag "$PV")" || die "Cannot derive tag from $PV"
  echo "Proposed tag: ${BLU}${TAG}${NC} (derived from ${PV})"

  export TAG
  gate_changelog_top_block_matches_version "$PV"   # FIRST block must match strict header & have content
  ensure_alpha_changelog_updated "$PV"             # Entry exists (anywhere), non-empty, included in last commit
}
