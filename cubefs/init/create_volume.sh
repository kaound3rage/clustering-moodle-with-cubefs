#!/bin/bash
# ─── CubeFS Volume Initializer ───────────────────────────────────────────
# This script runs once inside a temporary container to create the Moodle
# volume on the CubeFS cluster. It exits cleanly when done.
# ──────────────────────────────────────────────────────────────────────────

set -e

MASTER_ADDR="${CFS_MASTER:-cfs-master:17010}"
VOL_NAME="${CFS_VOL_NAME:-moodle}"
VOL_OWNER="${CFS_VOL_OWNER:-moodle}"
VOL_CAPACITY="${CFS_VOL_CAPACITY:-30}"

# md5 of owner (used as authKey for volume API)
AUTH_KEY=$(echo -n "$VOL_OWNER" | md5sum | awk '{print $1}')

echo "[cfs-init] Waiting for CubeFS master at ${MASTER_ADDR}..."
for i in $(seq 1 120); do
  if curl -sf "http://${MASTER_ADDR}/admin/getCluster" >/dev/null 2>&1; then
    echo "[cfs-init] Master is reachable."
    break
  fi
  if [ "$i" -eq 120 ]; then
    echo "[cfs-init] ERROR: Master not reachable after 120 seconds."
    exit 1
  fi
  sleep 1
done

echo "[cfs-init] Waiting for DataNode and MetaNode to register..."
for i in $(seq 1 120); do
  META_COUNT=$(curl -sf "http://${MASTER_ADDR}/admin/getCluster" 2>/dev/null | grep -o '"MetaNodeCount":[0-9]*' | grep -o '[0-9]*' || echo 0)
  DATA_COUNT=$(curl -sf "http://${MASTER_ADDR}/admin/getCluster" 2>/dev/null | grep -o '"DataNodeCount":[0-9]*' | grep -o '[0-9]*' || echo 0)
  if [ "$META_COUNT" -ge 1 ] && [ "$DATA_COUNT" -ge 1 ]; then
    echo "[cfs-init] MetaNodes: ${META_COUNT}, DataNodes: ${DATA_COUNT} — ready."
    break
  fi
  if [ "$i" -eq 120 ]; then
    echo "[cfs-init] WARNING: Not all nodes registered after 120s (meta=${META_COUNT}, data=${DATA_COUNT})."
  fi
  sleep 1
done

# Check if volume already exists
echo "[cfs-init] Checking if volume '${VOL_NAME}' already exists..."
VOL_EXISTS=$(curl -sf "http://${MASTER_ADDR}/client/vol?name=${VOL_NAME}&authKey=${AUTH_KEY}" 2>/dev/null || echo "")

if [ -n "$VOL_EXISTS" ]; then
  echo "[cfs-init] Volume '${VOL_NAME}' already exists. Skipping creation."
else
  echo "[cfs-init] Creating volume '${VOL_NAME}' with capacity ${VOL_CAPACITY}GB, owner '${VOL_OWNER}'..."
  RESULT=$(curl -sf "http://${MASTER_ADDR}/admin/createVol?name=${VOL_NAME}&volType=1&capacity=${VOL_CAPACITY}&owner=${VOL_OWNER}&mpCount=1&dpCount=1&dpReadOnlyCount=0&crossZone=false" 2>&1)
  echo "[cfs-init] Master response: ${RESULT}"

  # Verify creation
  sleep 2
  VOL_CHECK=$(curl -sf "http://${MASTER_ADDR}/client/vol?name=${VOL_NAME}&authKey=${AUTH_KEY}" 2>/dev/null || echo "")
  if [ -z "$VOL_CHECK" ]; then
    echo "[cfs-init] WARNING: Could not verify volume creation. Check cluster logs."
  else
    echo "[cfs-init] Volume '${VOL_NAME}' created successfully."
  fi
fi

# Create subdirectories for Moodle shared storage
echo "[cfs-init] Volume initialization complete."
echo "[cfs-init] Exiting successfully."
exit 0
