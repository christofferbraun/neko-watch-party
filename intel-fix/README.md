# intel-fix

Unmodified copies of the scripts from neko's fix for Quick Sync video failing with
`(pipeline error) no element "vah264enc"` (black video for every viewer):
[m1k1o/neko#721](https://github.com/m1k1o/neko/pull/721), commit `020def0`.
neko is licensed under Apache-2.0; its license is included here as
[LICENSE](LICENSE). The rest of this repository is MIT-licensed.

In neko v3.2.0 and earlier Intel images, GStreamer scans for encoders once,
when neko starts. If that happens before VA-API is usable, `vah264enc` stays
missing until neko restarts. It also races to add neko to the GPU's render
group, so neko can start without access to `/dev/dri` at all.

| File | Mounted at | What it does |
| --- | --- | --- |
| `neko-serve` | `/usr/bin/neko-serve` | Waits until `vainfo` works, clears the stale GStreamer cache, then starts neko |
| `supervisord.neko.conf` | `/etc/neko/supervisord/neko.conf` | Starts neko through `neko-serve` |
| `entrypoint.sh` | `/usr/bin/entrypoint.sh` | Adds the neko user to the render group before supervisord starts, so neko itself can open `/dev/dri` |

`setup.sh` also sets these in `docker-compose.yaml`, as neko's fixed image does:
`entrypoint: ["/usr/bin/entrypoint.sh"]`, `command:` copied from the image (setting
an entrypoint clears it), and `LIBVA_DRIVER_NAME: iHD`, without which libva can't
use the X display, so `vainfo` in `neko-serve` never succeeds.

`setup.sh` applies all of this only when the neko image doesn't already contain
`/usr/bin/neko-serve`, and `update.sh` re-checks after every pull, so once a neko
release ships the fix, the next `./update.sh` stops using them.
