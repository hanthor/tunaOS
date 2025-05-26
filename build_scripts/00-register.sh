#!/bin/bash
# Purpose: Register the RHEL system using credentials from environment variables.
set -e # Exit immediately if a command exits with a non-zero status.

echo "INFO: [00-register.sh] Starting RHEL registration process..."

# Validate that necessary credential environment variables are set
if [[ -n "$RH_ACTIVATION_KEY" && -n "$RH_ORG_ID" ]]; then
    echo "INFO: [00-register.sh] Using Activation Key and Organization ID for registration."
    REG_COMMAND="subscription-manager register --org=\"$RH_ORG_ID\" --activationkey=\"$RH_ACTIVATION_KEY\" --force"
elif [[ -n "$RH_USERNAME" && -n "$RH_PASSWORD" ]]; then
    echo "INFO: [00-register.sh] Using Username and Password for registration."
    REG_COMMAND="subscription-manager register --username=\"$RH_USERNAME\" --password=\"$RH_PASSWORD\" --force"
else
    echo "ERROR: [00-register.sh] Missing required RHEL subscription credentials."
    echo "Please ensure RH_ORG_ID & RH_ACTIVATION_KEY (or RH_USERNAME & RH_PASSWORD) are set as environment variables."
    exit 1
fi

# Register the system
if ! eval "$REG_COMMAND"; then
    echo "ERROR: [00-register.sh] RHEL subscription registration failed."
    exit 1
fi
echo "INFO: [00-register.sh] System registered successfully."

# Attempt to attach subscriptions if not handled by --auto-attach or activation key
echo "INFO: [00-register.sh] Attempting to attach subscriptions..."
if ! subscription-manager attach --auto; then
    # This might not be a fatal error if basic repos are already available via the key/org.
    echo "WARNING: [00-register.sh] 'subscription-manager attach --auto' reported issues or no new entitlements found. Continuing..."
fi

# Optional: Enable specific repositories if your activation key/org setup doesn't do it by default
# Ensure these repo names are correct for your RHEL version (e.g., rhel10)
# MAJOR_VERSION is available from the Containerfile ARG
# REPO_VERSION_ARCH_PART="${MAJOR_VERSION:-10}-for-$(uname -m)" # uname -m will give x86_64 or aarch64
# subscription-manager repos \
#    --enable="rhel-${REPO_VERSION_ARCH_PART}-baseos-rpms" \
#    --enable="rhel-${REPO_VERSION_ARCH_PART}-appstream-rpms"

echo "INFO: [00-register.sh] RHEL Registration and initial setup complete."