export repo_organization := env("GITHUB_REPOSITORY_OWNER", "ublue-os")
export image_name := env("IMAGE_NAME", "bluefin")
export centos_version := env("CENTOS_VERSION", "10")
export default_tag := env("DEFAULT_TAG", "a10s")
export bib_image := env("BIB_IMAGE", "quay.io/centos-bootc/bootc-image-builder:latest")

alias build-vm := build-qcow2
alias rebuild-vm := rebuild-qcow2
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

# Clean Repo
[group('Utility')]
clean:
    #!/usr/bin/env bash
    set -eoux pipefail
    touch _build
    find *_build* -exec rm -rf {} \;
    rm -f previous.manifest.json
    rm -f changelog.md
    rm -f output.env

# Sudo Clean Repo
[group('Utility')]
[private]
sudo-clean:
    just sudoif just clean

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
    sudoif {{ command }} {{ args }}

# This Justfile recipe builds a container image using Podman.
#
# Arguments:
#   $target_image - The tag you want to apply to the image (default: bluefin).
#   $tag - The tag for the image (default: lts).
#   $dx - Enable DX (default: "0").
#   $gdx - Enable GDX (default: "0").
#
# DX:
#   Developer Experience (DX) is a feature that allows you to install the latest developer tools for your system.
#   Packages include VScode, Docker, Distrobox, and more.
# GDX: https://docs.projectbluefin.io/gdx/
#   GPU Developer Experience (GDX) creates a base as an AI and Graphics platform.
#   Installs Nvidia drivers, CUDA, and other tools.
#
# The script constructs the version string using the tag and the current date.
# If the git working directory is clean, it also includes the short SHA of the current HEAD.
#
# just build $target_image $tag $dx $gdx
#
# Example usage:
#   just build bluefin lts 1 0
#
# This will build an image 'bluefin:a10s' with DX and GDX enabled.
#

