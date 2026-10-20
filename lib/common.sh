# Shared helpers for setup.sh, verify.sh, update.sh and build-policy.sh.
# Source this file; don't run it.
# shellcheck shell=bash disable=SC2034

NEKO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$NEKO_DIR/.env"
GLUETUN_ENV_FILE="$NEKO_DIR/gluetun.env"

if [[ -t 2 ]]; then
  C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_RESET=$'\e[0m'
else
  C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_RESET=''
fi

# All messages go to stderr so they never mix with captured output.
info() { printf '%s\n' "$*" >&2; }
step() { printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET" >&2; }
ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
fail() { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { fail "$*"; exit 1; }

as_root() {
  if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

# Docker, through sudo until the user's docker group membership takes effect.
DOCKER=(docker)
init_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker isn't installed. Run ./setup.sh first."
  if ! docker info >/dev/null 2>&1; then
    if as_root docker info >/dev/null 2>&1; then
      DOCKER=(as_root docker)
    else
      die "Can't reach the Docker daemon. Is it running? (sudo systemctl start docker)"
    fi
  fi
}
dk() { "${DOCKER[@]}" "$@"; }
compose() { (cd "$NEKO_DIR" && "${DOCKER[@]}" compose "$@"); }

# .env and gluetun.env hold single-quoted values written by setup.sh, so sourcing is safe.
load_env() {
  local f
  for f in "$ENV_FILE" "$GLUETUN_ENV_FILE"; do
    if [[ -f $f ]]; then
      set -a
      # shellcheck disable=SC1090
      . "$f"
      set +a
    fi
  done
}

# Copies neko's stock Firefox policy out of the image into policies.default.json.
fetch_default_policy() {
  local image=$1 tmp=neko-policy-tmp
  dk rm -f "$tmp" >/dev/null 2>&1 || true
  dk create --name "$tmp" "$image" >/dev/null
  dk cp "$tmp:/usr/lib/firefox/distribution/policies.json" "$NEKO_DIR/policies.default.json"
  dk rm "$tmp" >/dev/null
}

public_ip() {
  curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true
}

lan_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}
