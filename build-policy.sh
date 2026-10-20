#!/usr/bin/env bash
# Builds policies.json from neko's stock Firefox policy (policies.default.json),
# using NEKO_USE_VPN, NEKO_PLEX_IP and NEKO_EXTRA_DIRECT_HOSTS from .env.
# setup.sh and update.sh run this. If you run it by hand, follow with:
#   docker compose restart neko     (Firefox reads the policy only at startup)
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env
cd "$NEKO_DIR"

command -v jq >/dev/null 2>&1 || die "jq is required: sudo apt install -y jq"
[[ -f policies.default.json ]] || die "policies.default.json is missing. Run ./update.sh to fetch it."

# If Docker started before policies.json existed, it created an empty folder in its place.
if [[ -d policies.json ]]; then
  warn "policies.json is a folder (Docker created it). Replacing it."
  as_root rm -rf policies.json
fi

# Hosts the browser reaches directly instead of through the VPN.
# plex.tv is included so Plex sees your home IP and streams over the LAN.
passthrough="localhost, 127.0.0.1"
if [[ -n ${NEKO_PLEX_IP:-} ]]; then
  passthrough+=", ${NEKO_PLEX_IP}, .plex.direct, plex.tv, .plex.tv"
fi
if [[ -n ${NEKO_EXTRA_DIRECT_HOSTS:-} ]]; then
  passthrough+=", ${NEKO_EXTRA_DIRECT_HOSTS}"
fi

use_vpn=false
[[ ${NEKO_USE_VPN:-no} == yes ]] && use_vpn=true

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# Always: keep cookies and sessions across restarts, so logins persist in profile/.
# With the VPN: all browsing goes through gluetun, and so does WebRTC on websites,
# so a site can't discover your home IP that way.
jq --arg pt "$passthrough" --argjson vpn "$use_vpn" '
  .policies.SanitizeOnShutdown = {"Cache":false,"Cookies":false,"Downloads":false,"FormData":false,"History":false,"OfflineApps":false,"Sessions":false,"SiteSettings":false}
  | .policies.Homepage.StartPage = "previous-session"
  | if $vpn then
      .policies.Proxy = {"Mode":"manual","Locked":true,"HTTPProxy":"gluetun:8888","UseHTTPProxyForAllProtocols":true,"Passthrough":$pt}
      | .policies.Preferences["media.peerconnection.ice.proxy_only"] = {"Value":true,"Status":"locked"}
    else . end
' policies.default.json > "$tmp"

jq -e '.policies.SanitizeOnShutdown' "$tmp" > /dev/null || die "Generated policy is invalid."
# Write in place rather than replacing the file, so a running container's bind mount stays attached.
cat "$tmp" > policies.json
ok "policies.json built (VPN: $use_vpn)"
