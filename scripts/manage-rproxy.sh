#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Config
# ----------------------------
APP="ogs-rproxy"
REPO="https://github.com/vcschuni/ogs-public.git"

# ----------------------------
# Verify passed arg and show help if required
# ----------------------------
OPTIONS=("deploy" "remove")
ACTION="${1:-}"
if [[ ! " ${OPTIONS[*]} " =~ " ${ACTION} " ]]; then
    echo
    echo "USAGE: $(basename "$0") <${OPTIONS[*]// /|}>"
    echo "EXAMPLE: $(basename "$0") ${OPTIONS[0]}"
    echo
    exit 1
fi

# ----------------------------
# Get current project
# ----------------------------
PROJ=$(oc project -q)

# ----------------------------
# Define hostname
# ----------------------------
SERVICE_HOSTNAME="ogs-${PROJ}.apps.silver.devops.gov.bc.ca"

# ----------------------------
# Confirm action
# ----------------------------
echo
echo "========================================"
echo " Action:            ${ACTION}"
echo " App:               ${APP}"
echo " Project:           ${PROJ}"
echo " Service Hostname:  ${SERVICE_HOSTNAME}"
echo "========================================"
echo
read -r -p "Continue? [y/N]: " CONFIRM
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
# Cleanup
# ----------------------------
echo ">>> Removing old ${APP} resources..."
[[ "${ACTION}" == "remove" ]] && oc delete service -l app="${APP}" --ignore-not-found --wait=true
[[ "${ACTION}" == "remove" ]] && oc delete route "${APP}" --ignore-not-found --wait=true
oc delete bc -l app="${APP}" --ignore-not-found --wait=true
oc delete builds -l app="${APP}" --ignore-not-found --wait=true
oc delete deployment -l app="${APP}" --ignore-not-found --wait=true
oc delete is -l app="${APP}" --ignore-not-found --wait=true
oc delete hpa "${APP}" --ignore-not-found --wait=true

# ----------------------------
# Stop here if remove was requested
# ----------------------------
if [[ "${ACTION}" == "remove" ]]; then
  echo
  echo ">>> Remove completed successfully"
  echo
  exit 0
fi

# ----------------------------
# Import base image
# Needs to match Dockerfile
# ----------------------------
echo ">>> Import base image..."
oc import-image nginx:1.29 \
	--from=docker.io/nginx:1.29 \
	--confirm

# ----------------------------
# Create BuildConfig
# ----------------------------
echo ">>> Creating/updating BuildConfig..."
oc new-build "$REPO" \
  --name="${APP}" \
  --context-dir="compose/${APP}" \
  --strategy=docker \
  --labels=app="${APP}"

# ----------------------------
# Start build
# ----------------------------
echo ">>> Starting build..."
oc start-build "${APP}" --wait

# ----------------------------
# Create Deployment
# ----------------------------
echo ">>> Creating/updating Deployment..."
oc create deployment "${APP}" \
  --image="image-registry.openshift-image-registry.svc:5000/${PROJ}/${APP}:latest" \
  --dry-run=client -o yaml | oc apply -f -
oc label deployment "${APP}" app="${APP}" --overwrite

# ----------------------------
# Set resources and autoscaler
# ----------------------------
oc set resources deployment/"${APP}" --limits=cpu=750m,memory=512Mi --requests=cpu=250m,memory=256Mi
oc autoscale deployment/"${APP}" --min=1 --max=2 --cpu-percent=65

# ----------------------------
# Rollout
# ----------------------------
echo ">>> Waiting for deployment rollout..."
oc rollout status deployment/"${APP}" --timeout=300s

# ----------------------------
# Expose internal service
# ----------------------------
if ! oc get service "${APP}" &>/dev/null; then
  echo ">>> Creating internal service..."
  oc expose deployment "${APP}" \
    --name="${APP}" \
    --port=8080 \
    --labels=app="${APP}" \
    --dry-run=client -o yaml | oc apply -f -
fi

# ----------------------------
# Expose external route
# ----------------------------
if ! oc get route "${APP}" &>/dev/null; then
  echo ">>> Creating external route..."
  oc expose service "${APP}" \
    --name="${APP}" \
    --hostname="${SERVICE_HOSTNAME}"

  echo ">>> Enabling HTTPS..."
  oc patch route "${APP}" -p '{
    "spec": {
      "tls": {
        "termination": "edge",
        "insecureEdgeTerminationPolicy": "Redirect"
      }
    }
  }'
fi

# ----------------------------
# Cleanup builds
# ----------------------------
oc delete builds -l app="${APP}" --ignore-not-found --wait=true

# ----------------------------
# Final status
# ----------------------------
echo
echo ">>> COMPLETE — ${APP} deployed!"
echo
