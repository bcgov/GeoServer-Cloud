#!/usr/bin/env bash
# Manage the gateway Deployment, its internal Service, and its 2-3 replica HPA.
# Requires Bash, an authenticated oc CLI, and the intended oc project.
#   ./scripts/manage-geoserver-gateway.sh <deploy|remove>
# The default image tag comes from the adjacent geoserver-version.env.
#
# deploy updates in place; remove deletes only this component's resources.
# Allow capacity for an extra pod and verify probes/shutdown on the target image
# in staging. Gateway/backend compatibility must hold throughout an upgrade.
set -euo pipefail

# ----------------------------
# Config
# ----------------------------
APP="ogs-geoserver-gateway"
source "$(dirname "${BASH_SOURCE[0]}")/geoserver-version.env"
VERSION="${GEOSERVER_CLOUD_VERSION}"
IMAGE="docker.io/geoservercloud/geoserver-cloud-gateway:${VERSION}"

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
    oc delete service "${APP}" --ignore-not-found --wait=true
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
  # Omit replicas so the HPA owns scaling; a new Deployment starts at one.
  revisionHistoryLimit: 3
  minReadySeconds: 15
  progressDeadlineSeconds: 900
  strategy:
    # Retain available capacity until a surge pod has been ready for 15 seconds.
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
        - name: geoserver-cloud-gateway
          image: "${IMAGE}"
          ports:
            - name: http
              containerPort: 8080
            - name: management
              containerPort: 8081
          env:
            - name: SPRING_PROFILES_ACTIVE
              value: "gateway_service,standalone"
            - name: SPRING_WEB_CORS_ALLOWED_ORIGINS
              value: "*"
            - name: SPRING_WEB_CORS_ALLOWED_METHODS
              value: "GET,POST,PUT,DELETE,OPTIONS,HEAD"
            - name: SPRING_WEB_CORS_ALLOWED_HEADERS
              value: "*"
            - name: SPRING_WEB_CORS_ALLOW_CREDENTIALS
              value: "true"
            - name: CATALINA_OPTS
              value: "-DALLOW_ENV_PARAMETRIZATION=true"
            - name: JAVA_OPTS
              value: "-Xms384m -Xmx768m -XX:+UseG1GC -XX:MaxGCPauseMillis=200"
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
              memory: 768Mi
            requests:
              cpu: 150m
              memory: 512Mi
          # Startup allows roughly 10 minutes before other probes take over.
          # Management port 8081 is not exposed by the Service; verify pod access
          # and NetworkPolicies. These checks do not validate backend requests.
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
  name: ${APP}
  labels:
    app: ${APP}
spec:
  selector:
    app: ${APP}
  ports:
    - port: 8080
      targetPort: 8080
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${APP}
  labels:
    app: ${APP}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ${APP}
  minReplicas: 2
  maxReplicas: 3
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 75
EOF

# ----------------------------
# Rollout
# ----------------------------
# A timeout exits this script, but does not cancel or roll back the rollout.
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
