# plex-vaapi-amdgpu-mod (UPDATED ENGINE FORK)

Fork of [jefflessard/plex-vaapi-amdgpu-mod](https://github.com/jefflessard/plex-vaapi-amdgpu-mod) — full credit to jefflessard for the original mod and approach.

[linuxserver.io mod](https://github.com/linuxserver/docker-mods) that adds AMD amdgpu hardware VAAPI transcoding to the [linuxserver.io Plex Media Server image](https://docs.linuxserver.io/images/docker-plex).

## Why this fork exists

Upstream's published Docker Hub image (`jefflessard/plex-vaapi-amdgpu-mod`) is frozen at ~2023-03 — **Mesa 22.3 / libva 2.17 / LLVM 15** — even though the Dockerfile builds from `alpine:edge` (the published image just wasn't rebuilt). This fork rebuilds against current `alpine:edge` (**2026-09-11 build = Mesa 26.2.2 / libva 2.23 / LLVM 23 / ACO**) and fixes the library copy list for modern Mesa.

The libraries come from the [mesa-va-gallium](https://pkgs.alpinelinux.org/package/edge/main/x86/mesa-va-gallium) package on `alpine:edge` (musl). They are kept isolated in `/vaapi-amdgpu/lib` so they never overwrite the Ubuntu/glibc libraries that ship with `plexmediaserver` — the same approach as upstream, with `VERSION=latest` Plex images.

## What changed vs upstream

Each of these was a silent failure on modern Mesa (Plex logs
`[FFMPEG] Failed to initialise VAAPI connection: -1 (unknown libva error)`
and quietly falls back to software, 1000%+ CPU):

| Change | Why |
|---|---|
| `libLLVM-15*` → `libLLVM*` | LLVM soname changed (now 23) |
| add `libgallium*` | Mesa 23.3+: radeonsi is a stub that dlopens `libgallium-*.so` |
| add `libSPIRV-Tools.so*` | Mesa 24+: shader compiler, runtime dlopen |
| add `libxcb-randr.so.0*` | newer stack dlopens it at runtime |
| `libz.so.1*` from `/usr/lib` | moved out of `/lib` in current Alpine edge |
| `libelf*` (broadened glob) | covers `libelf-<ver>.so` + `libelf.so.1` |

Deliberately NOT changed: the runtime `libva` API stays whatever `mesa-va-gallium` pulls on Alpine edge, and the copy list stays **curated** — do not ldd-copy the full closure, it drags in musl `libpcre2`/`libselinux` which shadow glibc libs in the Plex container (via `LD_LIBRARY_PATH`) and crash Plex at startup.

Verified live 2026-09-11: Plex 1.43.4 (`lscr.io/linuxserver/plex:latest`), AMD RX 6950 XT (navi21): `hardware transcoding: final decoder: vaapi, final encoder: vaapi`.

## Usage

```bash
docker run -d \
  --device /dev/dri/ \
  -e DOCKER_MODS=<this-fork-image> \
  -e VERSION=latest \
  -e LD_LIBRARY_PATH=/vaapi-amdgpu/lib \
  -e LIBVA_DRIVERS_PATH=/vaapi-amdgpu/lib/dri \
  --name plex \
  linuxserver/plex
```

Note: on recent Plex versions the server resets `LIBVA_DRIVERS_PATH` for its own spawned transcoders, so setting both env vars explicitly in the container (as above) is more reliable than relying on the mod's s6 `svc-plex` launcher alone.

## Troubleshooting

Check which GPU the render node maps to first (`renderD128` may not be your big card):

```bash
for c in card0 card1 card2; do [ -d /sys/class/drm/$c/device ] && \
  echo "$c: $(grep PCI_ID /sys/class/drm/$c/device/uevent)"; done
```

Test the transcoder directly (use the render node of your transcode GPU):

```bash
docker exec -it -e LIBVA_DRIVERS_PATH=/vaapi-amdgpu/lib/dri -e LD_LIBRARY_PATH=/vaapi-amdgpu/lib plex \
  /usr/lib/plexmediaserver/Plex\ Transcoder -hide_banner -loglevel debug -vaapi_device /dev/dri/renderD128
```

Success in the Plex server log looks like:

```
hardware transcoding: final decoder: vaapi, final encoder: vaapi
```

If you see `final decoder: , final encoder:` (empty) or repeated
`Failed to initialise VAAPI connection: -1`, Plex fell back to software — a runtime-dlopen'd library is missing from the bundle (historically: `libgallium`, `libSPIRV-Tools.so`, `libxcb-randr.so.0`).

## Building the mod image yourself

```bash
docker build -t <registry>/plex-vaapi-amdgpu-mod:latest .
docker push <registry>/plex-vaapi-amdgpu-mod
```

The engine tracks `alpine:edge`, so a plain rebuild whenever Mesa releases picks up the new driver.
