RED="$(printf '\033[31m')"; GRN="$(printf '\033[32m')"; YEL="$(printf '\033[33m')"; BLU="$(printf '\033[34m')"; NC="$(printf '\033[0m')"

ask()      { local q="$1"; local d="${2:-}"; read -r -p "$(printf "${BLU}?${NC} %s %s " "$q" "${d:+[$d]}")" ans || true; echo "${ans:-$d}"; }
confirm()  { local q="$1"; local d="${2:-y}"; local ans; ans="$(ask "$q" "$d")"; [[ "$ans" =~ ^[Yy]$ ]]; }
die()      { echo -e "${RED}✖ $*${NC}"; exit 1; }
info()     { echo -e "${GRN}✔${NC} $*"; }
warn()     { echo -e "${YEL}!${NC} $*"; }
require_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

clean_artifacts() {
  echo "Removing build artifacts: dist/, build/, *.egg-info"
  rm -rf dist build *.egg-info
  info "Cleanup complete."
}
