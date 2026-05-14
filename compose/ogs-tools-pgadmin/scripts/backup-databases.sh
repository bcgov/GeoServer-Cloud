#!/bin/bash
set -euo pipefail

# -----------------------------
# Configuration
# -----------------------------
DB_USER="postgres"
DB_PASSWORD="${POSTGRES_PASSWORD}"
DB_HOST="${POSTGRES_HOST}"
DB_PORT=5432
BACKUP_DIR="/var/lib/pgadmin/storage/spatialadmin_gov.bc.ca/backups/${PROJECT}" 
RETENTION_DAYS=14
DATABASES=("postgres" "gisdata" "ogs_configuration")
DATESTAMP=$(date +'%Y%m%d-%H')

# -----------------------------
# Make the backup dir if it does not exist
# -----------------------------
mkdir -p "${BACKUP_DIR}"

# -----------------------------
# Logging setup
# -----------------------------
mkdir -p "${BACKUP_DIR}"
LOG_FILE="${BACKUP_DIR}/${DATESTAMP}.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

# -----------------------------
# Start header
# -----------------------------
START_TS=$(date +"%Y-%m-%d %H:%M:%S %Z")
START_EPOCH=$(date +%s)

echo "========================================"
echo "  Operation: PostgreSQL Backup"
echo " Start Time: ${START_TS}"
echo "========================================"

# -----------------------------
# Footer (always runs)
# -----------------------------
EXIT_CODE=0
footer() {
    END_TS=$(date +"%Y-%m-%d %H:%M:%S %Z")
    END_EPOCH=$(date +%s)
    DURATION=$((END_EPOCH - START_EPOCH))
    DURATION_FMT=$(printf "%02d:%02d:%02d" $((DURATION/3600)) $((DURATION%3600/60)) $((DURATION%60)))

    echo
    echo "========================================"
    echo " End Time: ${END_TS}"
    echo " Duration: ${DURATION_FMT}"
    echo "========================================"
    echo
}

trap 'EXIT_CODE=$?; footer' EXIT

# -----------------------------
# Export password for pg_dump
# -----------------------------
export PGPASSWORD="$DB_PASSWORD"

# -----------------------------
# Backup loop
# -----------------------------
for DB_NAME in "${DATABASES[@]}"; do
    BACKUP_FILE="${BACKUP_DIR}/${DATESTAMP}_${DB_NAME}.dump"
    echo
    echo "Backing up database '${DB_NAME}' to '${BACKUP_FILE}'..."

    # pg_dump with error handling
    if ! pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -F c -Z 9 -f "${BACKUP_FILE}"; then
        echo "Backup of '${DB_NAME}' failed!"
        EXIT_CODE=1
    else
        echo "Backup of '${DB_NAME}' successful."
        echo "To restore this backup:"
        echo " >>> pg_restore -h $DB_HOST -p $DB_PORT -U $DB_USER --clean --if-exists -d ${DB_NAME} -v ${BACKUP_FILE}"
    fi
done

# -----------------------------
# Cleanup old backups
# -----------------------------
echo
echo "Cleaning up backups and logs older than ${RETENTION_DAYS} days in $BACKUP_DIR..."
find "$BACKUP_DIR" -type f \( -name "*.dump" -o -name "*.log" \) -mtime +$RETENTION_DAYS -exec rm -f {} \;
echo "Backup and cleanup completed."