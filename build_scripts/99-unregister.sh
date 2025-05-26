#!/bin/bash
# Purpose: Unregister the RHEL system and clean up subscription data.
set -e # Exit on most errors, but be somewhat lenient for cleanup.

echo "INFO: [99-unregister.sh] Starting RHEL unregistration and cleanup process..."

# Check if the system is currently registered to avoid errors if it's not
if subscription-manager status &>/dev/null; then
    echo "INFO: [99-unregister.sh] Unregistering system from RHSM..."
    if ! subscription-manager unregister; then
        echo "WARNING: [99-unregister.sh] Failed to unregister system. Continuing cleanup."
    else
        echo "INFO: [99-unregister.sh] System unregistered successfully."
    fi
else
    echo "INFO: [99-unregister.sh] System does not appear to be registered. Skipping unregistration command."
fi

echo "INFO: [99-unregister.sh] Cleaning subscription-manager data..."
if ! subscription-manager clean; then
    echo "WARNING: [99-unregister.sh] Failed to clean subscription-manager data. Continuing cleanup."
else
    echo "INFO: [99-unregister.sh] Subscription manager data cleaned."
fi

# Further file-level cleanup (like rm -rf /etc/rhsm/*) will be done in the Containerfile's RUN command.
echo "INFO: [99-unregister.sh] Unregistration script tasks complete."