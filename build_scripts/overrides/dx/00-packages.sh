#!/bin/bash

set -xeuo pipefail

# Function to handle errors and exit
handle_error() {
    local exit_code=$?
    local cmd="$BASH_COMMAND"
    echo "ERROR: Command '$cmd' failed with exit code $exit_code." >&2
    exit "$exit_code"
}
trap 'handle_error' ERR

# Install required packages
echo "Installing DNF packages..."
dnf install -y \
    python3-ramalama

# VSCode on the base image!
echo "Adding VSCode repo and installing code..."
dnf config-manager --add-repo "https://packages.microsoft.com/yumrepos/vscode" || echo "VSCode repo already added or failed to add."
dnf config-manager --set-disabled packages.microsoft.com_yumrepos_vscode || true # Disable if it's already enabled
dnf -y --enablerepo packages.microsoft.com_yumrepos_vscode --nogpgcheck install code

# Docker setup
echo "Adding Docker repo and installing Docker components..."
dnf config-manager --add-repo "https://download.docker.com/linux/centos/docker-ce.repo" || echo "Docker repo already added or failed to add."
dnf config-manager --set-disabled docker-ce-stable || true # Disable if it's already enabled
dnf -y --enablerepo docker-ce-stable install \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

# Libvirt setup
echo "Installing Libvirt related packages..."
dnf -y --enablerepo copr:copr.fedorainfracloud.org:ublue-os:packages install \
    libvirt \
    libvirt-daemon-kvm \
    libvirt-nss \
    cockpit-machines \
    virt-install \
    ublue-os-libvirt-workarounds

# --- Kubernetes and related tools download and verification ---

DEFAULT_RETRY=5 # Increased retry count for network operations
RETRY_DELAY=5   # Delay between retries in seconds

# Function to get latest GitHub release tag
get_latest_github_release() {
    local repo="$1"
    local version=""
    for i in $(seq 1 "${DEFAULT_RETRY}"); do
        echo "Attempt ${i}/${DEFAULT_RETRY}: Fetching latest release for ${repo}..."
        version=$(curl -s -L "https://api.github.com/repos/${repo}/releases/latest" | jq -r .tag_name)
        if [[ -n "$version" && "$version" != "null" ]]; then
            echo "Found latest version for ${repo}: ${version}"
            echo "$version"
            return 0
        fi
        echo "Warning: Could not get latest version for ${repo}. Retrying in ${RETRY_DELAY} seconds..."
        sleep "${RETRY_DELAY}"
    done
    echo "ERROR: Failed to get latest release for ${repo} after multiple attempts." >&2
    exit 1
}

# Get versions with robust fetching
STABLE_KUBE_VERSION="$(get_latest_github_release kubernetes/kubernetes)"
STABLE_KUBE_VERSION_MAJOR="${STABLE_KUBE_VERSION%.*}" # This assumes vX.Y.Z format

KIND_LATEST_VERSION="$(get_latest_github_release kubernetes-sigs/kind)"
KZERO_LATEST_VERSION="$(get_latest_github_release k0sproject/k0s)"
KZEROCTL_LATEST_VERSION="$(get_latest_github_release k0sproject/k0sctl)"


GITHUB_LIKE_ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')"

KUBE_TMP="$(mktemp -d)"
echo "Temporary directory: ${KUBE_TMP}"
trap "echo 'Cleaning up temporary directory: ${KUBE_TMP}'; rm -rf ${KUBE_TMP}" EXIT

KIND_BIN_NAME="kind-linux-${GITHUB_LIKE_ARCH}"

pushd "${KUBE_TMP}"

