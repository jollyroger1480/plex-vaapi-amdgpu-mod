# Plex (LSIO) Docker mod: AMD Mesa VAAPI driver — UPDATED ENGINE FORK
#
# Fork of jefflessard/plex-vaapi-amdgpu-mod
# (original: https://github.com/jefflessard/plex-vaapi-amdgpu-mod)
# Upstream's published Docker Hub image was frozen at ~2023-03
# (Mesa 22.3 / libva 2.17 / LLVM 15, musl) even though this Dockerfile says
# alpine:edge. This fork rebuilds against current alpine:edge
# (2026-09-11 build = Mesa 26.2.2 / libva 2.23 / LLVM 23 / ACO) and fixes
# the library copy list for modern Mesa:
#
#   - libLLVM-15*  -> libLLVM*        (soname changed, LLVM 23)
#   - + libgallium*                   (Mesa 23.3+: radeonsi is a stub that
#                                      dlopens libgallium-*.so at runtime;
#                                      missing it = "VAAPI connection -1")
#   - + libSPIRV-Tools.so*            (Mesa 24+: shader compiler, runtime
#                                      dlopen; missing it = silent software
#                                      fallback in Plex)
#   - + libxcb-randr.so.0*            (newer stack dlopens it at runtime)
#   - libz moved from /lib to /usr/lib in current Alpine edge
#   - libelf* glob broadened (libelf-<ver>.so + libelf.so.1)
#
# Do NOT ldd-copy the full dependency closure: that drags in musl
# libpcre2/libselinux etc., which then shadow glibc libs in the Plex
# container via LD_LIBRARY_PATH and crash Plex at startup.
# Runtime-dlopen misses are silent: Plex logs
# "[FFMPEG] Failed to initialise VAAPI connection: -1 (unknown libva error)"
# and quietly transcodes in software (1000%+ CPU).
#
# Verified live 2026-09-11: Plex 1.43.4 + linuxserver.io image, AMD
# RX 6950 XT (navi21): "final decoder: vaapi, final encoder: vaapi".
FROM alpine:edge AS source

RUN apk add mesa-va-gallium --no-cache --update-cache

RUN mkdir -p "/source/vaapi-amdgpu/lib/dri" \
 && cp -a /usr/lib/dri/*.so /source/vaapi-amdgpu/lib/dri \
 && cd /lib \
 && cp -a \
    ld-musl-x86_64.so.1* \
    libc.musl-x86_64.so.1* \
    /source/vaapi-amdgpu/lib \
 && cd /usr/lib \
 && cp -a \
    libLLVM* \
    libgallium* \
    libSPIRV-Tools.so* \
    libSPIRV-Tools-shared.so* \
    libX11-xcb.so.1* \
    libXau.so.6* \
    libXdmcp.so.6* \
    libdrm.so.2* \
    libdrm_amdgpu.so.1* \
    libdrm_nouveau.so.2* \
    libdrm_radeon.so.1* \
    libelf* \
    libexpat.so.1* \
    libgcc_s.so.1* \
    libstdc++.so.6* \
    libva-drm.so.2* \
    libva.so.2* \
    libxcb-dri2.so.0* \
    libxcb-dri3.so.0* \
    libxcb-present.so.0* \
    libxcb-randr.so.0* \
    libxcb-sync.so.1* \
    libxcb-xfixes.so.0* \
    libxcb.so.1* \
    libxml2.so.2* \
    libxshmfence.so.1* \
    libbsd.so.0* \
    libmd.so.0* \
    libzstd.so.1* \
    libffi.so.8* \
    liblzma.so.5* \
    libz.so.1* \
    /source/vaapi-amdgpu/lib \
 && mkdir -p /source/usr/share/libdrm \
 && cp -a /usr/share/libdrm/amdgpu.ids /source/usr/share/libdrm/ \
 && mkdir -p /source/etc/s6-overlay/s6-rc.d/svc-plex/

COPY run /source/etc/s6-overlay/s6-rc.d/svc-plex/

FROM scratch

#ENV LIBVA_DRIVERS_PATH="/vaapi-amdgpu/lib/dri" \

COPY --from=source "/source/" "/"
