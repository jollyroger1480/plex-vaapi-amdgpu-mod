# Optional layer: GPU (OpenCL) HDR tone mapping for AMD radeonsi.
#
# Builds on top of a Plex image that already has the Mesa VAAPI stack in
# /vaapi-amdgpu (the "bake the engine into your Plex image" Dockerfile in the
# main README). Adds Mesa rusticl (OpenCL) and installs a transcoder wrapper
# that moves Plex's CPU HDR tone mapping onto the GPU. See README.md.
#
#   docker build -t plex-amdgpu-tonemap --build-arg BASE=plex-amdgpu:latest gpu-tonemap
#
# Off switch at runtime: touch /config/gpu-tonemap.disable inside the container.
ARG BASE=plex-amdgpu:latest

FROM alpine:edge AS mesa
RUN apk add --no-cache mesa-va-gallium mesa-rusticl libclc
RUN mkdir -p /out/lib/dri \
 && cp -a /usr/lib/dri/*.so /out/lib/dri \
 && cp -a /lib/ld-musl-x86_64.so.1* /lib/libc.musl-x86_64.so.1* /out/lib/ \
 && cd /usr/lib && cp -L libLLVM* libgallium* libSPIRV-Tools*.so* libX11-xcb.so.1* libXau.so.6* libXdmcp.so.6* \
    libdrm.so.2* libdrm_amdgpu.so.1* libdrm_intel.so.1* libpciaccess.so.0* libdrm_nouveau.so.2* libdrm_radeon.so.1* \
    libelf* libexpat.so.1* libgcc_s.so.1* libstdc++.so.6* libva-drm.so.2* libva.so.2* \
    libxcb-dri2.so.0* libxcb-dri3.so.0* libxcb-present.so.0* libxcb-randr.so.0* libxcb-sync.so.1* libxcb-xfixes.so.0* libxcb.so.1* \
    libxml2.so.2* libxshmfence.so.1* libbsd.so.0* libmd.so.0* libzstd.so.1* libffi.so.8* liblzma.so.5* libz.so.1* \
    libRusticlOpenCL.so* libclang-cpp.so* libLLVMSPIRVLib.so* /out/lib/ \
 && hdr=$(apk info | grep -m1 -E '^clang[0-9]+-headers$') && test -n "$hdr" \
 && mkdir -p /out/clang && for f in $(apk info -L "$hdr" | grep -v ' contains:' | grep .); do \
      mkdir -p "/out/clang/$(dirname "$f")"; cp -a "/$f" "/out/clang/$f"; done

FROM ${BASE}
COPY --from=mesa /out/lib /vaapi-amdgpu/lib
COPY --from=mesa /out/clang/ /
COPY --from=mesa /usr/share/clc /usr/share/clc
# rusticl looks for libclc under the Mesa target names.
RUN ln -s spirv64-unknown-unknown/libclc.spv /usr/share/clc/spirv64-mesa3d-.spv \
 && ln -s spirv32-unknown-unknown/libclc.spv /usr/share/clc/spirv-mesa3d-.spv \
 && mkdir -p /etc/OpenCL/vendors \
 && echo /vaapi-amdgpu/lib/libRusticlOpenCL.so.1 > /etc/OpenCL/vendors/rusticl.icd
ENV RUSTICL_ENABLE=radeonsi
RUN mv "/usr/lib/plexmediaserver/Plex Transcoder" "/usr/lib/plexmediaserver/Plex Transcoder.real"
COPY --chmod=755 ["plex-transcoder-wrapper.sh", "/usr/lib/plexmediaserver/Plex Transcoder"]