# Function to download and verify files
download_and_verify() {
    local url="$1"
    local output_file="$2"
    local checksum_url="$3"
    local checksum_file="$4"
    local expected_checksum_line="$5" # For files that have a specific line in a shared checksum file

    echo "Attempting to download ${output_file} from ${url}"
    for i in $(seq 1 "${DEFAULT_RETRY}"); do
        curl --retry "${DEFAULT_RETRY}" --retry-delay "${RETRY_DELAY}" -Lo "${output_file}" "${url}" && break
        echo "Warning: Download of ${output_file} failed. Retrying in ${RETRY_DELAY} seconds..."
        sleep "${RETRY_DELAY}"
        if [ "$i" -eq "$DEFAULT_RETRY" ]; then
            echo "ERROR: Failed to download ${output_file} after multiple attempts." >&2
            exit 1
        fi
    done

    # Download checksum file if provided
    if [[ -n "$checksum_url" && -n "$checksum_file" ]]; then
        echo "Attempting to download checksum file ${checksum_file} from ${checksum_url}"
        for i in $(seq 1 "${DEFAULT_RETRY}"); do
            curl --retry "${DEFAULT_RETRY}" --retry-delay "${RETRY_DELAY}" -Lo "${checksum_file}" "${checksum_url}" && break
            echo "Warning: Download of ${checksum_file} failed. Retrying in ${RETRY_DELAY} seconds..."
            sleep "${RETRY_DELAY}"
            if [ "$i" -eq "$DEFAULT_RETRY" ]; then
                echo "ERROR: Failed to download ${checksum_file} after multiple attempts." >&2
                exit 1
            fi
        done

        # Verify checksum
        echo "Verifying checksum for ${output_file} using ${checksum_file}..."
        if [[ -n "$expected_checksum_line" ]]; then
            # For checksums where we need to grep a specific line
            if ! grep "${expected_checksum_line}" "${checksum_file}" | grep -v 'sig\|exe' | sha256sum --strict --check; then
                echo "ERROR: Checksum verification failed for ${output_file}." >&2
                exit 1
            fi
        else
            # For standalone checksum files or direct file checksum
            if ! sha256sum --strict --check "${checksum_file}"; then
                echo "ERROR: Checksum verification failed for ${output_file}." >&2
                exit 1
            fi
        fi
    else
        echo "No checksum file provided for ${output_file}. Skipping checksum verification."
    fi
}

# Download and verify Kind
download_and_verify \
    "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_LATEST_VERSION}/${KIND_BIN_NAME}" \
    "${KIND_BIN_NAME}" \
    "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_LATEST_VERSION}/${KIND_BIN_NAME}.sha256sum" \
    "${KIND_BIN_NAME}.sha256sum"

# Download and verify Kubectl
download_and_verify \
    "https://dl.k8s.io/release/${STABLE_KUBE_VERSION}/bin/linux/${GITHUB_LIKE_ARCH}/kubectl" \
    "kubectl" \
    "https://dl.k8s.io/release/${STABLE_KUBE_VERSION}/bin/linux/${GITHUB_LIKE_ARCH}/kubectl.sha256" \
    "kubectl.sha256" \
    "kubectl" # The kubectl.sha256 file typically just contains the checksum and filename

# Download and verify K0sctl
download_and_verify \
    "https://github.com/k0sproject/k0sctl/releases/download/${KZEROCTL_LATEST_VERSION}/k0sctl-linux-${GITHUB_LIKE_ARCH}" \
    "k0sctl-linux-${GITHUB_LIKE_ARCH}" \
    "https://github.com/k0sproject/k0sctl/releases/download/${KZEROCTL_LATEST_VERSION}/checksums.txt" \
    "kzeroctl-checksums.txt" \
    "k0sctl-linux-${GITHUB_LIKE_ARCH}"

# Download and verify K0s
download_and_verify \
    "https://github.com/k0sproject/k0s/releases/download/${KZERO_LATEST_VERSION}/k0s-${KZERO_LATEST_VERSION}-${GITHUB_LIKE_ARCH}" \
    "k0s-${KZERO_LATEST_VERSION}-${GITHUB_LIKE_ARCH}" \
    "https://github.com/k0sproject/k0s/releases/download/${KZERO_LATEST_VERSION}/sha256sums.txt" \
    "kzero-checksums.txt" \
    "k0s-${KZERO_LATEST_VERSION}-${GITHUB_LIKE_ARCH}"


echo "All downloads and verifications successful. Installing binaries..."

install -Dpm0755 "${KIND_BIN_NAME}" "/usr/bin/kind"
install -Dpm0755 "./kubectl" "/usr/bin/kubectl"
install -Dpm0755 "./k0sctl-linux-${GITHUB_LIKE_ARCH}" "/usr/bin/k0sctl"
install -Dpm0755 "./k0s-${KZERO_LATEST_VERSION}-${GITHUB_LIKE_ARCH}" "/usr/bin/k0s"

popd

echo "Script completed successfully!"