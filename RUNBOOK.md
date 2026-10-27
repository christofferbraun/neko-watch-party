# Runbook

The full walkthrough: how the traffic flows, what to prepare, the steps `setup.sh` can't do for you (Cloudflare and your router), how to verify, and what to do when something breaks.

Replace `neko.example.com` with your own hostname throughout.

## How it works

Neko has two kinds of traffic, and they reach viewers by different routes:

| Traffic | Protocol | Route to viewers |
| --- | --- | --- |
| Web UI, login, chat, controls | HTTP + WebSocket | Cloudflare Tunnel: no inbound ports, HTTPS on your domain |
| Video and audio | WebRTC (UDP, TCP fallback) on one port, 52000 by default | Router port forward, straight to the server |

Cloudflare's proxy and Tunnel only carry HTTP, so the video can't go through them. Viewers still only need the URL. After login, neko tells their browser where to fetch the video, and the browser connects to your public IP on the WebRTC port automatically.

If you turn on the browser VPN, the shared browser's own browsing takes a third route:

| What the neko browser opens | Route |
| --- | --- |
| Your Plex server, `*.plex.direct`, `plex.tv`, and any hosts you list | Direct over your LAN and home connection |
| Everything else | VPN, through gluetun's proxy. Pages stop loading if the VPN drops. |

Only the browser uses the VPN. Neko's video stream and the Cloudflare tunnel don't touch it. That's deliberate: putting neko itself inside the VPN's network would send the WebRTC port through the VPN and break video.

## Before you start

**1. CGNAT check.** Compare your router's WAN IP (on its status page) with what the internet sees:

```bash
curl -4 ifconfig.me
```

