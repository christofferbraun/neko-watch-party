# intel-fix

Unmodified copies of part of neko's fix for Quick Sync video failing with
`(pipeline error) no element "vah264enc"` (black video for every viewer):
[m1k1o/neko#721](https://github.com/m1k1o/neko/pull/721), commit `020def0`.
neko is licensed under Apache-2.0; its license is included here as
[LICENSE](LICENSE). The rest of this repository is MIT-licensed.

In neko v3.2.0 and earlier Intel images, GStreamer scans for encoders once,
when neko starts. If that happens before VA-API is usable, `vah264enc` stays
missing until neko restarts.

| File | Mounted at | What it does |
| --- | --- | --- |
| `neko-serve` | `/usr/bin/neko-serve` | Waits until `vainfo` works, clears the stale GStreamer cache, then starts neko |
| `supervisord.neko.conf` | `/etc/neko/supervisord/neko.conf` | Starts neko through `neko-serve` |

`setup.sh` mounts these only when the neko image doesn't already contain
`/usr/bin/neko-serve`, and `update.sh` re-checks after every pull, so once a neko
release ships the fix, the next `./update.sh` stops using them.

The upstream fix has a second part that isn't applied here: an entrypoint
that grants the render group before supervisord starts, which fixes a race
where neko starts without access to `/dev/dri`. `verify.sh` checks for that
case ("neko process has GPU access").
