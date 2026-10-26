#!/usr/bin/env bash
# Manage the REST configuration Deployment and internal Service named restconfig.
# Requires Bash, an authenticated oc CLI, the intended oc project, PostgreSQL,
# RabbitMQ, and Secrets ogs-geoserver, ogs-rabbitmq, and
# ogs-postgresql-cluster-pguser-ogs-config-user.
#   ./scripts/manage-geoserver-rest.sh <deploy|remove>
# The default image tag comes from the adjacent geoserver-version.env.
#
# deploy updates in place; remove leaves the shared catalog and Secrets intact.
# Back up the catalog and test mixed-version schema/event compatibility in staging.
# Pause configuration writes during upgrades unless mixed-version writes are safe.
set -euo pipefail

# ----------------------------
# Config
# ----------------------------
APP="ogs-geoserver-rest"
source "$(dirname "${BASH_SOURCE[0]}")/geoserver-version.env"
VERSION="${GEOSERVER_CLOUD_VERSION}"
IMAGE="docker.io/geoservercloud/geoserver-cloud-rest:${VERSION}"

# ----------------------------
# Verify passed arg and show help if required
# ----------------------------
ACTION="${1:-}"
case "${ACTION}" in
    deploy|remove) ;;
    *)
        echo "USAGE: $(basename "$0") <deploy|remove>" >&2
        exit 1
        ;;
esac

if [[ ! "${VERSION}" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]]; then
    echo ">>> ERROR: GEOSERVER_CLOUD_VERSION must be a valid image tag" >&2
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
echo " Image:             ${IMAGE}"
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
# Remove resources only when explicitly requested
# ----------------------------
if [[ "${ACTION}" == "remove" ]]; then
    oc delete service restconfig --ignore-not-found --wait=true
    oc delete hpa "${APP}" --ignore-not-found --wait=true
    oc delete deployment "${APP}" --ignore-not-found --wait=true
    echo ""
    echo ">>> Remove completed successfully"
    echo ""
    exit 0
fi

# ----------------------------
# Apply the complete configuration without deleting running resources
# ----------------------------
echo ">>> Applying ${APP} configuration..."
oc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP}
  labels:
    app: ${APP}
