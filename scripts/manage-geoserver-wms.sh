#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Config
# ----------------------------
APP="ogs-geoserver-wms"
IMAGE="docker.io/geoservercloud/geoserver-cloud-wms:2.28.2.4"

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
    --image="${IMAGE}" \
    --dry-run=client -o yaml | oc apply -f -
oc label deployment "${APP}" app="${APP}" --overwrite

# ----------------------------
# Inject runtime variables
# ----------------------------
oc set env deployment/"${APP}" \
    GEOSERVER_ADMIN_USERNAME=$(oc get secret ogs-geoserver -o jsonpath='{.data.GEOSERVER_ADMIN_USER}' | base64 --decode) \
    GEOSERVER_ADMIN_PASSWORD=$(oc get secret ogs-geoserver -o jsonpath='{.data.GEOSERVER_ADMIN_PASSWORD}' | base64 --decode) \
	LOGGING_LEVEL_ORG_GEOSERVER=INFO \
	PGCONFIG_HOST=$(oc get secret ogs-postgresql-cluster-pguser-ogs-config-user -o jsonpath='{.data.pgbouncer-host}' | base64 --decode) \
	PGCONFIG_PORT=$(oc get secret ogs-postgresql-cluster-pguser-ogs-config-user -o jsonpath='{.data.pgbouncer-port}' | base64 --decode) \
	PGCONFIG_DATABASE=$(oc get secret ogs-postgresql-cluster-pguser-ogs-config-user -o jsonpath='{.data.dbname}' | base64 --decode) \
	PGCONFIG_USERNAME=$(oc get secret ogs-postgresql-cluster-pguser-ogs-config-user -o jsonpath='{.data.user}' | base64 --decode) \
	PGCONFIG_PASSWORD=$(oc get secret ogs-postgresql-cluster-pguser-ogs-config-user -o jsonpath='{.data.password}' | base64 --decode) \
	PGCONFIG_SCHEMA=public \
	SPRING_PROFILES_ACTIVE="standalone,pgconfig,eventbus-rabbit" \
	SPRING_CLOUD_BUS_ENABLED=true \
	SPRING_RABBITMQ_HOST=ogs-rabbitmq \
	SPRING_RABBITMQ_PORT=5672 \
	SPRING_RABBITMQ_USERNAME=$(oc get secret ogs-rabbitmq -o jsonpath='{.data.RABBITMQ_DEFAULT_USER}' | base64 --decode) \
	SPRING_RABBITMQ_PASSWORD=$(oc get secret ogs-rabbitmq -o jsonpath='{.data.RABBITMQ_DEFAULT_PASS}' | base64 --decode) \
	SPRING_RABBITMQ_REQUESTED_HEARTBEAT=30 \
	SPRING_RABBITMQ_CONNECTION_TIMEOUT=10000 \
	SPRING_RABBITMQ_LISTENER_SIMPLE_RETRY_ENABLED=true \
	SPRING_RABBITMQ_LISTENER_SIMPLE_RETRY_MAX_ATTEMPTS=20 \
	SPRING_RABBITMQ_LISTENER_SIMPLE_RETRY_INITIAL_INTERVAL=10000 \
	SPRING_RABBITMQ_LISTENER_SIMPLE_RETRY_MULTIPLIER=1.5 \
	CATALINA_OPTS="-DALLOW_ENV_PARAMETRIZATION=true" \
    JAVA_OPTS="-Xms512m -Xmx1g -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:+AlwaysPreTouch -XX:+UseStringDeduplication" \
	FLYWAY_BASELINE_ON_MIGRATE=true

# ----------------------------
# Set resources and autoscaler
# ----------------------------
oc set resources deployment/"${APP}" --limits=cpu=2,memory=2Gi --requests=cpu=500m,memory=1.5Gi
oc autoscale deployment/"${APP}" --min=1 --max=2 --cpu-percent=70

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
      --name=wms \
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
