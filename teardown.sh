#!/usr/bin/env bash
# ============================================================================
#  teardown.sh — Tear down the Moodle + CubeFS cluster
#  Run as root or with sudo.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOUNT_POINT="${MOUNT_POINT:-/data/cubefs-mount}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log()  { echo -e "${GREEN}[teardown]${NC} $*"; }

# Determine compose command
if docker compose version &>/dev/null; then
  COMPOSE="docker compose"
else
  COMPOSE="docker-compose"
fi

cd "${SCRIPT_DIR}"

log "Stopping all containers..."
${COMPOSE} down --remove-orphans

log "Unmounting CubeFS..."
if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
  fusermount -u "${MOUNT_POINT}" 2>/dev/null || umount "${MOUNT_POINT}" 2>/dev/null || true
fi

log "Removing shared mount propagation..."
umount "${MOUNT_POINT}" 2>/dev/null || true

echo ""
log "Teardown complete."
log "Data is preserved in: ${DATA_DIR:-${SCRIPT_DIR}/data}"
log "To remove all data: rm -rf ${DATA_DIR:-${SCRIPT_DIR}/data}"
log "To remove Docker volumes: ${COMPOSE} down -v"
