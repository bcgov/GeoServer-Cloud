#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Config
# ----------------------------
APP="ogs-geoserver-gateway"
IMAGE="docker.io/geoservercloud/geoserver-cloud-gateway:2.28.2.4"

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
# Confirm action
# ----------------------------
echo
echo "========================================"
echo " Action:            ${ACTION}"
echo " App:               ${APP}"
echo " Project:           ${PROJ}"
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
oc delete deployment -l app="${APP}" --ignore-not-found --wait=true
oc delete hpa "${APP}" --ignore-not-found --wait=true

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
# Create deployment
# ----------------------------
echo ">>> Creating deployment..."
oc create deployment "${APP}" \
    --image="$IMAGE" \
    --dry-run=client -o yaml | oc apply -f -
oc label deployment "${APP}" app="${APP}" --overwrite

# ----------------------------
# Inject runtime variables
# ----------------------------
oc set env deployment/"${APP}" \
	SPRING_PROFILES_ACTIVE=gateway_service,standalone \
	SPRING_WEB_CORS_ALLOWED_ORIGINS=* \
	SPRING_WEB_CORS_ALLOWED_METHODS=GET,POST,PUT,DELETE,OPTIONS,HEAD \
	SPRING_WEB_CORS_ALLOWED_HEADERS=* \
	SPRING_WEB_CORS_ALLOW_CREDENTIALS=true \
    CATALINA_OPTS="-DALLOW_ENV_PARAMETRIZATION=true" \
    JAVA_OPTS="-Xms384m -Xmx768m -XX:+UseG1GC -XX:MaxGCPauseMillis=200"

# ----------------------------
# Set resources and autoscaler
# ----------------------------
oc set resources deployment/"${APP}" --limits=cpu=300m,memory=768Mi --requests=cpu=150m,memory=512Mi
oc autoscale deployment/"${APP}" --min=2 --max=3 --cpu-percent=75

# ----------------------------
# Rollout
# ----------------------------
echo ">>> Waiting for deployment rollout..."
oc rollout status deployment/"${APP}" --timeout=300s

# ----------------------------
# Expose service
# ----------------------------
if ! oc get service "${APP}" &>/dev/null; then
    echo ">>> Creating service..."
    oc expose deployment "${APP}" \
      --name="${APP}" \
      --port=8080 \
      --labels=app="${APP}" \
      --dry-run=client -o yaml | oc apply -f -
fi

# ----------------------------
# Final status
# ----------------------------
echo
echo ">>> COMPLETE — ${APP} deployed!"
echo
