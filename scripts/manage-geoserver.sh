#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Scripts to run
# ----------------------------
SCRIPTS=(
    "./scripts/manage-geoserver-webui.sh"
    "./scripts/manage-geoserver-wfs.sh"
    "./scripts/manage-geoserver-wms.sh"
    "./scripts/manage-geoserver-rest.sh"
    "./scripts/manage-geoserver-gateway.sh"
)

# ----------------------------
# Verify argument
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
echo " Action:  ${ACTION}"
echo " App:     ogs-geoserver (all)"
echo " Project: ${PROJ}"
echo " Scripts: ${#SCRIPTS[@]}"
echo "========================================"
echo
read -r -p "Continue with all scripts? [y/N]: " CONFIRM
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
# Run scripts
# ----------------------------
for SCRIPT in "${SCRIPTS[@]}"; do
    if [[ -x "$SCRIPT" ]]; then
        echo
        echo ">>> Running $SCRIPT $ACTION"
        # Send a single 'Y' to confirmation prompt
        printf "Y\n" | "$SCRIPT" "$ACTION"
    else
        echo ">>> ERROR: $SCRIPT not found or not executable"
    fi
done

# ----------------------------
# Final status
# ----------------------------
echo
echo ">>> ALL scripts completed successfully!"
echo