# Build the image using the specified parameters
rechunk $target_image=image_name $tag=default_tag: (_rootful_load_image target_image tag)
    #!/usr/bin/env bash
    set -euo pipefail

    full_image_ref_input="${target_image}:${tag}"
    image_id=""
    actual_image_ref="" 

    echo "INFO: Checking for rootful image: ${full_image_ref_input}..."
    inspect_output=$(just sudoif podman inspect -t image "${full_image_ref_input}" 2>/dev/null)
    if [[ $? -eq 0 && -n "$inspect_output" ]]; then
        echo "INFO: Found rootful image as: ${full_image_ref_input}"
        image_id=$(echo "$inspect_output" | jq -r '.[0].Id') # Get the specific ID
        actual_image_ref="${full_image_ref_input}"
    else
        if [[ "${target_image}" != */* ]]; then
            local_prefixed_ref="localhost/${target_image}:${tag}"
            echo "INFO: Checking for rootful image: ${local_prefixed_ref}..."
            inspect_output_localhost=$(just sudoif podman inspect -t image "${local_prefixed_ref}" 2>/dev/null)
            if [[ $? -eq 0 && -n "$inspect_output_localhost" ]]; then
                echo "INFO: Found rootful image as: ${local_prefixed_ref}"
                image_id=$(echo "$inspect_output_localhost" | jq -r '.[0].Id')
                actual_image_ref="${local_prefixed_ref}"
            fi
        fi
    fi

    if [[ -z "$image_id" ]]; then
        echo "INFO: Image not found locally. Attempting to pull rootful image: ${full_image_ref_input}..."
        if just sudoif podman pull "${full_image_ref_input}"; then
            echo "INFO: Successfully pulled rootful image: ${full_image_ref_input}"
            inspect_output_pulled=$(just sudoif podman inspect -t image "${full_image_ref_input}")
            if [[ $? -eq 0 && -n "$inspect_output_pulled" ]]; then
                image_id=$(echo "$inspect_output_pulled" | jq -r '.[0].Id')
                actual_image_ref="${full_image_ref_input}"
            else
                echo "ERROR: Pulled image ${full_image_ref_input} but could not inspect it afterwards."
                exit 1
            fi
        else
            echo "ERROR: Failed to find or pull rootful image: ${full_image_ref_input}"
            exit 1
        fi
    fi

    if [[ -z "$image_id" ]]; then
        echo "ERROR: Image ${full_image_ref_input} could not be reliably found or pulled into rootful storage."
        exit 1
    fi


    temp_tag_name_part="unchunked-${target_image}:${tag}"  
    fully_qualified_temp_tag="localhost/${temp_tag_name_part}"

    just sudoif podman rmi "${fully_qualified_temp_tag}" >/dev/null 2>&1 || true

    if ! just sudoif podman tag "${actual_image_ref}" "${fully_qualified_temp_tag}"; then
        echo "ERROR: Failed to tag ${actual_image_ref} as ${fully_qualified_temp_tag}. Aborting."
        exit 1
    fi

    if ! just sudoif podman run \
        --rm --privileged --security-opt label=disable \
        -v /var/lib/containers:/var/lib/containers:Z \
        quay.io/centos-bootc/centos-bootc:stream10 \
        /usr/libexec/bootc-base-imagectl rechunk \
        "${fully_qualified_temp_tag}" "${actual_image_ref}"; then
        echo "INFO: removing temporary tag ${fully_qualified_temp_tag}."
        just sudoif podman rmi "${fully_qualified_temp_tag}" >/dev/null 2>&1 || true
        exit 1
    fi


    just sudoif podman rmi "${fully_qualified_temp_tag}" >/dev/null 2>&1 || true
    echo "INFO: Successfully rechunked image ${actual_image_ref}"
    just sudoif podman inspect "${actual_image_ref}" --format "'{{ '{{.ID}}' }}'" | xargs -I {} echo "INFO: Image ID: {}"
    # Unload an image from rootful podman
    just _rootful_unload_image ${target_image} ${tag}

build $target_image=image_name $tag=default_tag $dx="0" $gdx="0":
    #!/usr/bin/env bash

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
        "${BUILD_ARGS[@]}" \
        --pull=newer \
        --tag "${target_image}:${tag}" \
        .

# Command: _rootful_load_image
# Description: This script checks if the current user is root or running under sudo. If not, it attempts to resolve the image tag using podman inspect.
#              If the image is found, it loads it into rootful podman. If the image is not found, it pulls it from the repository.
#
# Parameters:
#   $target_image - The name of the target image to be loaded or pulled.
#   $tag - The tag of the target image to be loaded or pulled. Default is 'default_tag'.
#
# Example usage:
#   _rootful_load_image my_image latest
#
# Steps:
# 1. Check if the script is already running as root or under sudo.
# 2. Check if target image is in the non-root podman container storage)
# 3. If the image is found, load it into rootful podman using podman scp.
# 4. If the image is not found, pull it from the remote repository into reootful podman.

_rootful_load_image $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -eou pipefail

    # Check if already running as root or under sudo
    if [[ -n "${SUDO_USER:-}" || "${UID}" -eq "0" ]]; then
        echo "Already root or running under sudo, no need to load image from user podman."
        exit 0
    fi
    function copy_image_from_user_to_root() {
        local target_image="$1"
        local tag="$2"
        COPYTMP=$(mktemp -p "${PWD}" -d -t _build_podman_scp.XXXXXXXXXX)
        just sudoif TMPDIR=${COPYTMP} podman image scp ${UID}@localhost::"${target_image}:${tag}" root@localhost::"${target_image}:${tag}"
        rm -rf "${COPYTMP}"
    }

    # Try to resolve the image tag using podman inspect
    set +e
    resolved_tag=$(podman inspect -t image "${target_image}:${tag}" | jq -r '.[].RepoTags.[0]')
    return_code=$?
    set -e

    if [[ $return_code -eq 0 ]]; then
        # If the image is found, load it into rootful podman
        SID=$(podman images --filter reference="${target_image}:${tag}" --format "'{{ '{{.ID}}' }}'")
        DID=$(just sudoif podman images --filter reference="${target_image}:${tag}" --format "'{{ '{{.ID}}' }}'")
        echo "Image found in user podman: ${SID}"
        echo "Image found in root podman: ${DID}"
        if [[ -z "$SID" ]]; then
            echo "Image not found in user podman, skipping load."
            exit 0
        fi
        if [[ "$SID" == "$DID" ]]; then
            echo "Image IDs match, skipping copy."
            exit 0
        fi
        if [[ "$SID" != "$DID" ]]; then
            echo "Image IDs do not match, deleting ${DID} and copying image from user podman to root podman..."
            just sudoif podman rmi "${target_image}:${tag}" || true
            copy_image_from_user_to_root "$target_image" "$tag"
        fi

        if [[ -z "$DID" ]]; then
           copy_image_from_user_to_root "$target_image" "$tag"
        fi
    else
        # If the image is not found, pull it from the repository
        echo "Image not found locally, pulling from repository..."
        just sudoif podman pull "${target_image}:${tag}"
    fi

_rootful_unload_image $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -eou pipefail


    function copy_image_from_root_to_user() {
        local target_image="$1"
        local tag="$2"
        COPYTMP=$(mktemp -p "${PWD}" -d -t _build_podman_scp.XXXXXXXXXX)
        just sudoif TMPDIR=${COPYTMP} podman image scp root@localhost::"${target_image}:${tag}" ${UID}@localhost::"${target_image}:${tag}"
        rm -rf "${COPYTMP}"
    }


    # Check if already running as root or under sudo
    if [[ -n "${SUDO_USER:-}" || "${UID}" -eq "0" ]]; then
        echo "Already root or running under sudo, no need to load image from user podman."
        exit 0
    fi

    # Try to resolve the image tag using podman inspect
    set +e
    resolved_tag=$(just sudoif podman inspect -t image "${target_image}:${tag}" | jq -r '.[].RepoTags.[0]')
    return_code=$?
    set -e

    if [[ $return_code -eq 0 ]]; then
        # If the image is found, load it into rootful podman
        SID=$(just sudoif podman images --filter reference="${target_image}:${tag}" --format "'{{ '{{.ID}}' }}'")
        DID=$(podman images --filter reference="${target_image}:${tag}" --format "'{{ '{{.ID}}' }}'")
        echo "Image found in root podman: ${SID}"
        echo "Image found in user podman: ${DID}"
        # compare the image IDs if thry are the same skip the copy if they are not the same remove the image from user podman
        if [[ -z "$SID" ]]; then
            echo "Image not found in root podman, skipping unload."
            exit 0
        fi
        if [[ "$SID" == "$DID" ]]; then
            echo "Image IDs match, skipping copy."
            exit 0
        fi
        # if the image IDs do not match, copy the image from root podman to user podman
        if [[ "$SID" != "$DID" ]]; then
            echo "Image IDs do not match, deleting ${DID} and copying image from root podman to user podman..."
            podman rmi "${target_image}:${tag}" || true
            copy_image_from_root_to_user "$target_image" "$tag"
        fi
        if [[ -z "$DID" ]]; then
            # If the image ID is not found, copy the image from user podman to root podman
            copy_image_from_root_to_user "$target_image" "$tag"

        fi
    else
        # If the image is not found, pull it from the repository
        podman pull "${target_image}:${tag}"
    fi

# Build a bootc bootable image using Bootc Image Builder (BIB)
# Converts a container image to a bootable image
# Parameters:
#   target_image: The name of the image to build (ex. localhost/fedora)
#   tag: The tag of the image to build (ex. latest)
#   type: The type of image to build (ex. qcow2, raw, iso)
#   config: The configuration file to use for the build (default: image.toml)

# Example: just _rebuild-bib localhost/fedora latest qcow2 image.toml
_build-bib $target_image $tag $type $config: (_rootful_load_image target_image tag)
    #!/usr/bin/env bash
    set -euo pipefail

    mkdir -p "output"

    echo "Cleaning up previous build"
    if [[ $type == iso ]]; then
      sudo rm -rf "output/bootiso" || true
    else
      sudo rm -rf "output/${type}" || true
    fi

    args="--type ${type} "
    args+="--use-librepo=True"

    sudo podman run \
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

    sudo chown -R $USER:$USER output

# Podman build's the image from the Containerfile and creates a bootable image
# Parameters:
#   target_image: The name of the image to build (ex. localhost/fedora)
#   tag: The tag of the image to build (ex. latest)
#   type: The type of image to build (ex. qcow2, raw, iso)
#   config: The configuration file to use for the build (deafult: image.toml)

# Example: just _rebuild-bib localhost/fedora latest qcow2 image.toml
_rebuild-bib $target_image $tag $type $config: (build target_image tag) && (_build-bib target_image tag type config)

# Build a QCOW2 virtual machine image
[group('Build Virtal Machine Image')]
build-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "qcow2" "image.toml")

# Build a RAW virtual machine image
[group('Build Virtal Machine Image')]
build-raw $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "raw" "image.toml")

# Build an ISO virtual machine image
[group('Build Virtal Machine Image')]
build-iso $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "iso" "iso.toml")

# Rebuild a QCOW2 virtual machine image
[group('Build Virtal Machine Image')]
rebuild-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: && (_rebuild-bib target_image tag "qcow2" "image.toml")

# Rebuild a RAW virtual machine image
[group('Build Virtal Machine Image')]
rebuild-raw $target_image=("localhost/" + image_name) $tag=default_tag: && (_rebuild-bib target_image tag "raw" "image.toml")

# Rebuild an ISO virtual machine image
[group('Build Virtal Machine Image')]
rebuild-iso $target_image=("localhost/" + image_name) $tag=default_tag: && (_rebuild-bib target_image tag "iso" "iso.toml")

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

# Run a virtual machine from a QCOW2 image
[group('Run Virtal Machine')]
run-vm-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: && (_run-vm target_image tag "qcow2" "image.toml")

# Run a virtual machine from a RAW image
[group('Run Virtal Machine')]
run-vm-raw $target_image=("localhost/" + image_name) $tag=default_tag: && (_run-vm target_image tag "raw" "image.toml")

# Run a virtual machine from an ISO
[group('Run Virtal Machine')]
run-vm-iso $target_image=("localhost/" + image_name) $tag=default_tag: && (_run-vm target_image tag "iso" "iso.toml")

# Run a virtual machine using systemd-vmspawn
[group('Run Virtal Machine')]
spawn-vm rebuild="0" type="qcow2" ram="6G":
    #!/usr/bin/env bash

    set -euo pipefail

    [ "{{ rebuild }}" -eq 1 ] && echo "Rebuilding the ISO" && just build-vm {{ rebuild }} {{ type }}

    systemd-vmspawn \
      -M "achillobator" \
      --console=gui \
      --cpus=2 \
      --ram=$(echo {{ ram }}| /usr/bin/numfmt --from=iec) \
      --network-user-mode \
      --vsock=false --pass-ssh-key=false \
      -i ./output/**/*.{{ type }}

##########################
#  'customize-iso-build' #
##########################
# Description:
# Enables the manual customization of the osbuild manifest before running the ISO build
#
# Mount the configuration file and output directory
# Clear the entrypoint to run the custom command

# Run osbuild with the specified parameters
customize-iso-build:
    sudo podman run \
    --rm -it \
    --privileged \
    --pull=newer \
    --net=host \
    --security-opt label=type:unconfined_t \
    -v $(pwd)/iso.toml \
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
            && mkksiso --add images --volid bluefin-boot /{{ iso_path }} /output/final.iso'

    if [ {{ override }} -ne 0 ] ; then
        mv output/final.iso {{ iso_path }}
    fi

# Runs shell check on all Bash scripts
lint:
    /usr/bin/find . -iname "*.sh" -type f -exec shellcheck "{}" ';'

# Runs shfmt on all Bash scripts
format:
    /usr/bin/find . -iname "*.sh" -type f -exec shfmt --write "{}" ';'

run-bootc-libvirt $target_image=("localhost/" + image_name) $tag=default_tag $image_name=image_name: (_rootful_load_image target_image tag)
    #!/usr/bin/env bash
    set -euo pipefail

    mkdir -p "output/"

    # clean up previous builds
    echo "Cleaning up previous build"
    just sudoif rm -rf "output/${image_name}_${tag}.raw" || true
    mkdir -p "output/"

     # build the disk image
    truncate -s 20G output/${image_name}_${tag}.raw
    # just sudoif podman run \
    # --rm --privileged \
    # -v /var/lib/containers:/var/lib/containers \
    # quay.io/centos-bootc/centos-bootc:stream10 \
    # /usr/libexec/bootc-base-imagectl rechunk \
    # ${target_image}:${tag} ${target_image}:re${tag}
    just sudoif podman run \
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
    sudo virt-install --os-variant almalinux9 --boot hd \
        --name "${image_name}-${tag}" \
        --memory 2048 \
        --vcpus 2 \
        --disk path="${QEMU_DISK_QCOW2}",format=raw,bus=scsi,discard=unmap \
        --network bridge=virbr0,model=virtio \
        --console pty,target_type=virtio \
        --noautoconsole
