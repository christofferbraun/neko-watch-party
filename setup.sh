#!/usr/bin/env bash
# Interactive setup for neko: asks for your settings, writes .env, gluetun.env,
# neko.yaml, docker-compose.yaml and policies.json, then starts the containers.
#
# Re-run it any time to change settings; your previous answers are the defaults.
#   ./setup.sh             ask everything
#   ./setup.sh --defaults  reuse saved answers without asking (regenerates config)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ACCEPT_DEFAULTS=no
GENERATED_SECRETS=()

# ---------- prompts ----------

# ask VAR "prompt" "default" [validator]
# Enter takes the default; "-" clears it. The validator gets the answer and
# returns non-zero (after printing why) to ask again.
ask() {
  local var=$1 prompt=$2 default=${3-} validator=${4-} reply
  while true; do
    if [[ $ACCEPT_DEFAULTS == yes ]]; then
      reply=$default
    else
      printf '%s' "$prompt" >&2
      if [[ -n $default ]]; then printf ' %s[%s]%s' "$C_DIM" "$default" "$C_RESET" >&2; fi
      printf ': ' >&2
      IFS= read -r reply || die "Input ended before setup finished."
      reply=${reply:-$default}
      [[ $reply == "-" ]] && reply=""
    fi
    if v_safe "$reply" && { [[ -z $validator ]] || "$validator" "$reply"; }; then
      printf -v "$var" '%s' "$reply"
      return
    fi
    [[ $ACCEPT_DEFAULTS == yes ]] && die "No valid saved answer for \"$prompt\". Run ./setup.sh without --defaults."
  done
}

# ask_yn VAR "question" yes|no
ask_yn() {
  local var=$1 prompt=$2 default=$3 reply hint="y/N"
  [[ $default == yes ]] && hint="Y/n"
  while true; do
    if [[ $ACCEPT_DEFAULTS == yes ]]; then
      reply=$default
    else
      printf '%s [%s]: ' "$prompt" "$hint" >&2
      IFS= read -r reply || die "Input ended before setup finished."
      reply=${reply:-$default}
    fi
    case ${reply,,} in
      y|yes) printf -v "$var" yes; return ;;
      n|no)  printf -v "$var" no; return ;;
      *)     warn "Please answer y or n." ;;
    esac
  done
}

# ask_secret VAR "prompt" "current value" generate|required|optional
# Input is hidden. Enter keeps the current value, or generates/skips per mode.
ask_secret() {
  local var=$1 prompt=$2 current=${3-} mode=$4 reply hint
  if [[ $ACCEPT_DEFAULTS == yes && ( -n $current || $mode != required ) ]]; then
    if [[ -z $current && $mode == generate ]]; then
      current=$(random_password)
      GENERATED_SECRETS+=("$prompt: $current")
    fi
    printf -v "$var" '%s' "$current"
    return
  fi
  [[ $ACCEPT_DEFAULTS == yes ]] && die "No saved answer for \"$prompt\". Run ./setup.sh without --defaults."
  while true; do
    if [[ -n $current ]]; then hint="Enter keeps the current one"
    elif [[ $mode == generate ]]; then hint="Enter generates one"
    elif [[ $mode == optional ]]; then hint="Enter to skip"
    else hint="hidden"; fi
    printf '%s %s[%s]%s: ' "$prompt" "$C_DIM" "$hint" "$C_RESET" >&2
    IFS= read -rs reply || die "Input ended before setup finished."
    printf '\n' >&2
    if [[ -z $reply ]]; then
      if [[ -n $current ]]; then
        reply=$current
      elif [[ $mode == generate ]]; then
        reply=$(random_password)
        GENERATED_SECRETS+=("$prompt: $reply")
      elif [[ $mode == required ]]; then
        warn "This one is required."
        continue
      fi
    fi
    if v_safe "$reply"; then
      printf -v "$var" '%s' "$reply"
      return
    fi
  done
}

