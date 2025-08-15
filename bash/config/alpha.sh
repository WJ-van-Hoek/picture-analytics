# Core paths
PYPROJECT="${PYPROJECT:-./pyproject.toml}"
INIT_FILE="${INIT_FILE:-./src/scripts/__init__.py}"
ALPHA_CHANGELOG="${ALPHA_CHANGELOG:-changelogs/alpha.md}"

# Branching / git
RC_BRANCH="${RC_BRANCH:-alpha-rc}"
REMOTE="${REMOTE:-origin}"
SIGN_TAG_DEFAULT="${SIGN_TAG_DEFAULT:-n}"

# Python / venv
VENV_DIR="${VENV_DIR:-.venv}"
VENV_PIP_INSTALL="${VENV_PIP_INSTALL:-.}"

# Feature flags
ENFORCE_MONOTONIC_VERSION="${ENFORCE_MONOTONIC_VERSION:-true}"
GPG_PREPARE="${GPG_PREPARE:-true}"

# Python command preference (respect active venv)
if [[ -n "${VIRTUAL_ENV:-}" && -x "${VIRTUAL_ENV}/bin/python" ]]; then
  PYTHON_CMD="${VIRTUAL_ENV}/bin/python"
else
  PYTHON_CMD="${PYTHON_CMD:-python3}"
fi
