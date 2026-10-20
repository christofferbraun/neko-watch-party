# neko-watch-party

A self-hosted shared browser for watching things together with friends, built on [neko](https://github.com/m1k1o/neko). One interactive script sets it all up on a Linux server:

- **Smooth video:** 1080p60 encoded on an Intel iGPU (Quick Sync), with CPU (x264) encoding for machines without one, and an optional 720p30 stream for viewers on slow connections.
- **Web UI on your domain:** served over HTTPS through a Cloudflare Tunnel, so no inbound port is needed for the UI. You can put Cloudflare Access email login in front of it.
- **Direct video:** WebRTC over a single forwarded UDP/TCP port (or Tailscale if you're behind CGNAT).
- **Optional browser VPN:** the shared browser's own traffic goes out through [gluetun](https://github.com/qdm12/gluetun). Plex and any hosts you list stay on your LAN, and every other local address is blocked.
- **Persistent logins:** cookies and sessions survive restarts.

## Quick start

On the server (Ubuntu/Debian; other distros need Docker, curl and jq installed first):

```bash
git clone https://github.com/christofferbraun/neko-watch-party.git ~/neko
cd ~/neko
./setup.sh
```

Before you run it, have these ready:

- A **Cloudflare Tunnel token**, if you use the tunnel ([RUNBOOK.md, step 1](RUNBOOK.md#step-1-create-a-cloudflare-tunnel)).
- Your **VPN provider's gluetun settings**, if you route the browser through a VPN ([gluetun wiki](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers)).

`setup.sh` installs anything missing (Docker, jq), asks for each setting, writes the config, builds the browser policy, and starts the containers. It then tells you which port to forward on your router. Re-run it any time to change something, and your previous answers become the defaults.

## Scripts

| Script | What it does |
| --- | --- |
| [setup.sh](setup.sh) | Interactive setup. `--defaults` regenerates the config from saved answers without asking. |
| [verify.sh](verify.sh) | Checks the running install: containers, tunnel, encoder, VPN IP, browser policy, ports. Then lists the checks that need a real viewer. |
| [update.sh](update.sh) | Pulls new images, refreshes neko's stock browser policy, rebuilds yours and recreates the containers. |
| [build-policy.sh](build-policy.sh) | Rebuilds `policies.json` (VPN proxy, direct hosts, keep cookies). The other scripts run it for you. |

## Generated files

`setup.sh` writes these next to itself. They're gitignored, so a `git pull` never touches them:

| File | Contents |
| --- | --- |
| `.env` | Your answers, including the neko passwords and tunnel token (mode 600) |
| `gluetun.env` | VPN provider settings (mode 600) |
| `docker-compose.yaml` | neko, plus gluetun and cloudflared if you use them |
| `neko.yaml` | Screen size and video encoding pipelines |
| `policies.json` | Firefox policy built from neko's default |
| `profile/` | The browser profile: logins and cookies. Treat it like a password vault. |

[examples/](examples/) shows what the generated config looks like for a typical Quick Sync + tunnel + VPN setup.

## Updating

```bash
cd ~/neko
git pull && ./setup.sh --defaults   # pick up changes to these scripts
./update.sh                         # newer neko, gluetun and cloudflared images
```

## More

[RUNBOOK.md](RUNBOOK.md) covers how the traffic flows, the Cloudflare and router steps, troubleshooting, security notes and the Tailscale option.
