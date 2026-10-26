#!/usr/bin/env bash
# Manage all GeoServer Cloud components in the currently selected OpenShift project.
#
# Run from the repository root with Bash, an authenticated oc CLI, and permission
# to read Deployments and manage Deployments, Services, and HPAs.
#   ./scripts/manage-geoserver.sh deploy
#   ./scripts/manage-geoserver.sh remove
#
# The shared default is in geoserver-version.env; an environment override is
# exported to every child. One confirmation authorizes all child operations.
# deploy applies in place and waits for each rollout; remove deletes application
# resources, not the PostgreSQL catalog, RabbitMQ, Secrets, or reverse proxy.
#
# Before a version upgrade, back up the catalog and test the exact version pair
# in staging. Old/new pods share the catalog and RabbitMQ events, so rolling
# replacement is safe only when schema and event formats are compatible.
# Pause configuration writes unless mixed-version writes are supported.
# A failure stops subsequent scripts but does not undo completed changes or stop
# an ongoing rollout. Image rollback does not reverse database migrations.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/geoserver-version.env"

# ----------------------------
# Scripts to run
# ----------------------------
# Preserve the bootstrap order and upgrade the gateway after its backends.
# Release-specific migration instructions may require a different sequence.
SCRIPTS=(
    "./scripts/manage-geoserver-webui.sh"
    "./scripts/manage-geoserver-wfs.sh"
    "./scripts/manage-geoserver-wms.sh"
    "./scripts/manage-geoserver-rest.sh"
    "./scripts/manage-geoserver-gateway.sh"
)

# ----------------------------
# Verify argument
# ----------------------------
ACTION="${1:-}"
case "${ACTION}" in
    deploy|remove) ;;
    *)
        echo "USAGE: $(basename "$0") <deploy|remove>" >&2
        exit 1
        ;;
esac

if [[ ! "${GEOSERVER_CLOUD_VERSION}" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]]; then
    echo ">>> ERROR: GEOSERVER_CLOUD_VERSION must be a valid image tag" >&2
    exit 1
fi

# Fail before changing any workload if the complete script set is unavailable.
for SCRIPT in "${SCRIPTS[@]}"; do
    if [[ ! -x "${SCRIPT}" ]]; then
        echo ">>> ERROR: ${SCRIPT} not found or not executable" >&2
        exit 1
    fi
done

# ----------------------------
# Get current project
# ----------------------------
PROJ=$(oc project -q)

# ----------------------------
# Confirm action
# ----------------------------
echo
echo "========================================"
echo " Action:  ${ACTION}"
echo " App:     ogs-geoserver (all)"
echo " Project: ${PROJ}"
echo " Version: ${GEOSERVER_CLOUD_VERSION}"
echo " Scripts: ${#SCRIPTS[@]}"
echo "========================================"
echo
read -r -p "Continue with all scripts? [y/N]: " CONFIRM
case "${CONFIRM:-N}" in
  [yY]|[yY][eE][sS])
    echo ">>> Proceeding..."
    ;;
  *)
    echo ">>> Cancelled"
    exit 0
    ;;
esac

# ----------------------------
# Run scripts
# ----------------------------
for SCRIPT in "${SCRIPTS[@]}"; do
    echo
    echo ">>> Running ${SCRIPT} ${ACTION}"
    # The operator already confirmed the full operation; answer each child prompt.
    if ! printf 'Y\n' | "${SCRIPT}" "${ACTION}"; then
        echo ">>> ERROR: ${SCRIPT} failed; stopping ${ACTION}" >&2
        exit 1
    fi
done

# ----------------------------
# Final status
# ----------------------------
echo
echo ">>> ALL scripts completed successfully!"
echo
