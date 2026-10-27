#!/usr/bin/env bash
# Updates the container images, regenerates neko.yaml and docker-compose.yaml from
# your saved answers so they match the new neko image (e.g. whether it still needs
# intel-fix/), refreshes neko's stock Firefox policy, rebuilds policies.json from it,
# and recreates the containers. Viewers are disconnected briefly.
#
# To pick up changes to this repo's scripts as well:
#   git pull && ./setup.sh --defaults
set -euo pipefail
# For setup.sh's encoder check and config writers; its main() only runs when executed.
source "$(dirname "$0")/setup.sh"
ACCEPT_DEFAULTS=yes
load_env
init_docker
cd "$NEKO_DIR"

[[ -f docker-compose.yaml && -n ${NEKO_IMAGE:-} ]] || die "Not set up yet. Run ./setup.sh first."

# Pulls the neko image, then picks its H.264 encoder and whether it needs intel-fix/.
detect_encoder_element

step "Pulling images"
compose pull

step "Regenerating config"
write_neko_yaml
write_compose
ok "Wrote neko.yaml and docker-compose.yaml"

step "Refreshing the browser policy"
fetch_default_policy "$NEKO_IMAGE"
./build-policy.sh

step "Recreating containers"
compose up -d --force-recreate --remove-orphans
dk image prune -f >/dev/null
ok "Updated. Run ./verify.sh to check everything."
