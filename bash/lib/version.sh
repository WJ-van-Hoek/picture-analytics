# --- existing functions kept; we add a few helpers and call them early in step_version_select ---

get_pyproject_version(){ awk -F '"' '/^\s*version\s*=\s*"/ {print $2; exit}' "$PYPROJECT"; }
get_init_version()    { awk -F '"' '/__version__\s*=\s*"/ {print $2; exit}' "$INIT_FILE"; }

set_versions() {
  local new="$1"
  "$PYTHON_CMD" - "$PYPROJECT" "$INIT_FILE" "$new" <<'PY'
import sys, re, pathlib
pyproject = pathlib.Path(sys.argv[1]); initf = pathlib.Path(sys.argv[2]); new = sys.argv[3]
pat_v = re.compile(r'(?m)^(\s*version\s*=\s*)(["\'])([^"\']+)(\2)')
txt = pyproject.read_text(encoding='utf-8'); txt, _ = pat_v.subn(lambda m: f'{m.group(1)}{m.group(2)}{new}{m.group(2)}', txt, 1); pyproject.write_text(txt, encoding='utf-8')
pat_i = re.compile(r'(?m)^(\s*__version__\s*=\s*)(["\'])([^"\']*)(\2)')
txt = initf.read_text(encoding='utf-8'); txt, _ = pat_i.subn(lambda m: f'{m.group(1)}{m.group(2)}{new}{m.group(2)}', txt, 1); initf.write_text(txt, encoding='utf-8')
PY
}

# ------------------------------
# Semver helpers (alpha only)
# ------------------------------
is_alpha_pep440(){ [[ "$1" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)a([0-9]+)$ ]]; }
pep440_to_tag(){ [[ "$1" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)a([0-9]+)$ ]] || return 1; echo "v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}-alpha.${BASH_REMATCH[4]}"; }
bump_alpha(){ is_alpha_pep440 "$1" || die "Not alpha: $1"; local M="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}" p="${BASH_REMATCH[3]}" a="${BASH_REMATCH[4]}"; echo "${M}.${m}.${p}a$((a+1))"; }
bump_patch_alpha(){ is_alpha_pep440 "$1" || die "Not alpha: $1"; local M="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}" p="${BASH_REMATCH[3]}"; echo "${M}.${m}.$((p+1))a1"; }
bump_minor_alpha(){ is_alpha_pep440 "$1" || die "Not alpha: $1"; local M="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}"; echo "${M}.$((m+1)).0a1"; }

# ------------------------------
# NEW: discover latest releases from Git tags
# ------------------------------

# Return newest tag matching the pattern (or empty), using natural version sort.
_latest_tag() { git tag --list "$1" | sort -V | tail -n1; }

# Latest *alpha* tag like vX.Y.Z-alpha.N
get_latest_alpha_tag() {
  _latest_tag 'v*-alpha.*'
}

# Latest *stable* tag like vX.Y.Z (no -alpha.*)
get_latest_stable_tag() {
  # list all vX.Y.Z tags and exclude any with -alpha.
  git tag --list 'v[0-9]*.[0-9]*.[0-9]*' | grep -v -- '-alpha\.' | sort -V | tail -n1
}