# ask_choice VAR "question" "default key" key1 "description 1" key2 "description 2" ...
ask_choice() {
  local var=$1 prompt=$2 default=$3 i n def_n=1
  shift 3
  local -a keys=() descs=()
  while (($#)); do keys+=("$1"); descs+=("$2"); shift 2; done
  for i in "${!keys[@]}"; do
    if [[ ${keys[i]} == "$default" ]]; then def_n=$((i + 1)); fi
  done
  if [[ $ACCEPT_DEFAULTS != yes ]]; then
    info "$prompt"
    for i in "${!keys[@]}"; do info "  $((i + 1))) ${descs[i]}"; done
  fi
  CHOICE_MAX=${#keys[@]}
  ask n "Choose 1-${#keys[@]}" "$def_n" v_choice
  printf -v "$var" '%s' "${keys[n - 1]}"
}

random_password() {
  local pw
  pw=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
  printf '%s' "${pw:0:24}"
}

# ---------- validators ----------

# Every value is written single-quoted into .env, so these two characters can't appear.
v_safe() {
  if [[ $1 == *"'"* || $1 == *$'\n'* ]]; then warn "Single quotes aren't allowed here."; return 1; fi
}
v_required() { [[ -n $1 ]] || { warn "This one is required."; return 1; }; }
v_choice() {
  if ! [[ $1 =~ ^[0-9]+$ ]] || ! (($1 >= 1 && $1 <= CHOICE_MAX)); then warn "Enter a number from 1 to $CHOICE_MAX."; return 1; fi
}
v_port() {
  if ! [[ $1 =~ ^[0-9]+$ ]] || ! (($1 >= 1024 && $1 <= 65535)); then warn "Enter a port from 1024 to 65535."; return 1; fi
}
v_bitrate() {
  if ! [[ $1 =~ ^[0-9]+$ ]] || ! (($1 >= 500 && $1 <= 50000)); then warn "Enter a bitrate in kbps, 500 to 50000."; return 1; fi
}
v_screen() {
  [[ $1 =~ ^[0-9]{3,4}x[0-9]{3,4}@[0-9]{2,3}$ ]] || { warn "Use WIDTHxHEIGHT@FPS, for example 1920x1080@60."; return 1; }
}
v_ipv4() {
  [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { warn "Enter an IPv4 address like 192.168.1.50."; return 1; }
}
v_ipv4_optional() { [[ -z $1 ]] || v_ipv4 "$1"; }
v_hostname() {
  [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]] || { warn "Enter a hostname like neko.example.com."; return 1; }
}
v_timezone() {
  [[ -n $1 && ( ! -d /usr/share/zoneinfo || -f /usr/share/zoneinfo/$1 ) ]] || { warn "Unknown timezone. Examples: UTC, Europe/Berlin, America/Chicago."; return 1; }
}
v_gluetun_extra() {
  [[ -z $1 || $1 =~ ^[A-Z][A-Z0-9_]*=.+$ ]] || { warn "Use KEY=VALUE, for example SERVER_CITIES=Amsterdam."; return 1; }
}
v_encoder() {
  if [[ $1 == qsv && ! -e /dev/dri/renderD128 ]]; then
    warn "/dev/dri/renderD128 doesn't exist, so there's no GPU to encode on. Pick CPU, or install your iGPU driver first."
    return 1
  fi
}

# ---------- steps ----------

preflight() {
  [[ $(uname -s) == Linux ]] || die "Run this on the Linux server that will host neko."
  [[ -t 0 || $ACCEPT_DEFAULTS == yes ]] || warn "Not running in a terminal; reading answers from stdin."
  cd "$NEKO_DIR"
}

install_dependencies() {
  step "Dependencies"
  local -a missing=()
  local c install
  for c in curl jq; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  if ((${#missing[@]})); then
    command -v apt-get >/dev/null 2>&1 || die "Install ${missing[*]} with your package manager, then re-run."
    ask_yn install "Install ${missing[*]} with apt?" yes
    [[ $install == yes ]] || die "${missing[*]} required."
    as_root apt-get update -q
    as_root apt-get install -y -q "${missing[@]}"
  fi

  if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    ask_yn install "Docker with the compose plugin isn't installed. Install it with Docker's script (get.docker.com)?" yes
    [[ $install == yes ]] || die "Docker is required: https://docs.docker.com/engine/install/"
    curl -fsSL https://get.docker.com | as_root sh
  fi
  init_docker
  ok "curl, jq and Docker are ready"
}

ask_settings() {
  local gpu_default=x264 default
  if [[ -e /dev/dri/renderD128 && $(cat /sys/class/drm/renderD128/device/vendor 2>/dev/null) == 0x8086 ]]; then
    gpu_default=qsv
  fi

  step "Video"
  default=${NEKO_ENCODER:-$gpu_default}
  while true; do
    ask_choice NEKO_ENCODER "How should video be encoded?" "$default" \
      qsv  "Intel Quick Sync (iGPU). Low CPU use; best for Intel CPUs with integrated graphics" \
      x264 "CPU (software x264). Works on any machine, but uses a lot of CPU"
    v_encoder "$NEKO_ENCODER" && break
    [[ $ACCEPT_DEFAULTS == yes ]] && die "Saved encoder is qsv, but there's no GPU. Run ./setup.sh without --defaults."
    default=x264
  done
  if [[ $NEKO_ENCODER == qsv ]]; then
    NEKO_IMAGE=ghcr.io/m1k1o/neko/intel-firefox:latest
    default=1920x1080@60
  else
    NEKO_IMAGE=ghcr.io/m1k1o/neko/firefox:latest
    default=1920x1080@30
  fi
  ask NEKO_SCREEN "Screen size and frame rate" "${NEKO_SCREEN:-$default}" v_screen
  local rate_default=5000
  if ((${NEKO_SCREEN##*@} >= 50)); then rate_default=8000; fi
  ask NEKO_HD_BITRATE "Bitrate per viewer in kbps (about 8000 for 1080p60, 5000 for 1080p30)" "${NEKO_HD_BITRATE:-$rate_default}" v_bitrate
  ask_yn NEKO_SD_STREAM "Also offer a 720p30 stream for viewers on weak connections?" "${NEKO_SD_STREAM:-yes}"

  step "Logins"
  info "Viewers log in with the user password. The admin password can kick people and change settings."
  ask_secret NEKO_USER_PASSWORD "User password" "${NEKO_USER_PASSWORD-}" generate
  ask_secret NEKO_ADMIN_PASSWORD "Admin password" "${NEKO_ADMIN_PASSWORD-}" generate
  if [[ $NEKO_USER_PASSWORD == "$NEKO_ADMIN_PASSWORD" ]]; then
    die "The user and admin passwords must differ, or every viewer gets admin."
  fi

  step "Web UI"
  info "The web UI (login, chat, controls) is plain HTTP + WebSocket."
  ask_choice NEKO_WEB_ACCESS "How should people reach it?" "${NEKO_WEB_ACCESS:-tunnel}" \
    tunnel "Cloudflare Tunnel: HTTPS on your own domain, no inbound port for the UI (recommended)" \
    lan    "Plain HTTP on a port of this server: for LAN-only use or your own reverse proxy"
  if [[ $NEKO_WEB_ACCESS == tunnel ]]; then
    info "Create the tunnel first: Cloudflare dashboard > Zero Trust > Networks > Tunnels > Create a tunnel"
    info "(Cloudflared, choose Docker). Copy only the long token after --token, not the whole command."
    ask NEKO_HOSTNAME "Public hostname you'll give the tunnel" "${NEKO_HOSTNAME:-}" v_hostname
    ask_secret TUNNEL_TOKEN "Cloudflare Tunnel token" "${TUNNEL_TOKEN-}" required
    ask NEKO_HTTP_PORT "Local port for the web UI (bound to 127.0.0.1 only)" "${NEKO_HTTP_PORT:-8080}" v_port
  else
    NEKO_HOSTNAME=${NEKO_HOSTNAME:-}
    TUNNEL_TOKEN=${TUNNEL_TOKEN:-}
    ask NEKO_HTTP_PORT "Port for the web UI" "${NEKO_HTTP_PORT:-8080}" v_port
  fi

  step "Video connection (WebRTC)"
  info "Video can't go through Cloudflare. Viewers' browsers connect straight to this"
  info "server on one UDP+TCP port, which you forward on your router."
  ask NEKO_WEBRTC_PORT "WebRTC port" "${NEKO_WEBRTC_PORT:-52000}" v_port
  local ip ts_ip
  ip=$(public_ip)
  if [[ -n $ip ]]; then
    info "The internet sees this server as ${C_BOLD}$ip${C_RESET}. If your router's WAN IP is different,"
    info "you're behind CGNAT and port forwarding won't work: use Tailscale (see RUNBOOK.md)."
  fi
  ts_ip=$(tailscale ip -4 2>/dev/null | head -n1 || true)
  info "Neko auto-detects the public IP at startup. Set an IP only to pin it, or to"
  info "use your Tailscale IP${ts_ip:+ (this server has $ts_ip)} instead of a port forward."
  ask NEKO_NAT1TO1 "IP to advertise for video (Enter for auto, - to clear)" "${NEKO_NAT1TO1:-}" v_ipv4_optional

  step "Browser VPN"
  info "Optionally, the shared browser's own browsing goes out through a VPN (gluetun),"
  info "so sites see the VPN's IP instead of yours. Video and the web UI never use it."
  ask_yn NEKO_USE_VPN "Route the browser through a VPN?" "${NEKO_USE_VPN:-yes}"
  WRITE_GLUETUN_ENV=no
  if [[ $NEKO_USE_VPN == yes ]]; then
    local keep=no
    if [[ -f $GLUETUN_ENV_FILE ]]; then
      ask_yn keep "Keep the VPN settings already in gluetun.env?" yes
    fi
    if [[ $keep == no ]]; then
      ask_vpn_settings
      WRITE_GLUETUN_ENV=yes
    fi
    info "Hosts on the direct list skip the VPN. Every other local address is blocked,"
    info "so people with control can't browse to your router or other devices."
    ask NEKO_PLEX_IP "Plex server's LAN IP, so Plex streams locally (Enter to skip, - to clear)" "${NEKO_PLEX_IP:-}" v_ipv4_optional
    ask NEKO_EXTRA_DIRECT_HOSTS "Other hosts that skip the VPN, comma-separated (Enter to skip, - to clear)" "${NEKO_EXTRA_DIRECT_HOSTS:-}"
  else
    warn "Without the VPN, people with control can reach your LAN from the shared browser."
    NEKO_PLEX_IP=${NEKO_PLEX_IP:-}
    NEKO_EXTRA_DIRECT_HOSTS=${NEKO_EXTRA_DIRECT_HOSTS:-}
  fi

  local tz_default
  tz_default=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || true)
  ask TZ "Timezone" "${TZ:-${tz_default:-UTC}}" v_timezone
}

ask_vpn_settings() {
  info "Look up your provider's page for the exact settings:"
  info "  https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers"
  ask VPN_SERVICE_PROVIDER "Provider name, as gluetun spells it (e.g. mullvad, protonvpn, nordvpn)" "${VPN_SERVICE_PROVIDER:-}" v_required
  ask_choice VPN_TYPE "Protocol" "${VPN_TYPE:-wireguard}" \
    wireguard "WireGuard (faster; use it if your provider supports it)" \
    openvpn   "OpenVPN"
  if [[ $VPN_TYPE == wireguard ]]; then
    ask_secret WIREGUARD_PRIVATE_KEY "WireGuard private key" "${WIREGUARD_PRIVATE_KEY-}" required
    ask WIREGUARD_ADDRESSES "WireGuard address, e.g. 10.64.0.2/32 (Enter if your provider's page doesn't list one)" "${WIREGUARD_ADDRESSES:-}"
  else
    ask OPENVPN_USER "OpenVPN username" "${OPENVPN_USER:-}" v_required
    ask_secret OPENVPN_PASSWORD "OpenVPN password" "${OPENVPN_PASSWORD-}" required
  fi
  ask SERVER_COUNTRIES "Server countries, comma-separated (Enter for any, - to clear)" "${SERVER_COUNTRIES:-}"

  GLUETUN_EXTRA=()
  local line
  info "Add any other settings your provider's page asks for, as KEY=VALUE. Blank line to finish."
  while true; do
    ask line "  extra setting" "" v_gluetun_extra
    [[ -z $line ]] && break
    GLUETUN_EXTRA+=("$line")
  done
}

confirm_settings() {
  local fps=${NEKO_SCREEN##*@} mbps
  mbps=$(( (NEKO_HD_BITRATE * 11 / 10 + 999) / 1000 ))
  step "Summary"
  info "Encoder:      $NEKO_ENCODER ($NEKO_IMAGE)"
  info "Screen:       ${NEKO_SCREEN%@*} at $fps fps, $NEKO_HD_BITRATE kbps$([[ $NEKO_SD_STREAM == yes ]] && echo ", plus a 720p30 stream")"
  if [[ $NEKO_WEB_ACCESS == tunnel ]]; then
    info "Web UI:       https://$NEKO_HOSTNAME via Cloudflare Tunnel"
  else
    info "Web UI:       http://$(lan_ip):$NEKO_HTTP_PORT"
  fi
  info "Video:        port $NEKO_WEBRTC_PORT UDP+TCP, advertising ${NEKO_NAT1TO1:-the auto-detected public IP}"
  info "Browser VPN:  $NEKO_USE_VPN${NEKO_PLEX_IP:+ (Plex at $NEKO_PLEX_IP goes direct)}"
  info "Upload:       about $mbps Mbps per viewer at full quality (4 viewers: about $((mbps * 4)) Mbps)"
  local go
  ask_yn go "Write the config and continue?" yes
  [[ $go == yes ]] || die "Nothing written."
}

# Picks the H.264 element: the newer va plugin if the image has it, else the older vaapi one.
# The image has no gst-inspect, so this looks for the plugin files instead.
detect_encoder_element() {
  H264_ELEMENT=x264enc
  [[ $NEKO_ENCODER == qsv ]] || return 0
  step "Checking Quick Sync in the neko image"
  info "Downloading the neko image first (around 1 GB the first time, so this can take a few minutes)."
  dk pull "$NEKO_IMAGE"
  local el
  for el in vah264enc vaapih264enc; do
    if image_has_plugin "$NEKO_IMAGE" "$el"; then
      H264_ELEMENT=$el
      ok "Using $el"
      return 0
    fi
  done
  warn "The neko image has no VA-API GStreamer plugin, so it can't encode on the iGPU."
  local fallback
  ask_yn fallback "Fall back to CPU encoding (x264)?" yes
  [[ $fallback == yes ]] || die "Check your iGPU driver: sudo vainfo --display drm --device /dev/dri/renderD128"
  NEKO_ENCODER=x264
}

# Writes a file only through a temp copy, keeping the previous version as FILE.bak.
install_file() {
  local tmp=$1 dest=$2 mode=${3:-644}
  if [[ -f $dest ]] && ! cmp -s "$tmp" "$dest"; then
    cp -p "$dest" "$dest.bak"
  fi
  chmod "$mode" "$tmp"
  mv "$tmp" "$dest"
}

kv() { printf "%s='%s'\n" "$1" "$2"; }

write_env() {
  local tmp
  tmp=$(mktemp "$NEKO_DIR/.env.XXXXXX")
  {
    echo "# Written by setup.sh. Re-run ./setup.sh to change these; it uses them as defaults."
    echo "# Contains secrets: keep it chmod 600 and out of git."
    echo
    echo "# Video"
    kv NEKO_ENCODER "$NEKO_ENCODER"
    kv NEKO_IMAGE "$NEKO_IMAGE"
    kv NEKO_SCREEN "$NEKO_SCREEN"
    kv NEKO_HD_BITRATE "$NEKO_HD_BITRATE"
    kv NEKO_SD_STREAM "$NEKO_SD_STREAM"
    echo
    echo "# Logins"
    kv NEKO_USER_PASSWORD "$NEKO_USER_PASSWORD"
    kv NEKO_ADMIN_PASSWORD "$NEKO_ADMIN_PASSWORD"
    echo
    echo "# Web UI"
    kv NEKO_WEB_ACCESS "$NEKO_WEB_ACCESS"
    kv NEKO_HOSTNAME "$NEKO_HOSTNAME"
    kv NEKO_HTTP_PORT "$NEKO_HTTP_PORT"
    kv TUNNEL_TOKEN "$TUNNEL_TOKEN"
    echo
    echo "# Video connection"
    kv NEKO_WEBRTC_PORT "$NEKO_WEBRTC_PORT"
    kv NEKO_NAT1TO1 "$NEKO_NAT1TO1"
    echo
    echo "# Browser VPN (provider settings are in gluetun.env)"
    kv NEKO_USE_VPN "$NEKO_USE_VPN"
    kv NEKO_PLEX_IP "$NEKO_PLEX_IP"
    kv NEKO_EXTRA_DIRECT_HOSTS "$NEKO_EXTRA_DIRECT_HOSTS"
    kv TZ "$TZ"
  } > "$tmp"
  install_file "$tmp" "$ENV_FILE" 600
}

write_gluetun_env() {
  [[ $WRITE_GLUETUN_ENV == yes ]] || return 0
  local tmp line
  tmp=$(mktemp "$NEKO_DIR/gluetun.env.XXXXXX")
  {
    echo "# VPN provider settings for gluetun, written by setup.sh. Contains secrets."
    echo "# Reference: https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers"
    kv VPN_SERVICE_PROVIDER "$VPN_SERVICE_PROVIDER"
    kv VPN_TYPE "$VPN_TYPE"
    if [[ $VPN_TYPE == wireguard ]]; then
      kv WIREGUARD_PRIVATE_KEY "$WIREGUARD_PRIVATE_KEY"
      if [[ -n $WIREGUARD_ADDRESSES ]]; then kv WIREGUARD_ADDRESSES "$WIREGUARD_ADDRESSES"; fi
    else
      kv OPENVPN_USER "$OPENVPN_USER"
      kv OPENVPN_PASSWORD "$OPENVPN_PASSWORD"
    fi
    if [[ -n $SERVER_COUNTRIES ]]; then kv SERVER_COUNTRIES "$SERVER_COUNTRIES"; fi
    for line in "${GLUETUN_EXTRA[@]}"; do kv "${line%%=*}" "${line#*=}"; done
  } > "$tmp"
  install_file "$tmp" "$GLUETUN_ENV_FILE" 600
}

# gst_pipeline FPS SIZE BITRATE THREADS: one capture pipeline for neko.yaml.
# SIZE is WIDTHxHEIGHT to scale to, or empty for the full screen.
gst_pipeline() {
  local fps=$1 size=$2 bitrate=$3 threads=$4 i='          ' scale='' caps='' p
  local -a params
  if [[ -n $size ]]; then
    scale='videoscale ! '
    caps=",width=${size%x*},height=${size#*x}"
  fi
  case $H264_ELEMENT in
    vah264enc)    params=(name=encoder "bitrate=$bitrate" rate-control=cbr "key-int-max=$fps" b-frames=0 target-usage=6) ;;
    vaapih264enc) params=(name=encoder "bitrate=$bitrate" rate-control=cbr "keyframe-period=$fps" max-bframes=0 quality-level=6) ;;
    x264enc)      params=(name=encoder "bitrate=$bitrate" tune=zerolatency speed-preset=veryfast "key-int-max=$fps" bframes=0 byte-stream=true) ;;
  esac
  echo "${i}ximagesrc display-name={display} show-pointer=false use-damage=false"
  echo "${i}! video/x-raw,framerate=$fps/1"
  echo "${i}! ${scale}videoconvert n-threads=$threads ! queue"
  if [[ $H264_ELEMENT == x264enc ]]; then
    echo "${i}! video/x-raw${caps},format=I420"
  else
    echo "${i}! video/x-raw${caps},format=NV12"
  fi
  echo "${i}! $H264_ELEMENT"
  for p in "${params[@]}"; do echo "${i}  $p"; done
  echo "${i}! h264parse config-interval=-1"
  echo "${i}! video/x-h264,stream-format=byte-stream"
  echo "${i}! appsink name=appsink"
}

write_neko_yaml() {
  local fps=${NEKO_SCREEN##*@} ids=hd tmp
  [[ $NEKO_SD_STREAM == yes ]] && ids="hd, sd"
  tmp=$(mktemp "$NEKO_DIR/neko.yaml.XXXXXX")
  {
    cat <<EOF
# Written by setup.sh from your answers in .env. Re-run ./setup.sh to change it;
# manual edits are overwritten.
desktop:
  screen: "$NEKO_SCREEN"

capture:
  video:
    codec: h264
    ids: [ $ids ]          # first = default; viewers can switch in the UI
    pipelines:
      hd:   # ${NEKO_SCREEN%@*} at $fps fps, $H264_ELEMENT
        gst_pipeline: |
EOF
    gst_pipeline "$fps" "" "$NEKO_HD_BITRATE" 4
    if [[ $NEKO_SD_STREAM == yes ]]; then
      cat <<EOF
      sd:   # 1280x720 at 30 fps, for viewers on weak connections
        gst_pipeline: |
EOF
      gst_pipeline 30 1280x720 3000 2
    fi
    cat <<'EOF'

session:
  implicit_hosting: false    # viewers request control instead of grabbing it
  merciful_reconnect: true
EOF
  } > "$tmp"
  install_file "$tmp" "$NEKO_DIR/neko.yaml"
}

write_compose() {
  local port=$NEKO_WEBRTC_PORT bind=127.0.0.1 tmp
  [[ $NEKO_WEB_ACCESS == lan ]] && bind=0.0.0.0
  tmp=$(mktemp "$NEKO_DIR/docker-compose.yaml.XXXXXX")
  {
    cat <<EOF
# Written by setup.sh from your answers in .env. Re-run ./setup.sh to change it;
# manual edits are overwritten. Secrets are read from .env and gluetun.env.
services:
  neko:
    image: $NEKO_IMAGE
    container_name: neko
    restart: unless-stopped
    shm_size: 2gb
EOF
    if [[ $NEKO_ENCODER == qsv ]]; then
      cat <<'EOF'
    devices:
      - /dev/dri:/dev/dri          # iGPU for encoding + browser rendering
EOF
    fi
    echo "    ports:"
    printf '      - %-26s # %s\n' \
      "\"$bind:$NEKO_HTTP_PORT:8080\"" "web UI" \
      "\"$port:$port/udp\"" "WebRTC media; must be the same port on both sides" \
      "\"$port:$port/tcp\"" "WebRTC fallback when UDP is blocked"
    cat <<EOF
    volumes:
      - ./neko.yaml:/etc/neko/neko.yaml:ro
      - ./profile:/home/neko/.mozilla/firefox/profile.default
      - ./policies.json:/usr/lib/firefox/distribution/policies.json:ro
    environment:
      NEKO_MEMBER_MULTIUSER_USER_PASSWORD: \${NEKO_USER_PASSWORD}
      NEKO_MEMBER_MULTIUSER_ADMIN_PASSWORD: \${NEKO_ADMIN_PASSWORD}
      NEKO_WEBRTC_UDPMUX: $port
      NEKO_WEBRTC_TCPMUX: $port
      NEKO_WEBRTC_ICELITE: 1
EOF
    if [[ $NEKO_ENCODER == qsv ]]; then
      cat <<'EOF'
      # The image ships a GStreamer plugin cache built without a GPU, so VA encoders
      # are missing from it. A fresh cache is built at first use, with the GPU visible.
      GST_REGISTRY: /tmp/gstreamer-registry.bin
EOF
    fi
    if [[ $NEKO_WEB_ACCESS == tunnel ]]; then
      echo '      NEKO_SERVER_PROXY: "true"     # trust the tunnel'"'"'s forwarded headers'
    fi
    if [[ -n $NEKO_NAT1TO1 ]]; then
      echo "      NEKO_WEBRTC_NAT1TO1: \"$NEKO_NAT1TO1\""
    else
      echo "      # Public IP is auto-detected at startup. To pin it, set it in ./setup.sh."
    fi
    if [[ $NEKO_USE_VPN == yes ]]; then
      cat <<'EOF'
    depends_on:
      - gluetun

  gluetun:
    image: qmcgaw/gluetun:latest
    container_name: gluetun
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    # Never publish ports here: port 8888 would become an open proxy.
    env_file: gluetun.env
    environment:
      HTTPPROXY: "on"
      HTTPPROXY_LISTENING_ADDRESS: ":8888"
      TZ: ${TZ}
EOF
    fi
    if [[ $NEKO_WEB_ACCESS == tunnel ]]; then
      cat <<'EOF'

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    command: tunnel --no-autoupdate run
    environment:
      TUNNEL_TOKEN: ${TUNNEL_TOKEN}
    depends_on:
      - neko
EOF
    fi
  } > "$tmp"
  install_file "$tmp" "$NEKO_DIR/docker-compose.yaml"
}

write_files() {
  step "Writing config"
  write_env
  write_gluetun_env
  write_neko_yaml
  write_compose
  ok "Wrote .env$([[ $WRITE_GLUETUN_ENV == yes ]] && echo ", gluetun.env"), neko.yaml and docker-compose.yaml"
  if [[ $NEKO_USE_VPN == yes && ! -f $GLUETUN_ENV_FILE ]]; then
    die "gluetun.env is missing. Re-run ./setup.sh and enter your VPN settings."
  fi
}

prepare_browser() {
  step "Browser profile and policy"
  mkdir -p "$NEKO_DIR/profile"
  if [[ $(stat -c %u "$NEKO_DIR/profile") != 1000 ]]; then
    as_root chown -R 1000:1000 "$NEKO_DIR/profile"   # neko's browser runs as UID 1000
  fi
  fetch_default_policy "$NEKO_IMAGE"
  "$NEKO_DIR/build-policy.sh"
}

configure_host() {
  step "Host"
  local allow add_groups=() g
  if command -v ufw >/dev/null 2>&1 && as_root ufw status 2>/dev/null | grep -q "Status: active"; then
    ask_yn allow "ufw is active. Allow port $NEKO_WEBRTC_PORT (UDP+TCP) through it?" yes
    if [[ $allow == yes ]]; then
      as_root ufw allow "$NEKO_WEBRTC_PORT/udp" >/dev/null
      as_root ufw allow "$NEKO_WEBRTC_PORT/tcp" >/dev/null
      ok "ufw allows $NEKO_WEBRTC_PORT/udp and $NEKO_WEBRTC_PORT/tcp"
    fi
  fi

  if [[ $EUID -ne 0 ]]; then
    local user=${USER:-$(id -un)}
    local -a want=(docker)
    [[ $NEKO_ENCODER == qsv ]] && want+=(render video)
    for g in "${want[@]}"; do
      if getent group "$g" >/dev/null && ! id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$g"; then add_groups+=("$g"); fi
    done
    if ((${#add_groups[@]})); then
      as_root usermod -aG "$(IFS=,; echo "${add_groups[*]}")" "$user"
      ok "Added $user to: ${add_groups[*]} (log out and back in for it to apply; until then the scripts use sudo)"
    fi
  fi

  if [[ $NEKO_ENCODER == qsv ]] && ! command -v intel_gpu_top >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    local tools
    ask_yn tools "Install intel-gpu-tools (intel_gpu_top shows whether Quick Sync is busy)?" yes
    if [[ $tools == yes ]]; then as_root apt-get install -y -q intel-gpu-tools; fi
  fi
}

start_containers() {
  local start
  ask_yn start "Start neko now?" yes
  [[ $start == yes ]] || { info "Start later with: docker compose up -d"; return 0; }
  step "Starting"
  compose pull
  # Recreate so changes to neko.yaml and policies.json are picked up.
  compose up -d --force-recreate --remove-orphans
  ok "Containers started"
}

next_steps() {
  local lan
  lan=$(lan_ip)
  [[ -n $lan ]] || lan="this server's LAN IP"
  step "Next steps"
  info "1. On your router, forward port $NEKO_WEBRTC_PORT (UDP and TCP) to $lan."
  info "   Give this server a DHCP reservation so its IP never changes.${NEKO_NAT1TO1:+ (Skip this if $NEKO_NAT1TO1 is a Tailscale IP.)}"
  if [[ $NEKO_WEB_ACCESS == tunnel ]]; then
    info "2. In the tunnel's Public Hostname settings: $NEKO_HOSTNAME -> type HTTP, URL neko:8080"
    info "3. Recommended: add a Cloudflare Access app for $NEKO_HOSTNAME with an email allow-list (RUNBOOK.md, step 3)."
    info "4. Run ./verify.sh, then open https://$NEKO_HOSTNAME on your phone over mobile data."
  else
    info "2. Run ./verify.sh, then open http://$(lan_ip):$NEKO_HTTP_PORT"
  fi
  if ((${#GENERATED_SECRETS[@]})); then
    info ""
    info "Generated passwords (also saved in .env):"
    local s
    for s in "${GENERATED_SECRETS[@]}"; do info "  $s"; done
  fi
}

usage() {
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
  case ${1-} in
    -y|--defaults) ACCEPT_DEFAULTS=yes ;;
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) usage; exit 1 ;;
  esac
  preflight
  install_dependencies
  load_env
  ask_settings
  confirm_settings
  # Save answers now, so they're the defaults if setup is interrupted during the download.
  write_env
  write_gluetun_env
  detect_encoder_element
  write_files
  prepare_browser
  configure_host
  start_containers
  next_steps
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
