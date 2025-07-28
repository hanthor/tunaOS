# TunaOS Build System Justfile
#
# Common environment variables:

export repo_organization := env("GITHUB_REPOSITORY_OWNER", "hanthor")
export image_name := env("IMAGE_NAME", "yellowfin")
export centos_version := env("CENTOS_VERSION", "10")
export default_tag := env("DEFAULT_TAG", "latest")
export bib_image := env("BIB_IMAGE", "quay.io/centos-bootc/bootc-image-builder:latest")
builddir := shell('mkdir -p $1 && echo $1', absolute_path(env('BUILD', 'output')))

# Common aliases for frequently used commands

alias build-vm := build-qcow2
alias run-vm := run-vm-qcow2

[private]
default:
    @just --list

# Check Just Syntax
[group('Just')]
check:
    #!/usr/bin/env bash
    find . -type f -name "*.just" | while read -r file; do
    	echo "Checking syntax: $file"
    	just --unstable --fmt --check -f $file
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt --check -f Justfile

# Fix Just Syntax
[group('Just')]
fix:
    #!/usr/bin/env bash
    find . -type f -name "*.just" | while read -r file; do
    	echo "Checking syntax: $file"
    	just --unstable --fmt -f $file
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt -f Justfile || { exit 1; }

# Clean build outputs and temporary files
[group('Utility')]
clean:
    #!/usr/bin/env bash
    set -eoux pipefail
    touch _build
    find *_build* -exec rm -rf {} \; 2>/dev/null || true
    rm -f previous.manifest.json changelog.md output.env

