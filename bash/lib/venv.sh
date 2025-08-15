step_env_prepare() {
  VENV_DIR="${VENV_DIR:-.venv}" ; VENV_PIP_INSTALL="${VENV_PIP_INSTALL:-.}"
  command -v deactivate >/dev/null 2>&1 && deactivate || true
  [[ -d "$VENV_DIR" ]] || { echo "Creating Python virtual environment in $VENV_DIR …"; python3 -m venv "$VENV_DIR"; }
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
  PYTHON_CMD="$VENV_DIR/bin/python"; export PYTHON_CMD
  "$PYTHON_CMD" -m pip install --upgrade pip
  "$PYTHON_CMD" -m pip install --upgrade setuptools wheel build twine
  pip install "${VENV_PIP_INSTALL:-.}"
  "$PYTHON_CMD" -m pip >/dev/null 2>&1 || die "pip not available for $("$PYTHON_CMD" -V 2>/dev/null || echo python)."
}
