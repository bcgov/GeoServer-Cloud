#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Config
# ----------------------------
APP="ogs-pgadmin"
REPO="https://github.com/bcgov/GeoServer-Cloud.git"
PVC_SIZE="10Gi"

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
oc delete bc -l app="${APP}" --ignore-not-found --wait=true
oc delete builds -l app="${APP}" --ignore-not-found --wait=true
oc delete deployment -l app="${APP}" --ignore-not-found --wait=true
oc delete is -l app="${APP}" --ignore-not-found --wait=true

# ----------------------------
# Stop here if remove was requested
# ----------------------------
if [[ "${ACTION}" == "remove" ]]; then
	echo ""
	echo ">>> Remove completed successfully"
	echo ""
	exit
fi

# ----------------------------
# Create PVC if it doesn't exist
# ----------------------------
if ! oc get pvc "${APP}-data" &>/dev/null; then
    echo ">>> Creating PVC for data..."
    oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${APP}-data
  labels: 
    app: ${APP} 
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: ${PVC_SIZE}
EOF
	echo ">>> Waiting for PVC to be ready..."
	COUNT=0
	while true; do
		STATUS=$(oc get pvc "${APP}-data" -o jsonpath='{.status.phase}')
		echo "Current status: $STATUS"
		if [[ "$STATUS" == "Bound" ]]; then
			echo ">>> PVC is ready!"
			break
		fi
		sleep 5
		COUNT=$((COUNT+1))
		if [[ $COUNT -ge 30 ]]; then
			echo ">>> Timeout waiting for PVC!"
			exit 1
		fi
	done
else
    echo ">>> PVC ${APP}-data already exists, skipping creation"
fi

# ----------------------------
# Import base image
# Needs to match Dockerfile
# ----------------------------
echo ">>> Import base image..."
oc import-image debian:trixie-slim \
	--from=docker.io/debian:trixie-slim \
	--confirm

# ----------------------------
# Create the build config
# ----------------------------
echo ">>> Creating/updating BuildConfig..."
oc new-build "$REPO" \
	--name="${APP}" \
	--context-dir="compose/${APP}" \
	--strategy=docker \
	--labels=app="${APP}"

# ----------------------------
# Start the build
# ----------------------------
echo ">>> Starting build from repo..."
oc start-build "${APP}" --wait

# ----------------------------
# Create deployment
# ----------------------------
echo ">>> Applying Deployment with new image..."
oc create deployment "${APP}" \
    --image="image-registry.openshift-image-registry.svc:5000/${PROJ}/${APP}:latest" \
    --dry-run=client -o yaml | oc apply -f -
oc label deployment "${APP}" app="${APP}" --overwrite

# Switch deployment style to Recreate to prevent PVC access conflicts
oc patch deployment "${APP}" --type=json -p='[
  {"op":"remove","path":"/spec/strategy/rollingUpdate"},
  {"op":"replace","path":"/spec/strategy/type","value":"Recreate"}
]'

# ----------------------------
# Inject runtime variables
# ----------------------------
oc set env deployment/"${APP}" \
    PGADMIN_SETUP_EMAIL=$(oc get secret ogs-pgadmin -o jsonpath='{.data.PGADMIN_EMAIL}' | base64 --decode) \
    PGADMIN_SETUP_PASSWORD=$(oc get secret ogs-pgadmin -o jsonpath='{.data.PGADMIN_PASSWORD}' | base64 --decode) \
    POSTGRES_PASSWORD=$(oc get secret ogs-postgresql-cluster-pguser-postgres -o jsonpath='{.data.password}' | base64 --decode)

# ----------------------------
# Attach PVC
# ----------------------------
echo ">>> Attaching PVC..."
oc set volume deployment/"${APP}" \
    --add \
	  --name="${APP}-data" \
    --type=pvc \
    --claim-name="${APP}-data" \
    --mount-path=/var/lib/pgadmin

# ----------------------------
# Set resources
# ----------------------------
oc set resources deployment/"${APP}" --limits=cpu=750m,memory=1Gi --requests=cpu=250m,memory=512Mi

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
