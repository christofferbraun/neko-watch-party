#!/usr/bin/env bash
# Updates the container images, refreshes neko's stock Firefox policy, rebuilds
# policies.json from it, and recreates the containers. Viewers are disconnected briefly.
#
# To pick up changes to this repo's scripts as well:
#   git pull && ./setup.sh --defaults
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env
init_docker
cd "$NEKO_DIR"

[[ -f docker-compose.yaml && -n ${NEKO_IMAGE:-} ]] || die "Not set up yet. Run ./setup.sh first."

step "Pulling images"
compose pull

step "Refreshing the browser policy"
fetch_default_policy "$NEKO_IMAGE"
./build-policy.sh

step "Recreating containers"
compose up -d --force-recreate --remove-orphans
dk image prune -f >/dev/null
ok "Updated. Run ./verify.sh to check everything."
