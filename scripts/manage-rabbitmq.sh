#!/usr/bin/env bash
# Manage a single, non-persistent RabbitMQ broker in the selected oc project.
# Usage: bash scripts/manage-rabbitmq.sh <deploy|remove>
# Requires an authenticated oc CLI and the ogs-rabbitmq Secret.
# deploy applies in place and preserves both internal Services. Pod-template
# changes still cause downtime: Recreate avoids routing to independent brokers.
# No PVC is configured; replacing the pod can lose broker state and messages.
# An unchanged apply does not restart pods or pick up changed Secret values.
# The 1-1 HPA is retained for compatibility; this is not a clustered deployment.
set -euo pipefail

# ----------------------------
# Config
# ----------------------------
APP="ogs-rabbitmq"
# Current clients require x-queue-leader-locator, unsupported by RabbitMQ 3.11.
IMAGE="docker.io/rabbitmq:4.4-management"

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
# Confirm action
# ----------------------------
echo
echo "========================================"
echo " Action:            ${ACTION}"
echo " App:               ${APP}"
echo " Project:           ${PROJ}"
echo " Image:             ${IMAGE}"
echo "========================================"
echo " WARNING: Single broker, no persistence. Replacement interrupts connections"
echo " and can lose broker state/messages. This is not a zero-downtime upgrade."
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
    oc delete service "${APP}" "${APP}-management" --ignore-not-found --wait=true
    oc delete hpa "${APP}" --ignore-not-found --wait=true
    oc delete deployment "${APP}" --ignore-not-found --wait=true
    echo ">>> Remove completed successfully"
    exit 0
fi

# ----------------------------
# Apply complete configuration without deleting running resources
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
  replicas: 1
  revisionHistoryLimit: 3
  minReadySeconds: 10
  progressDeadlineSeconds: 600
  strategy:
    type: Recreate
    rollingUpdate: null
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
        - name: rabbitmq
          image: "${IMAGE}"
          ports:
            - name: amqp
              containerPort: 5672
            - name: management
              containerPort: 15672
          # Clear old literal values when switching to Secret references.
          env:
            - name: RABBITMQ_DEFAULT_USER
              value: null
              valueFrom:
                secretKeyRef:
                  name: ogs-rabbitmq
                  key: RABBITMQ_DEFAULT_USER
            - name: RABBITMQ_DEFAULT_PASS
              value: null
              valueFrom:
                secretKeyRef:
                  name: ogs-rabbitmq
                  key: RABBITMQ_DEFAULT_PASS
          resources:
            limits:
              cpu: 500m
              memory: 512Mi
            requests:
              cpu: 250m
              memory: 256Mi
          # TCP checks avoid launching extra Erlang VMs under the 500m CPU limit.
          # They check the AMQP listener, not authentication or broker alarms.
          startupProbe:
            exec: null
            tcpSocket:
              port: amqp
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 30
          readinessProbe:
            exec: null
            tcpSocket:
              port: amqp
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 2
          livenessProbe:
            exec: null
            tcpSocket:
              port: amqp
            periodSeconds: 30
            timeoutSeconds: 5
            failureThreshold: 6
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
    - port: 5672
      targetPort: 5672
---
apiVersion: v1
kind: Service
metadata:
  name: ${APP}-management
  labels:
    app: ${APP}
spec:
  selector:
    app: ${APP}
  ports:
    - port: 15672
      targetPort: 15672
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
  minReplicas: 1
  maxReplicas: 1
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 100
EOF

# ----------------------------
# Rollout
# ----------------------------
echo ">>> Waiting for deployment rollout..."
if ! oc rollout status deployment/"${APP}" --timeout=600s; then
    echo ">>> ERROR: ${APP} rollout failed; inspect pods, events, and logs" >&2
    echo ">>> The rollout may continue; this does not restore lost broker state." >&2
    exit 1
fi

# ----------------------------
# Final status
# ----------------------------
echo
echo ">>> COMPLETE — ${APP} deployed!"
echo
