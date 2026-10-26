#!/usr/bin/env bash
# Restart the existing stack without building images or applying version changes.
# Usage: bash scripts/restart-rollouts.sh
# Requires an authenticated oc CLI and all seven Deployments in the current project.
# RabbitMQ restarts first so fresh GeoServer clients can recreate subscriptions.
# Backends restart before the gateway, and the public reverse proxy restarts last.
# Each rollout must finish before the next starts; existing strategies are retained.
# WARNING: The single, non-persistent RabbitMQ broker interrupts connections and
# can lose queues/messages on replacement. This is not a zero-downtime operation.
# GeoServer readiness does not guarantee working RabbitMQ event subscriptions;
# verify application requests and queue consumers after completion.
# Failure stops subsequent restarts but does not cancel or undo an active rollout.
set -euo pipefail

if [[ $# -ne 0 ]]; then
    echo "USAGE: bash $(basename "$0")" >&2
    exit 1
fi

PROJ=$(oc project -q)
if [[ -z "${PROJ}" ]]; then
    echo ">>> ERROR: No OpenShift project selected" >&2
    exit 1
fi

DEPLOYMENTS=(
    "ogs-rabbitmq"
    "ogs-geoserver-webui"
    "ogs-geoserver-wfs"
    "ogs-geoserver-wms"
    "ogs-geoserver-rest"
    "ogs-geoserver-gateway"
    "ogs-rproxy"
)

# Pin every operation to this project, even if the CLI context changes.
echo ">>> Checking deployments in ${PROJ}..."
for APP in "${DEPLOYMENTS[@]}"; do
    if ! oc -n "${PROJ}" get deployment "${APP}" -o name; then
        echo ">>> ERROR: Cannot read deployment/${APP}; no restarts requested" >&2
        exit 1
    fi
done

echo
echo "========================================"
echo " Action:  Restart all stack rollouts"
echo " Project: ${PROJ}"
echo " Order:"
printf '   %s\n' "${DEPLOYMENTS[@]}"
echo "========================================"
echo " WARNING: RabbitMQ replacement interrupts connections and can lose"
echo " broker state/messages. WebUI sessions and requests may be affected."
echo " Images are not rebuilt or changed by this script."
echo
read -r -p "Restart all deployments? [y/N]: " CONFIRM
case "${CONFIRM:-N}" in
    [yY]|[yY][eE][sS]) ;;
    *)
        echo ">>> Cancelled"
        exit 0
        ;;
esac

for APP in "${DEPLOYMENTS[@]}"; do
    echo
    echo ">>> Restarting ${APP}..."
    if ! oc -n "${PROJ}" rollout restart deployment/"${APP}"; then
        echo ">>> ERROR: Could not request restart of ${APP}; stopping" >&2
        exit 1
    fi
    if ! oc -n "${PROJ}" rollout status deployment/"${APP}" --timeout=600s; then
        echo ">>> ERROR: ${APP} rollout failed; no subsequent restarts requested" >&2
        echo ">>> The rollout may still be running. Inspect it with:" >&2
        echo "oc -n ${PROJ} describe deployment ${APP}" >&2
        echo "oc -n ${PROJ} get pods -l app=${APP} -o wide" >&2
        echo ">>> Read logs from the specific failing pod, not an arbitrary deployment pod." >&2
        exit 1
    fi
done

echo
echo ">>> COMPLETE - All seven deployment rollouts finished in ${PROJ}."
echo ">>> Verify WMS/WFS requests, WebUI, and RabbitMQ queue consumers."
