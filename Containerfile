ARG MAJOR_VERSION="${MAJOR_VERSION:-10}"
FROM quay.io/almalinuxorg/almalinux-bootc:10-kitten

ARG ENABLE_DX="${ENABLE_DX:-0}"
ARG ENABLE_GDX="${ENABLE_GDX:-0}"
ARG IMAGE_NAME="${IMAGE_NAME:-blueshift}"
ARG IMAGE_VENDOR="${IMAGE_VENDOR:-alma}"
ARG MAJOR_VERSION="${MAJOR_VERSION:-10}"
ARG SHA_HEAD_SHORT="${SHA_HEAD_SHORT:-deadbeef}"

COPY system_files /files
COPY system_files_overrides /overrides
COPY build_scripts /build_scripts

RUN sh /build_scripts/00-workarounds.sh
RUN sh /build_scripts/10-packages-image-base.sh  
RUN sh /build_scripts/20-packages.sh  
RUN sh /build_scripts/26-packages-post.sh  
RUN sh /build_scripts/40-services.sh  
RUN sh /build_scripts/90-image-info.sh  
RUN sh /build_scripts/cleanup.sh
RUN sh /build_scripts/build.sh

# Makes `/opt` writeable by default
# Needs to be here to make the main image build strict (no /opt there)
RUN rm -rf /opt && ln -s /var/opt /opt 
