#!/usr/bin/env bash
# Checks a running install: containers, tunnel, encoder, VPN, browser policy,
# profile and ports. Prints the checks that need a real viewer at the end.
set -uo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env
init_docker
cd "$NEKO_DIR" || exit 1

failures=0
pass() { ok "$1"; }
flunk() { fail "$1"; failures=$((failures + 1)); }
# check "description" command...: passes when the command succeeds.
check() {
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else flunk "$desc"; fi
}

[[ -f docker-compose.yaml ]] || die "No docker-compose.yaml. Run ./setup.sh first."
mapfile -t services < <(compose config --services 2>/dev/null)
((${#services[@]})) || die "docker compose can't read the config. Try: docker compose config"
has() { printf '%s\n' "${services[@]}" | grep -qx "$1"; }
running() { [[ $(dk inspect -f '{{.State.Running}}' "$1" 2>/dev/null) == true ]]; }
tunnel_registered() { compose logs cloudflared 2>&1 | grep -qi 'registered tunnel connection'; }
policy_mounted() { dk exec neko cat /usr/lib/firefox/distribution/policies.json | cmp -s - policies.json; }
profile_owned() { [[ $(stat -c %u profile 2>/dev/null) == 1000 ]]; }
listening() { ss -Hl"$1"n "sport = :$2" | grep -q .; }

step "Containers"
for s in "${services[@]}"; do
  check "$s is running" running "$s"
done

if has cloudflared; then
  step "Cloudflare Tunnel"
  check "Tunnel has registered connections" tunnel_registered
fi

step "Video encoding"
encoder=$(grep -oE 'vah264enc|vaapih264enc|x264enc' neko.yaml | head -n1)
if [[ -n $encoder ]]; then
  check "neko image has the $encoder encoder" dk exec neko gst-inspect-1.0 "$encoder"
fi
if [[ $encoder == va*h264enc ]]; then
  check "iGPU is passed into the container" dk exec neko test -e /dev/dri/renderD128
fi

step "Browser"
check "policies.json is a file" test -f policies.json
check "Policy keeps cookies and sessions" jq -e '[.policies.SanitizeOnShutdown[]] | all(. == false)' policies.json
check "Container sees the same policy" policy_mounted
check "profile/ is owned by UID 1000" profile_owned

if has gluetun; then
  check "Policy sends browsing through gluetun" jq -e '.policies.Proxy.HTTPProxy == "gluetun:8888"' policies.json
  vpn_ip=$(compose logs gluetun 2>&1 | grep -i 'public ip' | tail -n1 | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
  home_ip=$(public_ip)
  if [[ -z $vpn_ip ]]; then
    flunk "gluetun hasn't reported a VPN IP yet (docker compose logs gluetun)"
  elif [[ -n $home_ip && $vpn_ip == "$home_ip" ]]; then
    flunk "VPN IP $vpn_ip is your home IP: the VPN isn't working"
  else
    pass "VPN is up: browser exits from $vpn_ip${home_ip:+ (home is $home_ip)}"
  fi
fi

step "Network"
port=${NEKO_WEBRTC_PORT:-52000}
check "Web UI answers on 127.0.0.1:${NEKO_HTTP_PORT:-8080}" curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:${NEKO_HTTP_PORT:-8080}/"
check "Listening on $port/udp" listening u "$port"
check "Listening on $port/tcp" listening t "$port"

step "Check by hand"
url="https://${NEKO_HOSTNAME:-<your hostname>}"
[[ ${NEKO_WEB_ACCESS:-tunnel} == lan ]] && url="http://$(lan_ip):${NEKO_HTTP_PORT:-8080}"
n=0
todo() { n=$((n + 1)); info "$n. $*"; }
todo "On your phone over mobile data (not Wi-Fi), open $url and log in. Video should start within seconds."
info "   Stuck on connecting? Run: sudo tcpdump -ni any port $port   (no packets = router forward or CGNAT)"
if [[ $encoder == va*h264enc ]]; then
  todo "While someone watches: sudo intel_gpu_top. The Video row should be busy."
fi
todo "In Chrome: chrome://webrtc-internals > inbound video > framesPerSecond should match your frame rate."
if has gluetun; then
  todo "Inside neko, open https://browserleaks.com/webrtc. Your home IP shouldn't appear."
fi
todo "Log into a site in neko, run: docker compose restart neko, and check you're still logged in."
if [[ -n ${NEKO_PLEX_IP:-} ]]; then
  todo "Play something on Plex in neko. Plex's dashboard should show it as local, not remote."
fi

echo >&2
if ((failures)); then
  fail "$failures check(s) failed. See Troubleshooting in RUNBOOK.md."
  exit 1
fi
ok "All automatic checks passed."
