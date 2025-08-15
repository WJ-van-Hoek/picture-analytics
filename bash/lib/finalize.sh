step_finalize() {
  if [[ "${DID_PUSH_TAG:-false}" == true ]]; then
    if confirm "Clean up local build artifacts (dist/, build/, *.egg-info) now?" "y"; then
      clean_artifacts
    else
      info "Skipping artifact cleanup."
    fi
  fi

  if [[ "${DID_PUSH_TAG:-false}" == true ]]; then
    info "Release EXECUTED: tag '$TAG' was pushed. Workflow should be running."
  else
    echo
    echo "=============================================================="
    echo "⚠️  Release NOT executed — tag not pushed."
    echo "To execute now: git push $REMOTE $TAG"
    echo "=============================================================="
    echo
    exit 2
  fi

  PKG_NAME_PIP="${PKG_NAME_PIP:-picture-analytics}"
  echo
  echo "Validate from TestPyPI with:"
  echo "  pip install --index-url https://test.pypi.org/simple/ --no-deps ${PKG_NAME_PIP}==${PV}"
  echo
  info "Alpha release flow complete."
}