# sudoif bash function
[group('Utility')]
[private]
sudoif command *args:
    #!/usr/bin/env bash
    function sudoif(){
        if [[ "${UID}" -eq 0 ]]; then
            "$@"
        elif [[ "$(command -v sudo)" && -n "${SSH_ASKPASS:-}" ]] && [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
            /usr/bin/sudo --askpass "$@" || exit 1
        elif [[ "$(command -v sudo)" ]]; then
            /usr/bin/sudo "$@" || exit 1
        else
            exit 1
        fi
    }
    {{ command }} {{ args }}

# Build container image with optional DX/GDX features
#
# Parameters:
#   target_image: Image name (default: yellowfin)
#   tag: Image tag (default: latest)
#   dx: Enable Developer Experience ("0" or "1")
#   gdx: Enable GPU Developer Experience ("0" or "1")
#   platform: Target platform (default: linux/amd64)
#
# Examples:
#   just build                           # Basic build
#   just build yellowfin latest 1 0     # Build with DX enabled

# just local-build                     # Build and rechunk locally
build $target_image=image_name $tag=default_tag $dx="0" $gdx="0" $platform="linux/amd64":
    #!/usr/bin/env bash
    set -euo pipefail

    # Handle empty tag parameter - use default_tag if tag is empty
    if [[ -z "${tag}" ]]; then
        tag="${default_tag}"
    fi

    # Get Version
    ver="${tag}-${centos_version}.$(date +%Y%m%d)"

    BUILD_ARGS=()
    BUILD_ARGS+=("--build-arg" "MAJOR_VERSION=${centos_version}")
    BUILD_ARGS+=("--build-arg" "IMAGE_NAME=${image_name}")
    BUILD_ARGS+=("--build-arg" "IMAGE_VENDOR=${repo_organization}")
    BUILD_ARGS+=("--build-arg" "ENABLE_DX=${dx}")
    BUILD_ARGS+=("--build-arg" "ENABLE_GDX=${gdx}")
    if [[ -z "$(git status -s)" ]]; then
        BUILD_ARGS+=("--build-arg" "SHA_HEAD_SHORT=$(git rev-parse --short HEAD)")
    fi

    podman build \
        --platform "${platform:-linux/amd64}" \
        "${BUILD_ARGS[@]}" \
        --pull=newer \
        --tag "${target_image}:${tag}" \
        .

# Build locally with rechunking (for testing)
local-build $target_image=image_name $tag=default_tag $dx="0" $gdx="0" $platform="linux/amd64":
    just build $target_image $tag $dx $gdx $platform
    just hhd-rechunk $target_image $tag

# Rechunk image using HHD-Dev rechunker (for advanced users)
hhd-rechunk $image_name="" $default_tag="":
    #!/usr/bin/env bash
    set -euo pipefail

    # Labels
    VERSION="$(podman inspect localhost/$image_name:$default_tag)"
    LABELS="$(podman inspect localhost/$image_name:$default_tag | jq -r '.[].Config.Labels | to_entries | map("\(.key)=\(.value|tostring)")|.[]')"
    CREF=$(podman create localhost/$image_name:$default_tag bash)
    OUT_NAME="$image_name.tar"
    MOUNT="$(podman mount $CREF)"

    podman pull --retry 3 "ghcr.io/hhd-dev/rechunk:v1.2.2"

    podman run --rm \
        --security-opt label=disable \
        --volume "$MOUNT":/var/tree \
        --env TREE=/var/tree \
        --user 0:0 \
        ghcr.io/hhd-dev/rechunk:v1.2.2 \
        /sources/rechunk/1_prune.sh

    podman run --rm \
        --security-opt label=disable \
        --volume "$MOUNT":/var/tree \
        --volume "cache_ostree:/var/ostree" \
        --env TREE=/var/tree \
        --env REPO=/var/ostree/repo \
        --env RESET_TIMESTAMP=1 \
        --user 0:0 \
        ghcr.io/hhd-dev/rechunk:v1.2.2 \
        /sources/rechunk/2_create.sh

    podman unmount "$CREF"
    podman rm "$CREF"

    podman run --rm \
        --security-opt label=disable \
        --volume "{{ builddir / '$variant-$version' }}:/workspace" \
        --volume "{{ justfile_dir() }}:/var/git" \
        --volume cache_ostree:/var/ostree \
        --env REPO=/var/ostree/repo \
        --env LABELS="$LABELS" \
        --env OUT_NAME="$OUT_NAME" \
        --env VERSION="$VERSION" \
        --env VERSION_FN=/workspace/version.txt \
        --env OUT_REF="oci-archive:$OUT_NAME" \
        --env GIT_DIR="/var/git" \
        --user 0:0 \
        ghcr.io/hhd-dev/rechunk:v1.2.2 \
        /sources/rechunk/3_chunk.sh
    podman  volume rm cache_ostree
    {{ if env("CI", "") != "" { 'mv ' + builddir / '$variant-$version/$image_name.tar ' + justfile_dir() / '$image_name.tar' } else { '' } }}

# Parameters:
#   target_image: The name of the image to build (ex. localhost/fedora)
#   tag: The tag of the image to build (ex. latest)
#   type: The type of image to build (ex. qcow2, raw, iso)
#   config: The configuration file to use for the build (default: image.toml)

# Example: just _rebuild-bib localhost/fedora latest qcow2 image.toml
_build-bib $target_image $tag $type $config:
    #!/usr/bin/env bash
    set -euo pipefail

    mkdir -p "output"

    echo "Cleaning up previous build"
    if [[ $type == iso ]]; then
      just rm -rf "output/bootiso" || true
    else
       rm -rf "output/${type}" || true
    fi

    args=" --type ${type}"
    args+=" --use-librepo=False"

    if [[ $type == qcow2 ]]; then
      args+=" --rootfs btrfs"
    fi

    if [[ $target_image == localhost/* ]]; then
      args+=" --local"
    fi

    podman run \
      --rm \
      -it \
      --privileged \
      --pull=newer \
      --net=host \
      --security-opt label=type:unconfined_t \
      -v $(pwd)/${config}:/config.toml:ro \
      -v $(pwd)/output:/output \
      -v /var/lib/containers/storage:/var/lib/containers/storage \
      "${bib_image}" \
      ${args} \
      "${target_image}:${tag}"

    chown -R $USER:$USER output

# Podman build's the image from the Containerfile and creates a bootable image
# Parameters:
#   target_image: The name of the image to build (ex. localhost/fedora)
#   tag: The tag of the image to build (ex. latest)
#   type: The type of image to build (ex. qcow2, raw, iso)
#   config: The configuration file to use for the build (deafult: image.toml)

# Example: just _rebuild-bib localhost/fedora latest qcow2 image.toml
_rebuild-bib $target_image $tag $type $config: (build target_image tag) && (_build-bib target_image tag type config)

# Build virtual machine images (qcow2, raw, iso)
[group('Virtual Machine Images')]
build-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: (_build-bib target_image tag "qcow2" "image.toml")

[group('Virtual Machine Images')]
build-raw $target_image=("localhost/" + image_name) $tag=default_tag: (_build-bib target_image tag "raw" "image.toml")

[group('Virtual Machine Images')]
build-iso $target_image=("localhost/" + image_name) $tag=default_tag: (_build-bib target_image tag "iso" "iso.toml")

# Rebuild virtual machine images (builds container first, then VM image)
[group('Virtual Machine Images')]
rebuild-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: (build target_image tag) && (_build-bib target_image tag "qcow2" "image.toml")

[group('Virtual Machine Images')]
rebuild-raw $target_image=("localhost/" + image_name) $tag=default_tag: (build target_image tag) && (_build-bib target_image tag "raw" "image.toml")

[group('Virtual Machine Images')]
rebuild-iso $target_image=("localhost/" + image_name) $tag=default_tag: (build target_image tag) && (_build-bib target_image tag "iso" "iso.toml")

# Run a virtual machine with the specified image type and configuration
_run-vm $target_image $tag $type $config:
    #!/usr/bin/env bash
    set -eoux pipefail

    # Determine the image file based on the type
    image_file="output/${type}/disk.${type}"
    if [[ $type == iso ]]; then
        image_file="output/bootiso/install.iso"
    fi

    # Build the image if it does not exist
    if [[ ! -f "${image_file}" ]]; then
        just "build-${type}" "$target_image" "$tag"
    fi

    # Determine an available port to use
    port=8006
    while grep -q :${port} <<< $(ss -tunalp); do
        port=$(( port + 1 ))
    done
    echo "Using Port: ${port}"
    echo "Connect to http://localhost:${port}"

    # Set up the arguments for running the VM
    run_args=()
    run_args+=(--rm --privileged)
    run_args+=(--pull=newer)
    run_args+=(--publish "127.0.0.1:${port}:8006")
    run_args+=(--env "CPU_CORES=4")
    run_args+=(--env "RAM_SIZE=3G")
    run_args+=(--env "DISK_SIZE=64G")
    run_args+=(--env "TPM=Y")
    run_args+=(--env "GPU=Y")
    run_args+=(--device=/dev/kvm)
    run_args+=(--volume "${PWD}/${image_file}":"/boot.${type}")
    run_args+=(docker.io/qemux/qemu)

    # Run the VM and open the browser to connect
    podman run "${run_args[@]}" &
    xdg-open http://localhost:${port}
    fg "%podman"

# Run virtual machine from built images
[group('Virtual Machine')]
run-vm-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: (_run-vm target_image tag "qcow2" "image.toml")

[group('Virtual Machine')]
run-vm-raw $target_image=("localhost/" + image_name) $tag=default_tag: (_run-vm target_image tag "raw" "image.toml")

[group('Virtual Machine')]
run-vm-iso $target_image=("localhost/" + image_name) $tag=default_tag: (_run-vm target_image tag "iso" "iso.toml")

# Run VM using systemd-vmspawn (alternative to QEMU)
[group('Virtual Machine')]
spawn-vm rebuild="0" type="qcow2" ram="6G":
    #!/usr/bin/env bash
    set -euo pipefail

    [ "{{ rebuild }}" -eq 1 ] && echo "Rebuilding the image" && just build-{{ type }} localhost/{{ image_name }} {{ default_tag }}

    systemd-vmspawn \
      -M "yellowfin-vm" \
      --console=gui \
      --cpus=2 \
      --ram=$(echo {{ ram }}| /usr/bin/numfmt --from=iec) \
      --network-user-mode \
      --vsock=false --pass-ssh-key=false \
      -i ./output/**/*.{{ type }}

# Advanced ISO customization (run osbuild manually)
[group('Advanced')]
customize-iso-build:
    podman run \
    --rm -it \
    --privileged \
    --pull=newer \
    --net=host \
    --security-opt label=type:unconfined_t \
    -v $(pwd)/iso.toml:/config.toml:ro \
    -v $(pwd)/output:/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    --entrypoint "" \
    "${bib_image}" \
    osbuild --store /store --output-directory /output /output/manifest-iso.json --export bootiso

##########################
#  'patch-iso-branding'  #
##########################
# Description:
# creates a custom branded ISO image. As per https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/7/html/anaconda_customization_guide/sect-iso-images#sect-product-img
# Parameters:
#   override: A flag to determine if the final ISO should replace the original ISO (default is 0).
#   iso_path: The path to the original ISO file.
# Runs a Podman container with Fedora image. Installs 'lorax' and 'mkksiso' tools inside the container. Creates a compressed 'product.img'
# from the Brnading images in the 'iso_files' directory. Uses 'mkksiso' to add the 'product.img' to the original ISO and creates 'final.iso'
# in the output directory. If 'override' is not 0, replaces the original ISO with the newly created 'final.iso'.

# applies custom branding to an ISO image.
patch-iso-branding override="0" iso_path="output/bootiso/install.iso":
    #!/usr/bin/env bash
    podman run \
        --rm \
        -it \
        --pull=newer \
        --privileged \
        -v ./output:/output \
        -v ./iso_files:/iso_files \
        quay.io/centos/centos:stream10 \
        bash -c 'dnf install -y lorax && \
    	mkdir /images && cd /iso_files/product && find . | cpio -c -o | gzip -9cv > /images/product.img && cd / \
            && mkksiso --add images --volid yellowfin-boot /{{ iso_path }} /output/final.iso'

    if [ {{ override }} -ne 0 ] ; then
        mv output/final.iso {{ iso_path }}
    fi

# Runs shell check on all Bash scripts
lint:
    /usr/bin/find . -iname "*.sh" -type f -exec shellcheck "{}" ';'

# Runs shfmt on all Bash scripts
format:
    /usr/bin/find . -iname "*.sh" -type f -exec shfmt --write "{}" ';'

run-bootc-libvirt $target_image=("localhost/" + image_name) $tag=default_tag $image_name=image_name:
    #!/usr/bin/env bash
    set -euo pipefail

    mkdir -p "output/"

    # clean up previous builds
    echo "Cleaning up previous build"
    if rm -rf "output/${image_name}_${tag}.raw" || true
    mkdir -p "output/"

     # build the disk image
    truncate -s 20G output/${image_name}_${tag}.raw
    # if podman run \
    # --rm --privileged \
    # -v /var/lib/containers:/var/lib/containers \
    # quay.io/centos-bootc/centos-bootc:stream10 \
    # /usr/libexec/bootc-base-imagectl rechunk \
    # ${target_image}:${tag} ${target_image}:re${tag}
    if podman run \
    --pid=host --network=host --privileged \
    --security-opt label=type:unconfined_t \
    -v $(pwd)/output:/output:Z \
    ${target_image}:${tag} bootc install to-disk --via-loopback --generic-image /output/${image_name}_${tag}.raw
    QEMU_DISK_QCOW2=$(pwd)/output/${image_name}_${tag}.raw
    # Run the VM using QEMU
    echo "Running VM with QEMU using disk: ${QEMU_DISK_QCOW2}"
    # Ensure the disk file exists
    if [[ ! -f "${QEMU_DISK_QCOW2}" ]]; then
        echo "Disk file ${QEMU_DISK_QCOW2} does not exist. Please build the image first."
        exit 1
    fi
    virt-install --os-variant almalinux9 --boot hd \
        --name "${image_name}-${tag}" \
        --memory 2048 \
        --vcpus 2 \
        --disk path="${QEMU_DISK_QCOW2}",format=raw,bus=scsi,discard=unmap \
        --network bridge=virbr0,model=virtio \
        --console pty,target_type=virtio \
        --noautoconsole