# Convert a vX.Y.Z-alpha.N tag -> PEP 440 X.Y.ZaN
alpha_tag_to_pep440() {
  local t="$1"
  if [[ "$t" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)-alpha\.([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}a${BASH_REMATCH[4]}"
  else
    return 1
  fi
}

# Suggest a next alpha if we need to enter one from scratch:
#  - If a latest alpha exists -> bump aN+1
#  - Else if a stable exists  -> start at that patch+1 a1
#  - Else                     -> 0.1.0a1
suggest_next_alpha_from_tags() {
  local latA latApv latS
  latA="$(get_latest_alpha_tag || true)"
  if [[ -n "$latA" ]]; then
    latApv="$(alpha_tag_to_pep440 "$latA" || true)"
    if [[ -n "$latApv" ]]; then
      bump_alpha "$latApv"
      return
    fi
  fi
  latS="$(get_latest_stable_tag || true)"
  if [[ -n "$latS" && "$latS" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    local M="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}" p="${BASH_REMATCH[3]}"
    echo "${M}.${m}.$((p+1))a1"
    return
  fi
  echo "0.1.0a1"
}

# Print a small dashboard of latest tags; export for other steps if needed.
print_latest_releases() {
  LATEST_STABLE_TAG="$(get_latest_stable_tag || true)"
  LATEST_ALPHA_TAG="$(get_latest_alpha_tag || true)"
  LATEST_ALPHA_PV="$(alpha_tag_to_pep440 "$LATEST_ALPHA_TAG" || true)"

  echo
  echo "Latest releases (from Git tags):"
  if [[ -n "$LATEST_STABLE_TAG" ]]; then
    echo "  • Stable: $LATEST_STABLE_TAG"
  else
    echo "  • Stable: <none>"
  fi
  if [[ -n "$LATEST_ALPHA_TAG" ]]; then
    echo "  • Alpha : $LATEST_ALPHA_TAG (PEP 440 → ${LATEST_ALPHA_PV})"
  else
    echo "  • Alpha : <none>"
  fi
  export LATEST_STABLE_TAG LATEST_ALPHA_TAG LATEST_ALPHA_PV
  echo
}

# ------------------------------
# Existing interactive step with a tiny addition up-front
# ------------------------------
step_version_select() {
  PV="$(get_pyproject_version || true)"; IV="$(get_init_version || true)"
  echo "Detected versions:"
  echo "  $PYPROJECT version:     ${PV:-<none>}"
  echo "  $INIT_FILE __version__: ${IV:-<none>}"

  # NEW: show latest releases first (informational only; no logic change)
  print_latest_releases

  if [[ -z "${PV:-}" || -z "${IV:-}" || "$PV" != "$IV" ]] || ! is_alpha_pep440 "$PV"; then
    warn "Version mismatch or not an alpha version (expected X.Y.ZaN)."
    # Use a sensible default derived from tags (still editable by you)
    local _default
    _default="$(suggest_next_alpha_from_tags)"
    NEWV="$(ask "Enter alpha version (e.g., 0.1.0a4)" "$_default")"
    is_alpha_pep440 "$NEWV" || die "Version '$NEWV' is not alpha (expected X.Y.ZaN)."
    echo "Updating versions to $NEWV ..."
    set_versions "$NEWV"
    git add "$PYPROJECT" "$INIT_FILE"
    git commit -m "chore(release): bump version to $NEWV [alpha]"
    PV="$NEWV"; IV="$NEWV"
    info "Versions updated and committed."
  else
    info "Versions are consistent and alpha: $PV"
    echo
    echo "Choose a version action:"
    echo "  1) Keep current                -> $PV"
    echo "  2) Bump alpha (aN + 1)         -> $(bump_alpha "$PV")"
    echo "  3) New PATCH alpha (Z+1 a1)    -> $(bump_patch_alpha "$PV")"
    echo "  4) New MINOR alpha (Y+1.0 a1)  -> $(bump_minor_alpha "$PV")"
    echo "  5) Enter custom (X.Y.ZaN)"
    choice="$(ask "Select [1-5]" "1")"
    case "$choice" in
      1) NEWV="$PV" ;;
      2) NEWV="$(bump_alpha "$PV")" ;;
      3) NEWV="$(bump_patch_alpha "$PV")" ;;
      4) NEWV="$(bump_minor_alpha "$PV")" ;;
      5) NEWV="$(ask "Enter alpha version (X.Y.ZaN)" "$PV")"; is_alpha_pep440 "$NEWV" || die "Not alpha: $NEWV" ;;
      *) die "Invalid choice" ;;
    esac
    if [[ "$NEWV" != "$PV" ]]; then
      echo "Updating versions to $NEWV …"
      set_versions "$NEWV"
      git add "$PYPROJECT" "$INIT_FILE"
      git commit -m "chore(release): bump version to $NEWV [alpha]"
      PV="$NEWV"; IV="$NEWV"
      info "Versions updated and committed."
    fi
  fi

  export PV IV
}
