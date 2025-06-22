FROM scratch AS ctx

COPY system_files /files
COPY system_files_overrides /overrides
COPY build_scripts /build_scripts

FROM quay.io/almalinuxorg/almalinux-bootc:10

ARG ENABLE_DX="${ENABLE_DX:-0}"
ARG ENABLE_GDX="${ENABLE_GDX:-0}"
ARG IMAGE_NAME="${IMAGE_NAME:-albacore}"
ARG IMAGE_VENDOR="${IMAGE_VENDOR:-hanthor}"
ARG MAJOR_VERSION="${MAJOR_VERSION:-10}"
ARG SHA_HEAD_SHORT="${SHA_HEAD_SHORT:-deadbeef}"

RUN --mount=type=tmpfs,dst=/opt \
  --mount=type=tmpfs,dst=/tmp \
  --mount=type=tmpfs,dst=/var \
  --mount=type=tmpfs,dst=/boot \
  --mount=type=bind,from=ctx,source=/,target=/run/context \
  /run/context/build_scripts/build.sh

# Makes `/opt` writeable by default
# Needs to be here to make the main image build strict (no /opt there)
RUN rm -rf /opt && ln -s /var/opt /opt 
