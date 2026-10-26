#!/usr/bin/env bash
# Create backups suspended; enable scheduling only after configuration succeeds.
# A failed setup leaves the CronJob suspended. Correct the error and rerun deploy.
set -euo pipefail

# ----------------------------
# Config
# ----------------------------
APP="ogs-tools-cronjob-db-backup"
TARGET_IMAGE="ogs-tools-pgadmin:latest"
TARGET_SCRIPT="/scripts/backup-databases.sh"
PVC_NAME="ogs-tools-pgadmin-data"

# ----------------------------
# Verify passed arg and show help if required
# ----------------------------
OPTIONS=("deploy" "remove")
OPTIONS_STR=$(IFS='|'; echo "${OPTIONS[*]}")
ACTION="${1:-}"
TARGET_NAMESPACE="${2:-}"

# Check if ACTION is valid
if [[ ! " ${OPTIONS[*]} " =~ " ${ACTION} " ]]; then
    echo
    echo "USAGE: $(basename "$0") <${OPTIONS_STR}> <target>"
    echo "EXAMPLE: $(basename "$0") ${OPTIONS[0]} abc123-dev"
    echo
    exit 1
fi

# Check if TARGET_NAMESPACE is provided
if [[ -z "$TARGET_NAMESPACE" ]]; then
    echo
    echo "ERROR: target namespace parameter is required"
    echo "USAGE: $(basename "$0") <${OPTIONS_STR}> <target>"
    echo "EXAMPLE: $(basename "$0") ${OPTIONS[0]} abc123-dev"
    echo
    exit 1
fi

# ----------------------------
# Get current project
# ----------------------------
PROJ=$(oc project -q)

# ----------------------------
# Modify APP name
# ----------------------------
APP="${APP}-for-${TARGET_NAMESPACE}"

# ----------------------------
# Get Schedule from target namespace
# ----------------------------
SCHEDULE=$(oc get secret ogs-cronjob-schedules -n ${TARGET_NAMESPACE} -o jsonpath='{.data.db_backup}' | base64 --decode)

# ----------------------------
# Confirm action
# ----------------------------
echo
echo "========================================"
echo " Action:            ${ACTION}"
echo " App:               ${APP}"
echo " Project:           ${PROJ}"
echo " Target Namespace:  ${TARGET_NAMESPACE}"
echo " Schedule:          ${SCHEDULE}"
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
oc delete cronjob "${APP}" --cascade=background --ignore-not-found --wait=true

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
# Create suspended cronjob with scheduling and storage configured
# ----------------------------
echo ">>> Creating suspended cronjob..."
oc apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ${APP}
  labels:
    app: ${APP}
spec:
  suspend: true
  schedule: "${SCHEDULE}"
  timeZone: America/Los_Angeles
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: ${APP}
              image: image-registry.openshift-image-registry.svc:5000/${PROJ}/${TARGET_IMAGE}
              command: ["/bin/bash", "-c", "${TARGET_SCRIPT}"]
              volumeMounts:
                - name: ${PVC_NAME}
                  mountPath: /var/lib/pgadmin
          volumes:
            - name: ${PVC_NAME}
              persistentVolumeClaim:
                claimName: ${PVC_NAME}
EOF

trap 'echo ">>> ERROR: Backup setup failed; scheduling was not enabled. Inspect cronjob/${APP} before retrying." >&2' ERR

# ----------------------------
# Inject runtime variables
# ----------------------------
POSTGRES_HOST=$(oc get secret ogs-postgresql-cluster-pguser-postgres -n "${TARGET_NAMESPACE}" -o jsonpath='{.data.host}' | base64 --decode)
POSTGRES_PASSWORD=$(oc get secret ogs-postgresql-cluster-pguser-postgres -n "${TARGET_NAMESPACE}" -o jsonpath='{.data.password}' | base64 --decode)
if [[ -z "${POSTGRES_HOST}" || -z "${POSTGRES_PASSWORD}" ]]; then
    echo ">>> ERROR: Backup host or password is empty; ${APP} remains suspended" >&2
    exit 1
fi

oc set env cronjob/"${APP}" \
    POSTGRES_HOST="${POSTGRES_HOST}" \
    POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
    PROJECT="${TARGET_NAMESPACE}"

# ----------------------------
# Enable scheduling only after all configuration succeeds
# ----------------------------
echo ">>> Enabling backup schedule..."
oc patch cronjob "${APP}" --type=merge -p '{"spec":{"suspend":false}}'
trap - ERR

# ----------------------------
# Final status
# ----------------------------
echo
echo ">>> COMPLETE — ${APP} deployed!"
echo