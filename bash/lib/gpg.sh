prepare_gpg() {
  [[ "$GPG_PREPARE" == "true" ]] || return 0
  if command -v gpg >/dev/null 2>&1; then
    [[ -t 1 ]] && export GPG_TTY="$(tty)"
    gpg --list-secret-keys --keyid-format=long >/dev/null 2>&1 || die "No GPG secret keys found. Configure git user.signingkey."
    git config --get user.signingkey >/dev/null || {
      warn "git config user.signingkey is not set."
      local kid; kid="$(gpg --list-secret-keys --keyid-format=long | awk '/^sec/{print $2}' | sed 's|.*/||' | head -n1)"
      [[ -n "$kid" ]] && confirm "Set user.signingkey to $kid?" "y" && git config --local user.signingkey "$kid" || die "No signing key configured."
      info "Configured user.signingkey=$kid (local)."
    }
  else die "gpg not found. Install GnuPG."; fi
}

confirm_release_version() {
  local v="$1" t="$2"
  echo
  echo "About to build and release:"
  echo "  Version: $v"
  echo "  Tag:     $t"
  echo "  Branch:  $CURRENT_BRANCH"
  [[ -n "$ALPHA_CHANGELOG" ]] && echo "  Changelog: $ALPHA_CHANGELOG"
  confirm "Proceed with building this version?" "y"
}