spec:
  # One steady-state pod, with capacity for a second during rolling replacement.
  replicas: 1
  revisionHistoryLimit: 3
  minReadySeconds: 15
  progressDeadlineSeconds: 900
  strategy:
    # Keep the old pod until the replacement has been ready for 15 seconds.
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  selector:
    matchLabels:
      app: ${APP}
  template:
    metadata:
      labels:
        app: ${APP}
    spec:
      # Budget for the 15-second preStop delay plus the 90-second shutdown phase.
      terminationGracePeriodSeconds: 120
      containers:
        - name: geoserver-cloud-rest
          image: "${IMAGE}"
          ports:
            - name: http
              containerPort: 8080
            - name: management
              containerPort: 8081
          # null clears old literal values when adopting secretKeyRef via apply.
          # Secret updates require pod recreation; unchanged apply will not restart.
          env:
            - name: GEOSERVER_ADMIN_USERNAME
              value: null
              valueFrom:
                secretKeyRef:
                  name: ogs-geoserver
                  key: GEOSERVER_ADMIN_USER
            - name: GEOSERVER_ADMIN_PASSWORD
              value: null
              valueFrom:
                secretKeyRef:
                  name: ogs-geoserver
                  key: GEOSERVER_ADMIN_PASSWORD
            - name: GWC_CACHEDIRECTORY
              value: "/tmp/gwc"
            - name: LOGGING_LEVEL_ORG_GEOSERVER
              value: "INFO"
            - name: PGCONFIG_HOST
              value: null
              valueFrom:
                secretKeyRef:
                  name: ogs-postgresql-cluster-pguser-ogs-config-user
                  key: pgbouncer-host
            - name: PGCONFIG_PORT
              value: null
              valueFrom:
                secretKeyRef:
                  name: ogs-postgresql-cluster-pguser-ogs-config-user
                  key: pgbouncer-port
            - name: PGCONFIG_DATABASE
              value: null
              valueFrom:
                secretKeyRef:
                  name: ogs-postgresql-cluster-pguser-ogs-config-user
                  key: dbname
            - name: PGCONFIG_USERNAME
              value: null
              valueFrom:
                secretKeyRef:
                  name: ogs-postgresql-cluster-pguser-ogs-config-user
                  key: user
            - name: PGCONFIG_PASSWORD
              value: null
              valueFrom:
                secretKeyRef:
                  name: ogs-postgresql-cluster-pguser-ogs-config-user
                  key: password
            - name: PGCONFIG_SCHEMA
              value: "public"
            - name: SPRING_PROFILES_ACTIVE
              value: "standalone,pgconfig,eventbus-rabbit,restconfig_service"
            - name: SPRING_CLOUD_BUS_ENABLED
              value: "true"
            - name: SPRING_RABBITMQ_HOST
              value: "ogs-rabbitmq"
            - name: SPRING_RABBITMQ_PORT
              value: "5672"
            - name: SPRING_RABBITMQ_USERNAME
              value: null
              valueFrom:
                secretKeyRef:
                  name: ogs-rabbitmq
                  key: RABBITMQ_DEFAULT_USER
            - name: SPRING_RABBITMQ_PASSWORD
              value: null
              valueFrom:
                secretKeyRef:
                  name: ogs-rabbitmq
                  key: RABBITMQ_DEFAULT_PASS
            - name: SPRING_RABBITMQ_REQUESTED_HEARTBEAT
              value: "30"
            - name: SPRING_RABBITMQ_CONNECTION_TIMEOUT
              value: "10000"
            - name: SPRING_RABBITMQ_LISTENER_SIMPLE_RETRY_ENABLED
              value: "true"
            - name: SPRING_RABBITMQ_LISTENER_SIMPLE_RETRY_MAX_ATTEMPTS
              value: "20"
            - name: SPRING_RABBITMQ_LISTENER_SIMPLE_RETRY_INITIAL_INTERVAL
              value: "10000"
            - name: SPRING_RABBITMQ_LISTENER_SIMPLE_RETRY_MULTIPLIER
              value: "1.5"
            - name: CATALINA_OPTS
              value: "-DALLOW_ENV_PARAMETRIZATION=true"
            - name: JAVA_OPTS
              value: "-Xms256m -Xmx512m -XX:+UseG1GC -XX:MaxGCPauseMillis=200"
            - name: FLYWAY_BASELINE_ON_MIGRATE
              value: "true"
            - name: SERVER_SHUTDOWN
              value: "graceful"
            - name: SPRING_LIFECYCLE_TIMEOUT_PER_SHUTDOWN_PHASE
              value: "90s"
            - name: MANAGEMENT_SERVER_PORT
              value: "8081"
            - name: MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED
              value: "true"
          resources:
            limits:
              cpu: 300m
              memory: 1Gi
            requests:
              cpu: 150m
              memory: 768Mi
          # Startup allows roughly 10 minutes before readiness/liveness take over.
          # Verify the target image serves these endpoints on management port 8081.
          # The Service excludes this port; pod-level access depends on policies.
          startupProbe:
            httpGet:
              path: /actuator/health/liveness
              port: management
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 60
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: management
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 2
          livenessProbe:
            httpGet:
              path: /actuator/health/liveness
              port: management
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          lifecycle:
            preStop:
              # Allow endpoint removal to propagate before SIGTERM; requires sh/sleep.
              exec:
                command: ["/bin/sh", "-c", "sleep 15"]
---
apiVersion: v1
kind: Service
metadata:
  name: restconfig
  labels:
    app: ${APP}
spec:
  selector:
    app: ${APP}
  ports:
    - port: 8080
      targetPort: 8080
EOF

# ----------------------------
# Rollout
# ----------------------------
# A timeout does not cancel the rollout or undo any catalog migration.
echo ">>> Waiting for deployment rollout..."
if ! oc rollout status deployment/"${APP}" --timeout=900s; then
    echo ">>> ERROR: ${APP} rollout failed; inspect pods, events, and logs before continuing" >&2
    exit 1
fi

# ----------------------------
# Final status
# ----------------------------
echo
echo ">>> COMPLETE — ${APP} deployed!"
echo
