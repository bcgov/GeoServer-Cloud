#!/usr/bin/env bash
# Build and roll out the public reverse proxy in the current OpenShift project.
# Usage: bash scripts/manage-rproxy.sh <deploy|remove>
# Requires an authenticated oc CLI and capacity for one extra proxy pod.
# Builds use the remote repository below: push Dockerfile/nginx.conf changes first.
# deploy preserves the Service/Route and waits for healthy replacement pods.
# remove deletes proxy resources only, not GeoServer or its databases.
# Rollout failure stops the script but does not cancel the rollout or undo changes.
set -euo pipefail

# ----------------------------
# Config
# ----------------------------
APP="ogs-rproxy"
REPO="https://github.com/bcgov/GeoServer-Cloud.git"

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
# Remove resources only when explicitly requested
# ----------------------------
if [[ "${ACTION}" == "remove" ]]; then
  oc delete route "${APP}" --ignore-not-found --wait=true
  oc delete service "${APP}" --ignore-not-found --wait=true
  oc delete bc "${APP}" --ignore-not-found --wait=true
  oc delete builds -l app="${APP}" --ignore-not-found --wait=true
  oc delete hpa "${APP}" --ignore-not-found --wait=true
  oc delete deployment "${APP}" --ignore-not-found --wait=true
  oc delete is "${APP}" --ignore-not-found --wait=true
  echo
  echo ">>> Remove completed successfully"
  echo
  exit 0
fi

# ----------------------------
# Apply build resources without automatically triggering a second build
# ----------------------------
echo ">>> Creating/updating BuildConfig..."
oc apply -f - <<EOF
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: ${APP}
  labels:
    app: ${APP}
---
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: ${APP}
  labels:
    app: ${APP}
spec:
  runPolicy: Serial
  successfulBuildsHistoryLimit: 3
  failedBuildsHistoryLimit: 3
  triggers: []
  source:
    type: Git
    git:
      uri: "${REPO}"
    contextDir: compose/${APP}
  strategy:
    type: Docker
    dockerStrategy:
      # Use the FROM image in the repository Dockerfile, not a separate override.
      from: null
  output:
    to:
      kind: ImageStreamTag
      name: ${APP}:latest
EOF

# ----------------------------
# Start build
# ----------------------------
echo ">>> Starting build..."
# start-build --wait supports older oc clients without JSONPath wait conditions.
if ! BUILD=$(oc start-build "${APP}" --wait -o name); then
    echo ">>> ERROR: ${APP} build failed; inspect its build status and logs" >&2
    exit 1
fi
oc logs "${BUILD}"
PHASE=$(oc get "${BUILD}" -o 'jsonpath={.status.phase}')
if [[ "${PHASE}" != "Complete" ]]; then
    echo ">>> ERROR: Build ${BUILD} is ${PHASE}; expected Complete" >&2
    exit 1
fi
DIGEST=$(oc get "${BUILD}" -o 'jsonpath={.status.output.to.imageDigest}')
if [[ ! "${DIGEST}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
    echo ">>> ERROR: Completed build ${BUILD} did not provide a valid image digest" >&2
    exit 1
fi
IMAGE="image-registry.openshift-image-registry.svc:5000/${PROJ}/${APP}@${DIGEST}"

# ----------------------------
# Create Deployment
# ----------------------------
echo ">>> Creating/updating Deployment..."
oc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP}
  labels:
    app: ${APP}
spec:
  # HPA owns replicas. First creation defaults to one until autoscaling adjusts it.
  revisionHistoryLimit: 3
  minReadySeconds: 15
  progressDeadlineSeconds: 900
  strategy:
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
      terminationGracePeriodSeconds: 120
      containers:
        - name: ${APP}
          image: "${IMAGE}"
          ports:
            - name: http
              containerPort: 8080
          resources:
            limits:
              cpu: 300m
              memory: 512Mi
            requests:
              cpu: 150m
              memory: 256Mi
          startupProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 30
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 2
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 15"]
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
echo ">>> Waiting for deployment rollout..."
if ! oc rollout status deployment/"${APP}" --timeout=900s; then
    echo ">>> ERROR: ${APP} rollout failed; inspect pods, events, and logs" >&2
    exit 1
fi

# ----------------------------
# Expose internal service
# ----------------------------
SERVICE=$(oc get service "${APP}" --ignore-not-found -o name)
if [[ -z "${SERVICE}" ]]; then
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
ROUTE=$(oc get route "${APP}" --ignore-not-found -o name)
if [[ -z "${ROUTE}" ]]; then
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
# Final status
# ----------------------------
echo
echo ">>> COMPLETE — ${APP} deployed!"
echo
