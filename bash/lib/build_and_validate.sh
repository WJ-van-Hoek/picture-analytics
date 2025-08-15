step_build_and_validate() {
  if ! "$PYTHON_CMD" -c "import build" >/dev/null 2>&1; then
    info "Installing build tooling (build, twine)…"
    "$PYTHON_CMD" -m pip install --upgrade pip >/dev/null
    "$PYTHON_CMD" -m pip install build twine >/dev/null
  fi
  info "Cleaning dist/ build/ *.egg-info …"; rm -rf dist build *.egg-info
  info "Building sdist & wheel …"; "$PYTHON_CMD" -m build
  info "Validating metadata with twine …"; "$PYTHON_CMD" -m twine check dist/*

  if confirm "Run local smoke install from built wheel (temp venv)?" "y"; then
    WHEEL="$(ls dist/*.whl | head -n1)"; [[ -n "$WHEEL" ]] || die "No wheel found in dist/"
    MODULE_IMPORT="$(basename "$(dirname "$INIT_FILE")")"; [[ -n "$MODULE_IMPORT" ]] || die "Cannot derive module from INIT_FILE"
    SMOKE_VENV=".smoke-venv"; rm -rf "$SMOKE_VENV"; "$PYTHON_CMD" -m venv "$SMOKE_VENV"
    SMOKE_PY="$SMOKE_VENV/bin/python"; "$SMOKE_PY" -m pip install -U pip >/dev/null
    echo "Running strict smoke test (no deps)…"; "$SMOKE_PY" -m pip install --no-deps "$WHEEL" >/dev/null
    set +e
    "$SMOKE_PY" - <<PY
import sys
try:
    import ${MODULE_IMPORT}
    print("✓ Import smoke test OK (no deps)"); sys.exit(0)
except ModuleNotFoundError as e:
    print(f"Dependency missing in strict test: {e}"); sys.exit(2)
except Exception as e:
    print(f"Import failed: {e}"); sys.exit(1)
PY
    STATUS=$?; set -e
    if [[ $STATUS -eq 2 ]]; then
      echo "Retrying smoke test with dependencies …"; "$SMOKE_PY" -m pip install "$WHEEL" >/dev/null
      "$SMOKE_PY" - <<PY
import sys
try:
    import ${MODULE_IMPORT}
    print("✓ Import smoke test OK (with deps)"); sys.exit(0)
except Exception as e:
    print(f"Import failed even with deps: {e}"); sys.exit(1)
PY
    elif [[ $STATUS -ne 0 ]]; then rm -rf "$SMOKE_VENV"; die "Smoke test failed."; fi
    rm -rf "$SMOKE_VENV"; info "Smoke test completed and cleaned up."
  fi
}
