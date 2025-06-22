#!/usr/bin/env bash

set -xeuo pipefail

FLAVOR="gdx"
IMAGE_NAME="albacore-${FLAVOR}"
IMAGE_REF="ostree-image-signed:docker://ghcr.io/ublue-os/albacore-${FLAVOR}"
export FLAVOR
export IMAGE_NAME
export IMAGE_REF
"${SCRIPTS_PATH}/image-info-set"