If they match, port forwarding will work. If they differ, your ISP has you behind CGNAT. In that case, use the [Tailscale option](#optional-tailscale-instead-of-a-port-forward) or a VPS relay.

**2. Upload bandwidth.** Each viewer gets their own copy of the stream: about 8 Mbps at 1080p60, so four viewers need roughly 35 Mbps of upload. Test with fast.com or `speedtest-cli`. `setup.sh` prints the estimate for your settings.

**3. Intel iGPU (for Quick Sync).** Check that the render device exists and the driver can encode H.264:

```bash
ls /dev/dri/renderD128
sudo apt install -y vainfo
sudo vainfo --display drm --device /dev/dri/renderD128 | grep -i h264
```

Look for `EncSlice` or `EncSliceLP` entries. If there's no render device, choose CPU encoding in `setup.sh`.

**4. Fixed LAN IPs.** In your router, give the server a DHCP reservation so its IP never changes. Do the same for your Plex server if you use one.

**5. Browser VPN (optional).** You need a VPN provider that gluetun supports, ideally with WireGuard. Find your provider's page in the [gluetun wiki](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers) and note the settings it asks for (usually a private key, an address and a server country).

## Step 1: Create a Cloudflare Tunnel

Skip this if you chose plain HTTP for the web UI.

The tunnel puts the web UI on `neko.example.com` over HTTPS without opening ports 80, 443 or 8080. Your existing DNS records stay as they are.

1. Go to dash.cloudflare.com, then **Zero Trust → Networks → Tunnels** (newer accounts may label it *Connectors*). Click **Create a tunnel**.
2. Choose **Cloudflared**, name it `neko`, and save.
3. On the install screen, pick **Docker**. The command shown contains `--token eyJ...`. Copy only the long token; `setup.sh` asks for it. Don't run Cloudflare's command, because the generated compose file runs cloudflared for you.

Leave the tab open. You'll add the public hostname in step 3.

## Step 2: Run setup.sh

```bash
git clone https://github.com/christofferbraun/neko-watch-party.git ~/neko
cd ~/neko
./setup.sh
```

It asks for:

| Setting | Notes |
| --- | --- |
| Encoder | Intel Quick Sync if `/dev/dri/renderD128` exists, otherwise CPU (x264). With Quick Sync, it checks which VA encoder the image has and picks it automatically. |
| Screen and bitrate | Defaults are 1920x1080@60 at 8000 kbps (Quick Sync) or 1920x1080@30 (CPU). Bitrate is per viewer. |
| 720p30 stream | A lighter stream viewers can switch to in neko's quality menu. It only runs while someone watches it. |
| Passwords | Viewers use the user password. The admin password can kick people and change settings. Press Enter to generate either one. |
| Web UI | Cloudflare Tunnel (hostname and token), or plain HTTP on a port for LAN use or your own reverse proxy. |
| WebRTC port | 52000 by default. It must be the same number on the router and the server, because neko tells browsers that exact port. |
| Advertised IP | Leave blank to auto-detect your public IP. Set it to pin a static IP or to use a Tailscale IP. |
| Browser VPN | Your gluetun provider, protocol, keys and countries, plus any extra `KEY=VALUE` settings your provider's wiki page lists. |
| Direct hosts | Your Plex server's LAN IP, plus any other hosts that should skip the VPN. |
| Timezone | Used by gluetun's logs. |

It then writes `.env`, `gluetun.env`, `neko.yaml`, `docker-compose.yaml` and `policies.json`, creates `profile/`, offers to open the port in ufw, adds you to the `docker` (and `render`/`video`) groups, and starts the containers.

Log out and back in once afterwards, so the group membership applies. Until then the scripts use sudo for Docker.

To change anything later, run `./setup.sh` again. It shows your previous answers as defaults, and it keeps a `.bak` copy of any file it changes.

## Step 3: Cloudflare hostname and Access

### 3a. Public hostname

Back on the tunnel's **Public Hostname** screen, set:

- Subdomain and domain: the hostname you gave `setup.sh` (pick one that doesn't clash with an existing DNS record)
- Service type: `HTTP`
- URL: `neko:8080` (the container name, not localhost)

Save. Cloudflare creates the CNAME automatically, and WebSockets work through tunnels by default.

### 3b. Cloudflare Access (recommended)

Access puts an email login in front of neko, so only people you list can reach the login page. Only they ever learn your home IP.

1. **Zero Trust → Access → Applications → Add an application → Self-hosted.**
2. Application domain: `neko.example.com`.
3. Add a policy with action **Allow**, include **Emails**, and list your viewers' email addresses.
4. Make sure **One-time PIN** is enabled as a login method (Settings → Authentication).
5. Save. Visitors now get an emailed code before they see neko.

## Step 4: Router port forward

Forward the WebRTC port (UDP and TCP) to the server, and nothing else. Open your router's admin page, usually `192.168.1.1` or `192.168.0.1`. Find **Port Forwarding**, **Virtual Server** or **NAT**, and add:

| Name | External port | Internal IP | Internal port | Protocol |
| --- | --- | --- | --- | --- |
| neko-udp | 52000 | server LAN IP | 52000 | UDP |
| neko-tcp | 52000 | server LAN IP | 52000 | TCP |

If the router offers a single **Both** or **TCP/UDP** option, one rule is enough.

Docker-published ports bypass ufw, but `setup.sh` still offers to add ufw rules so the setup stays explicit.

## Step 5: Verify

```bash
./verify.sh
```

It checks that the containers are running and the tunnel is connected, and that the image has your encoder and can see the iGPU. It also checks that the browser policy is mounted and keeps cookies, that `profile/` is owned by UID 1000, that the VPN exit IP differs from your home IP, and that the web UI and WebRTC port are listening.

It finishes with the checks that need a real viewer:

1. **Connect from outside.** On your phone using mobile data, not Wi-Fi, open `https://neko.example.com`. Pass the Access email code, then log in with any name plus the admin password. Video should appear within a few seconds.
2. **iGPU is doing the work.** While someone watches, run `sudo intel_gpu_top`. The **Video** row should be busy (that's Quick Sync encoding). **Render/3D** activity is the browser drawing on the GPU.
3. **Real frame rate.** On a Chrome viewer, open `chrome://webrtc-internals`, find the inbound video stream, and read `framesPerSecond`.
4. **No IP leak.** Inside neko, open `https://ifconfig.me` (should show the VPN IP) and `https://browserleaks.com/webrtc` (your home IP should not appear).
5. **Logins persist.** Log into a site in neko, run `docker compose restart neko`, and confirm you're still logged in.
6. **Plex plays locally.** Play something through app.plex.tv in neko. In Plex, **Settings → Manage → Dashboard** should show the stream as local, not remote.

Viewers log in with the user password. They watch by default; give them control from the user list.

### Watching from home

Use the normal URL on your home network too; it won't use your upload. The web UI goes through Cloudflare, but that's only a trickle of control messages. The video goes to your public IP, and the router loops it straight back inside (hairpin NAT), so it never leaves your house.

If video plays on home Wi-Fi, you're set. If the page loads but video never connects, your router doesn't hairpin; see Troubleshooting.

## Troubleshooting

Most failures are on the UDP path, so start there.

Some fixes below edit `neko.yaml` by hand. `setup.sh` regenerates that file, so re-apply the edit after re-running it (the previous version is kept as `neko.yaml.bak`).

**Page loads, but video is stuck on connecting or black.** UDP isn't reaching the server. Run this while someone connects from outside:

```bash
sudo tcpdump -ni any port 52000
```

- **No packets at all:** the router forward is wrong, or you're behind CGNAT (Before you start, check 1).
- **Packets arrive, still no video:** neko may be advertising the wrong IP. Re-run `./setup.sh` and set the advertised IP to your public IP (`curl -4 ifconfig.me`).

**Video works for viewers outside, but never connects at home.** Your router doesn't support hairpin NAT, and neko advertises only your public IP. For now, watch from mobile data. The lasting fix is running neko with host networking and full ICE so it also offers its LAN IP, but that changes how cloudflared and the VPN proxy connect.

**Black video, and neko's log says `(pipeline error) no element "vah264enc"`.** A startup race in neko v3.2.0 and earlier Intel images: neko scans for encoders before VA-API is usable. `setup.sh` applies part of neko's upstream fix to such images (see [intel-fix/](intel-fix/README.md)); run `git pull && ./update.sh` to get it. If `verify.sh` then says the neko process lacks GPU access, restart just neko once the container is up: `docker compose restart neko`.

**`setup.sh` says the image has no VA-API plugin.** The neko image changed and dropped its GPU encoder plugins. Accept the CPU fallback for now, or pin an older image tag.

**Not sure the iGPU encoder actually works?** The neko image doesn't include GStreamer's inspection tool, so this throwaway container installs it and lists the encoders your GPU exposes (it changes nothing on the server):

```bash
sudo docker run --rm --device /dev/dri:/dev/dri --entrypoint sh ghcr.io/m1k1o/neko/intel-firefox:latest -c \
  'apt-get update -qq >/dev/null && apt-get install -y -qq gstreamer1.0-tools >/dev/null && gst-inspect-1.0 2>/dev/null | grep -iE "^va.*264"'
```

You want to see `vah264enc: VA-API H.264 Encoder in Intel(R) ... Graphics`. If nothing is listed, check the driver on the host (`sudo vainfo --display drm --device /dev/dri/renderD128`) and make sure `intel-media-va-driver-non-free` (or `intel-media-va-driver`) is installed.

**Pipeline errors in the log mentioning `/dev/dri` or VA.** Check that the device is passed through:

```bash
docker exec neko ls -l /dev/dri
```

**One viewer gets no video while others do.** Their browser may refuse the H.264 profile; this mostly affects some Firefox viewers. In both pipelines in `neko.yaml`, change `video/x-h264,stream-format=byte-stream` to `video/x-h264,stream-format=byte-stream,profile=constrained-baseline`, then run `docker compose restart neko`.

**Choppy for one viewer only.** That's their bandwidth. They can switch to the `sd` (720p30) stream in neko's quality menu.

**FPS dips on heavy pages.** Check `docker stats neko`. If the CPU is pegged, raise `videoconvert n-threads` in `neko.yaml` to 6, or re-run `./setup.sh` with a 30 fps screen.

**Your home IP changed.** Neko detects the IP at startup, so run `docker compose restart neko`. If you pinned an advertised IP, update it with `./setup.sh` first.

**Neko browser says "The proxy server is refusing connections".** Gluetun hasn't connected yet, or the VPN settings are wrong. Check the log, and compare `gluetun.env` against your provider's gluetun wiki page:

```bash
docker compose logs --tail 50 gluetun
```

**`policies.json` turned into a folder.** If Docker starts before the policy file exists, it creates an empty folder with that name. `build-policy.sh` replaces it automatically:

```bash
docker compose down && ./build-policy.sh && docker compose up -d
```

**Logged out after every restart.** Run `./verify.sh`: the policy must keep cookies and `profile/` must be owned by UID 1000. Fix ownership with `sudo chown -R 1000:1000 profile`.

**Plex stream shows as remote.** Re-run `./setup.sh` and make sure your Plex server's IP is set. That also sends `plex.tv` direct, so Plex sees your home IP. As a fallback, open `http://<plex-ip>:32400/web` in neko, which always connects locally.

**Plex says the server is unavailable.** Your router's DNS rebinding protection is probably blocking `plex.direct` lookups. Whitelist `plex.direct` in the router's DNS settings, or set Plex's **Settings → Network → Secure connections** to *Preferred*.

**Plex runs on the neko server itself and shows as remote.** Plex sees neko's traffic coming from Docker's internal network. In Plex, add `172.16.0.0/12` to **Settings → Network → LAN Networks**, alongside your LAN (for example `192.168.1.0/24`).

**Anything else.** Grab the logs:

```bash
docker compose logs --tail 100 neko
```

## Security

The open port is low-risk. The main trade-off is that logged-in viewers can see your home IP.

**Why the WebRTC port is reasonably safe:**

- It's neko's WebRTC engine, not a login, shell or admin panel. It only speaks STUN, DTLS and SRTP.
- A media session needs one-time credentials and an encryption fingerprint. Neko hands those out only over the logged-in WebSocket, so a scanner hitting the port without them gets dropped.
- Docker maps the port only into the neko container, not to the rest of the server or LAN.

**Remaining risks:** a bug in neko or its WebRTC library; someone who knows your IP flooding your connection; scanners noticing the open TCP port (harmless).

**Shared logins.** Anyone you give control can use whatever accounts are logged in inside neko. Use accounts you're fine sharing, and leave Firefox's password manager off; cookies are what keep you logged in. Treat `profile/` like a password vault.

**The LAN stays walled off (with the VPN on).** Only the hosts on the direct list are reachable from the neko browser. Any other LAN address goes to the VPN proxy, and gluetun's firewall blocks local destinations. Viewers with control can't browse to your router or other devices. Without the VPN, the browser can reach your LAN like any other device on it.

**Keep it tight:**

- Keep Cloudflare Access on, so only listed viewers reach the login.
- Use strong neko passwords, and don't share the admin one.
- Forward only the WebRTC port.
- Never publish gluetun's port 8888, which would make it an open proxy.
- Update regularly.

## Maintenance

```bash
./update.sh                          # newer images, regenerated config + browser policy
git pull && ./setup.sh --defaults    # newer versions of these scripts
./setup.sh                           # change passwords or any other setting

docker compose stop                  # stop without removing
docker compose start
docker compose restart neko
```

All containers use `restart: unless-stopped`, so they come back after a reboot automatically.

## Optional: Tailscale instead of a port forward

Use this if you're behind CGNAT, or want no open port and no exposed home IP. The cost is that every viewer installs Tailscale.

1. Install Tailscale on the server and note its Tailscale IP:

   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   sudo tailscale up
   tailscale ip -4
   ```

2. Re-run `./setup.sh` and enter that `100.x.y.z` address as the advertised IP (setup shows it as a hint).
3. Delete the WebRTC port rules from your router.
4. In the Tailscale admin console, share the server with each viewer. They install Tailscale and accept the invite.
5. The web URL can stay on Cloudflare. Video now flows over Tailscale, so you need Tailscale running on your own devices too.

## Sources

- [Neko v3: Docker images](https://neko.m1k1o.net/docs/v3/installation/docker-images)
- [Neko v3: Examples (Intel GPU)](https://neko.m1k1o.net/docs/v3/installation/examples)
- [Neko v3: Audio and video capture](https://neko.m1k1o.net/docs/v3/configuration/capture)
- [Neko v3: WebRTC configuration](https://neko.m1k1o.net/docs/v3/configuration/webrtc)
- [Neko v3: Configuration reference](https://neko.m1k1o.net/docs/v3/configuration)
- [Neko v3: Reverse proxy setup](https://neko.m1k1o.net/docs/v3/reverse-proxy-setup)
- [Neko v3: Browser customization (persistent profile, policies)](https://neko.m1k1o.net/docs/v3/customization/browsers)
- [neko-vpn (browser-via-proxy approach)](https://github.com/m1k1o/neko-vpn)
- [gluetun](https://github.com/qdm12/gluetun) and its [provider setup wiki](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers)
