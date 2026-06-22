#!/usr/bin/env bash
# ============================================================================
#  deploy.sh — One-click deployment for Moodle cluster with CubeFS storage
#  Run as root or with sudo on the target Linux server.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${DATA_DIR:-${SCRIPT_DIR}/data}"
MOUNT_POINT="${MOUNT_POINT:-/data/cubefs-mount}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[deploy]${NC} $*"; }
warn() { echo -e "${YELLOW}[deploy]${NC} $*"; }
err()  { echo -e "${RED}[deploy]${NC} $*"; }

# ── Pre-flight checks ──────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  err "This script must be run as root (or with sudo)."
  exit 1
fi

# Check Docker
if ! command -v docker &>/dev/null; then
  err "Docker is not installed. Please install Docker first."
  exit 1
fi

if ! docker compose version &>/dev/null && ! docker-compose version &>/dev/null; then
  err "Docker Compose (v2 plugin or standalone) is not installed."
  exit 1
fi

# Determine compose command
if docker compose version &>/dev/null; then
  COMPOSE="docker compose"
else
  COMPOSE="docker-compose"
fi

# Check / install fuse (required for CubeFS client)
if [ ! -c /dev/fuse ]; then
  warn "FUSE device not found. Attempting to install fuse..."
  if command -v apt-get &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq fuse
  elif command -v yum &>/dev/null; then
    yum install -y fuse
  elif command -v dnf &>/dev/null; then
    dnf install -y fuse
  else
    err "Could not install fuse automatically. Please install it manually."
    exit 1
  fi
fi

# Load fuse kernel module if not loaded
if ! lsmod | grep -q fuse; then
  warn "Loading FUSE kernel module..."
  modprobe fuse || warn "Could not load fuse module (might be built-in)."
fi

# ── Prepare directories ────────────────────────────────────────────────────
log "Creating data directories..."
mkdir -p "${DATA_DIR}/cubefs"/{master,metanode,datanode,client}/{data,log}
mkdir -p "${DATA_DIR}/cubefs/datanode/disk"
mkdir -p "${MOUNT_POINT}"

# Make the mount point shared so FUSE mount propagates to other containers
log "Configuring shared mount propagation on ${MOUNT_POINT}..."
mount --make-shared "${MOUNT_POINT}" 2>/dev/null || {
  # If it's not a mountpoint yet, bind-mount it to itself first
  mount --bind "${MOUNT_POINT}" "${MOUNT_POINT}"
  mount --make-shared "${MOUNT_POINT}"
}

# ── Deploy ──────────────────────────────────────────────────────────────────
cd "${SCRIPT_DIR}"

log "Pulling Docker images..."
${COMPOSE} pull

log "Starting CubeFS cluster (master, metanode, datanode)..."
${COMPOSE} up -d cfs-master cfs-metanode cfs-datanode

log "Waiting for CubeFS cluster to become healthy..."
RETRIES=0
MAX_RETRIES=90
while [ $RETRIES -lt $MAX_RETRIES ]; do
  STATUS=$(${COMPOSE} ps --format json 2>/dev/null | grep -c '"healthy"' || true)
  if [ "$STATUS" -ge 3 ]; then
    break
  fi
  RETRIES=$((RETRIES + 1))
  sleep 2
done

if [ $RETRIES -eq $MAX_RETRIES ]; then
  warn "CubeFS cluster did not become healthy within 180s. Continuing anyway..."
  ${COMPOSE} logs cfs-master cfs-metanode cfs-datanode --tail=20
else
  log "CubeFS cluster is healthy."
fi

log "Running CubeFS volume initializer..."
${COMPOSE} up cfs-init

log "Starting CubeFS FUSE client..."
${COMPOSE} up -d cfs-client

log "Waiting for CubeFS mount to be ready..."
RETRIES=0
MAX_RETRIES=30
while [ $RETRIES -lt $MAX_RETRIES ]; do
  if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
    break
  fi
  RETRIES=$((RETRIES + 1))
  sleep 2
done

if [ $RETRIES -eq $MAX_RETRIES ]; then
  warn "CubeFS mount not ready after 60s. Check cfs-client logs."
else
  log "CubeFS is mounted at ${MOUNT_POINT}."
fi

log "Starting Moodle cluster + Nginx load balancer..."
${COMPOSE} up -d moodle nginx

log ""
log "============================================"
log "  Deployment complete!"
log "============================================"
log ""
log "  Moodle URL : http://$(hostname -I | awk '{print $1}'):${PORT:-8082}"
log "  Replicas   : ${MOODLE_REPLICAS:-3}"
log "  CubeFS UI  : http://$(hostname -I | awk '{print $1}'):80 (Nginx → Moodle)"
log ""
log "  Useful commands:"
log "    ${COMPOSE} ps              — check service status"
log "    ${COMPOSE} logs -f moodle  — follow Moodle logs"
log "    ${COMPOSE} logs -f cfs-*   — follow CubeFS logs"
log "    ${COMPOSE} down -v         — tear down everything"
log ""
