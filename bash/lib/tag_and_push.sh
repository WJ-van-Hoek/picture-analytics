step_tag_and_push() {
  ensure_tag_available "$TAG" "$REMOTE"

  local sign
  sign="$(ask "Sign tag with GPG? (y/n)" "$SIGN_TAG_DEFAULT")"
  if [[ "$sign" =~ ^[Yy]$ ]]; then
    prepare_gpg
    git tag -s "$TAG" -m "Alpha release $PV"
  else
    git tag    "$TAG" -m "Alpha release $PV"
  fi
  echo "Created tag: $TAG"

  if confirm "Push tag '$TAG' to $REMOTE and trigger workflow?" "y"; then
    git commit --allow-empty -m "alpha release $PV"
    info "Created empty commit for Alpha release $PV"
    git push "$REMOTE" "$CURRENT_BRANCH"
    git push "$REMOTE" "$TAG"
    export DID_PUSH_TAG=true
    info "Tag pushed. Workflow will publish and create pre-release."
  else
    warn "Tag not pushed. Later: git push $REMOTE $TAG"
  fi
}
