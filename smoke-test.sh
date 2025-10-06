#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${1:-ghcr.io/vdsm-ci/vdsm-ci:latest}"
CONTAINER_NAME="vdsm-smoke-test"
SMOKE_TEST_PORT=5001
TIMEOUT=60

echo "Starting smoke test for $IMAGE_NAME..."

# Clean up any existing test container
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Start the container
if ! docker run -d \
  --name "$CONTAINER_NAME" \
  --privileged \
  -p ${SMOKE_TEST_PORT}:5000 \
  "$IMAGE_NAME" >/dev/null; then
  echo "ERROR: Failed to start container" >&2
  exit 1
fi

echo "Waiting for DSM to respond (timeout: ${TIMEOUT}s)..."

# Wait for DSM to respond using wall clock time
start_time=$(date +%s)
while true; do
  elapsed=$(($(date +%s) - start_time))

  if response=$(curl -sf http://localhost:${SMOKE_TEST_PORT} 2>&1); then
    echo "✓ Smoke test PASSED - DSM responded after ${elapsed}s"
    echo "Response preview: ${response:0:250}"
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    exit 0
  fi

  if [ $elapsed -ge $TIMEOUT ]; then
    echo ""
    echo "ERROR: Smoke test FAILED - DSM did not respond after ${TIMEOUT}s" >&2
    echo ""
    echo "Container logs:" >&2
    docker logs "$CONTAINER_NAME" >&2
    echo ""
    echo "Container '$CONTAINER_NAME' left running for debugging" >&2
    exit 1
  fi

  sleep 1
done
