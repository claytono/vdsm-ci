#!/usr/bin/env bash
set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASEDIR"

# Source DSM version configuration
# shellcheck source=./dsm-version.sh disable=SC1091
source "$BASEDIR/dsm-version.sh"
DSM_PAT_URL="https://global.synologydownload.com/download/DSM/release/${DSM_VERSION}/${DSM_BUILD}/DSM_VirtualDSM_${DSM_BUILD}.pat"
DSM_PAT_FILE="$BASEDIR/cache/DSM_VirtualDSM_${DSM_BUILD}.pat"

IMAGE_NAME=${DSM_IMAGE_NAME:-"ghcr.io/claytono/vdsm-ci"}
IMAGE_TAG=${DSM_IMAGE_TAG:-"latest"}
FULL_IMAGE_NAME="$IMAGE_NAME:$IMAGE_TAG"

DSM_SERVER_NAME=${DSM_SERVER_NAME:-"vdsm-ci"}
DSM_ADMIN_USER=${DSM_ADMIN_USER:-"ciadmin"}
DSM_ADMIN_PASS=${DSM_ADMIN_PASS:-"F4k3Pass1!"}
DSM_VM_IP=${DSM_VM_IP:-"20.20.20.21"}

CONTAINER_NAME="vdsm-config"
PATCHED_IMAGE="vdsm/virtual-dsm:patched"
QEMU_CPU_FLAGS="-cpu Westmere,-invtsc"

KEEP_CONTAINER=false
IGNORE_CHECKPOINTS=false
CLEANUP_OLD_IMAGES=true
START_FROM_CHECKPOINT=""
EXPLORE_ONLY=false
ENABLE_CHECKPOINTS=false
ACCEL_MODE="auto"  # "auto", "kvm", or "tcg"

# ============================================================================
# Helper Functions
# ============================================================================

# --- Image & Checkpoint Naming ---

checkpoint_image_name() {
  local checkpoint_name=$1
  echo "${IMAGE_NAME}:ckpt-${checkpoint_name}"
}

checkpoint_exists() {
  local checkpoint_name=$1
  docker image inspect "$(checkpoint_image_name "$checkpoint_name")" >/dev/null 2>&1
}

list_checkpoints() {
  docker images "${IMAGE_NAME}" --format "  {{.Tag}}" 2>/dev/null | grep "^ckpt-" | sed 's/^ckpt-/  /' || echo "  (none)"
}

tag_with_version() {
  local image=$1
  local version_tag="${IMAGE_NAME}:${DSM_VERSION}"
  docker tag "$image" "$version_tag"
  echo "Tagged as: $version_tag"
}

# --- Container Lifecycle ---

run_vdsm_container() {
  local image=$1
  local snapshot_name=${2:-""}

  docker rm "$CONTAINER_NAME" 2>/dev/null || true

  local qemu_args="$QEMU_CPU_FLAGS"
  if [[ -n "$snapshot_name" ]]; then
    qemu_args="$qemu_args -loadvm $snapshot_name"
  fi

  # For TCG builds, we need KVM=N during checkpoint creation
  # Otherwise snapshots will contain kvmclock state incompatible with TCG
  local kvm_args=()
  if [[ "$ACCEL_MODE" == "tcg" ]]; then
    kvm_args+=(-e KVM=N)
  fi

  docker run -d \
    --name "$CONTAINER_NAME" \
    --privileged \
    -p 5000:5000 \
    -e DISK_FMT=qcow2 \
    -e ARGUMENTS="$qemu_args" \
    "${kvm_args[@]}" \
    -v "$DSM_PAT_FILE:/boot.pat:ro" \
    -v "$PWD/videos:/tmp/playwright-videos" \
    "$image"
}

copy_automation_script() {
  docker cp "$BASEDIR/provision-dsm.py" "$CONTAINER_NAME:/tmp/provision-dsm.py"
}

stop_and_commit() {
  local target_image=$1
  local snapshot_name=${2:-""}

  docker stop "$CONTAINER_NAME"

  local changes=(
    'ENV DISK_FMT=qcow2'
    'EXPOSE 5000'
    'LABEL org.opencontainers.image.vendor="vdsm-ci"'
    'LABEL vdsm-ci.image.type="checkpoint"'
    'LABEL vdsm-ci.managed="true"'
  )

  if [[ -n "$snapshot_name" ]]; then
    changes+=("ENV ARGUMENTS=\"${QEMU_CPU_FLAGS} -loadvm ${snapshot_name}\"")
  fi

  local change_args=()
  for change in "${changes[@]}"; do
    change_args+=(--change="$change")
  done

  docker commit "${change_args[@]}" "$CONTAINER_NAME" "$target_image" >/dev/null
  docker rm "$CONTAINER_NAME" 2>/dev/null || true
}

# --- QEMU Operations ---

create_qemu_snapshot() {
  local snapshot_name=$1

  # Check if QEMU is running
  if ! docker exec "$CONTAINER_NAME" pgrep -f qemu-system-x86_64 >/dev/null; then
    echo "ERROR: QEMU not running, cannot create snapshot" >&2
    exit 1
  fi

  docker exec "$CONTAINER_NAME" bash -c "
    result=\$(echo 'savevm ${snapshot_name}' | nc -q 1 localhost 7100 2>&1 | tr -d '\\000')
    if echo \"\$result\" | grep -qi 'error\|failed'; then
      echo 'ERROR: QEMU snapshot failed:' >&2
      echo \"\$result\" >&2
      exit 1
    fi
    echo 'QEMU snapshot saved: ${snapshot_name}'
  "
}

# --- Waiting Primitives ---

wait_for_url() {
  local url=$1
  local timeout=$2
  local description=$3
  local executor=${4:-""}  # Optional: empty for host, or container name for docker exec

  local start
  start=$(date +%s)
  local last_print=0

  while true; do
    local now
    now=$(date +%s)
    local elapsed=$((now - start))

    # Execute curl either on host or in container
    local curl_result=0
    if [[ -z "$executor" ]]; then
      curl --connect-timeout 5 -sf "$url" >/dev/null 2>&1 || curl_result=$?
    else
      docker exec "$executor" curl --connect-timeout 5 -sf "$url" >/dev/null 2>&1 || curl_result=$?
    fi

    if [[ $curl_result -eq 0 ]]; then
      return 0
    fi

    if [ "$elapsed" -ge "$timeout" ]; then
      echo "ERROR: $description not available after ${timeout}s" >&2
      docker logs "$CONTAINER_NAME" >&2
      exit 1
    fi

    if [ $((elapsed - last_print)) -ge 10 ]; then
      echo "[wait-for-boot] Still waiting for $description at $url... (${elapsed}s/${timeout}s)"
      last_print=$elapsed
    fi

    sleep 1
  done
}

start_from_checkpoint() {
  local checkpoint_name=$1

  # Verify checkpoint exists
  if ! checkpoint_exists "$checkpoint_name"; then
    echo "ERROR: Checkpoint '$checkpoint_name' does not exist!" >&2
    echo "" >&2
    echo "Available checkpoints:" >&2
    list_checkpoints >&2
    exit 1
  fi

  echo ""
  echo "Resuming from checkpoint: $checkpoint_name"
  echo "QEMU will restore snapshot '${checkpoint_name}' on startup..."

  run_vdsm_container "$(checkpoint_image_name "$checkpoint_name")" "$checkpoint_name"

  check_container_running

  echo "Copying latest automation script into container..."
  copy_automation_script
  echo "✓ Automation script updated"

  echo "Waiting for DSM web interface to be available..."
  wait_for_dsm
  echo "✓ DSM web interface and VM network ready"
}

save_checkpoint() {
  local checkpoint_name=$1
  local tag_name=${2:-"ckpt-${checkpoint_name}"}  # Optional tag, defaults to ckpt-<name>
  local checkpoint_image="${IMAGE_NAME}:${tag_name}"

  echo ""
  echo "Saving checkpoint: $checkpoint_name (tag: $tag_name)"

  # Take QEMU snapshot
  create_qemu_snapshot "$checkpoint_name"

  # Commit container to image
  echo "Committing checkpoint image..."
  stop_and_commit "$checkpoint_image" "$checkpoint_name"

  # Restart from checkpoint
  echo "Restarting container from checkpoint..."
  run_vdsm_container "$checkpoint_image" "$checkpoint_name" >/dev/null

  copy_automation_script 2>/dev/null || true

  echo "Waiting for DSM web interface to be available..."
  wait_for_dsm
  echo "✓ DSM web interface and VM network ready"

  echo "✓ Checkpoint saved: $checkpoint_image (QEMU will restore on startup)"
}

wait_for_dsm() {
  local timeout=600

  # First wait for external port (localhost:5000)
  wait_for_url "http://localhost:5000" "$timeout" "VDSM web interface"

  # Then wait for internal VM network (from inside container)
  wait_for_url "http://${DSM_VM_IP}:5000" "$timeout" "VM network" "$CONTAINER_NAME"
}

cleanup() {
  if [[ "${KEEP_CONTAINER:-false}" == true ]]; then
    echo ""
    echo "Skipping cleanup; container left running due to --keep"
    return
  fi
  echo ""
  echo "Cleaning up..."
  docker stop "$CONTAINER_NAME" 2>/dev/null || true
  docker rm "$CONTAINER_NAME" 2>/dev/null || true
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep)
        KEEP_CONTAINER=true
        shift
        ;;
      --no-cache)
        IGNORE_CHECKPOINTS=true
        shift
        ;;
      --disable-image-cleanup)
        CLEANUP_OLD_IMAGES=false
        shift
        ;;
      --from-checkpoint)
        if [[ -z "$2" || "$2" == --* ]]; then
          echo "ERROR: --from-checkpoint requires a checkpoint name (start-ready, final)" >&2
          exit 1
        fi
        START_FROM_CHECKPOINT="$2"
        shift 2
        ;;
      --explore)
        EXPLORE_ONLY=true
        KEEP_CONTAINER=true  # Auto-enable --keep in explore mode
        shift
        ;;
      --checkpoints)
        ENABLE_CHECKPOINTS=true
        shift
        ;;
      --tcg)
        ACCEL_MODE="tcg"
        shift
        ;;
      --kvm)
        ACCEL_MODE="kvm"
        shift
        ;;
      *)
        echo "Usage: $0 [--keep] [--no-cache] [--disable-image-cleanup] [--from-checkpoint <name>] [--explore] [--checkpoints] [--tcg|--kvm]" >&2
        exit 1
        ;;
    esac
  done
}

cleanup_old_containers() {
  echo "Cleaning up any existing build containers..."
  docker ps -a --filter "name=vdsm-config" --format "{{.Names}}" | while read -r container; do
    echo "  Stopping and removing: $container"
    docker stop "$container" 2>/dev/null || true
    docker rm "$container" 2>/dev/null || true
  done
}

cleanup_old_images() {
  if [[ "$CLEANUP_OLD_IMAGES" == false ]]; then
    return
  fi

  echo "Cleaning up dangling images..."

  # Remove only dangling images that we created (have vdsm-ci.managed=true label)
  local dangling
  dangling=$(docker images -f "dangling=true" -f "label=vdsm-ci.managed=true" -q 2>/dev/null || true)

  if [[ -n "$dangling" ]]; then
    local dangling_count
    dangling_count=$(echo "$dangling" | wc -l | tr -d ' ')
    echo "  Removing $dangling_count vdsm-ci dangling image(s)..."
    echo "$dangling" | xargs docker rmi -f >/dev/null 2>&1 || true
    echo "  ✓ Cleanup complete"
  else
    echo "  No images to clean up"
  fi
}

check_container_running() {
  if ! docker ps --filter "name=$CONTAINER_NAME" --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
    echo "ERROR: Container exited. Last 15 lines of logs:" >&2
    docker logs --tail 15 "$CONTAINER_NAME" >&2
    exit 1
  fi
}

# ============================================================================
# Step Functions
# ============================================================================

boot_vdsm() {
  echo ""
  echo "Step 1: Starting VDSM container..."
  echo "Note: Port 5000 is mapped for troubleshooting during build"

  run_vdsm_container "$PATCHED_IMAGE"

  echo "Waiting for container to be running..."
  local timeout=30
  local elapsed=0
  while ! docker ps --filter "name=$CONTAINER_NAME" --filter "status=running" --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; do
    if [ $elapsed -ge $timeout ]; then
      echo "ERROR: Container failed to start within ${timeout}s" >&2
      docker logs "$CONTAINER_NAME" >&2
      exit 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  echo "✓ VDSM container is running"
}

copy_scripts() {
  echo ""
  echo "Step 2: Copying automation scripts..."
  copy_automation_script
  echo "✓ Scripts copied"
}

wait_for_web() {
  echo ""
  echo "Step 3: Waiting for VDSM web interface to be available (~10 minutes)..."
  echo "Note: Images are automatically converted to qcow2 after install by patched entry.sh"
  wait_for_dsm
  echo "✓ VDSM web interface is responding (images must be converted)"

  # Delete PAT file to reduce image size (~350MB saved)
  echo "Removing PAT file to reduce image size..."
  docker exec "$CONTAINER_NAME" rm -f /storage/*.pat
  echo "✓ PAT file removed"
}

wait_for_start_button() {
  echo ""
  echo "Step 4: Waiting for DSM start button to appear..."
  docker exec "$CONTAINER_NAME" \
    /opt/venv/bin/python /tmp/provision-dsm.py wait-for-boot --vm-ip "${DSM_VM_IP}"
  echo "✓ Start button appeared"
}

run_playwright_step() {
  local step_num="$1"
  local command="$2"
  shift 2  # Remove first two arguments, leaving any additional docker exec args

  echo ""
  echo "Step ${step_num}: Running ${command}..."

  # Create videos directory if it doesn't exist
  mkdir -p "$PWD/videos"

  docker exec "$@" \
    "$CONTAINER_NAME" \
    /opt/venv/bin/python /tmp/provision-dsm.py "${command}" --vm-ip "${DSM_VM_IP}"

  echo "✓ ${command} complete"
}

configure_admin() {
  run_playwright_step 5 configure-admin \
    -e DSM_SERVER_NAME="$DSM_SERVER_NAME" \
    -e DSM_ADMIN_USER="$DSM_ADMIN_USER" \
    -e DSM_ADMIN_PASS="$DSM_ADMIN_PASS"
}

post_wizard() {
  run_playwright_step 6 post-wizard
}

configure_system() {
  run_playwright_step 7 configure-system
}

# ============================================================================
# Main Execution
# ============================================================================

parse_args "$@"

# If using --from-checkpoint, enable checkpoints automatically
if [[ -n "$START_FROM_CHECKPOINT" ]]; then
  ENABLE_CHECKPOINTS=true
fi

# Validate --explore requires --from-checkpoint
if [[ "$EXPLORE_ONLY" == true && -z "$START_FROM_CHECKPOINT" ]]; then
  echo "ERROR: --explore requires --from-checkpoint to specify which checkpoint to restore" >&2
  echo "" >&2
  echo "Available checkpoints:" >&2
  list_checkpoints >&2
  exit 1
fi

trap cleanup EXIT

echo "============================================"
echo "  Building Pre-configured VDSM Image"
echo "============================================"
echo ""

# Auto-detect acceleration mode if set to "auto"
if [[ "$ACCEL_MODE" == "auto" ]]; then
  if [[ -e "/dev/kvm" ]]; then
    ACCEL_MODE="kvm"
    echo "Auto-detected: KVM acceleration available"
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    ACCEL_MODE="tcg"
    echo "Auto-detected: macOS detected, using TCG"
  else
    echo "ERROR: Cannot auto-detect acceleration mode." >&2
    echo "  /dev/kvm not found and platform is not macOS." >&2
    echo "  This platform requires explicit acceleration mode." >&2
    echo "  Please specify --kvm or --tcg." >&2
    exit 1
  fi
fi

# Add variant suffix to image name (unless already present)
if [[ "$IMAGE_NAME" != *"-kvm" ]] && [[ "$IMAGE_NAME" != *"-tcg" ]]; then
  IMAGE_NAME="${IMAGE_NAME}-${ACCEL_MODE}"
  FULL_IMAGE_NAME="$IMAGE_NAME:$IMAGE_TAG"
fi

echo ""
echo "Image: $FULL_IMAGE_NAME"
echo "Acceleration: $ACCEL_MODE"
echo "Server name: $DSM_SERVER_NAME"
echo "Admin user: $DSM_ADMIN_USER"
echo ""

cleanup_old_containers
cleanup_old_images

# Check PAT file exists, download if needed
if [[ ! -f "$DSM_PAT_FILE" ]]; then
  echo ""
  echo "PAT file not found, downloading DSM ${DSM_VERSION} (build ${DSM_BUILD})..."
  mkdir -p "$BASEDIR/cache"
  curl -fL "$DSM_PAT_URL" -o "$DSM_PAT_FILE"
  echo "✓ PAT file downloaded"
fi

# Build patched VDSM image if it doesn't exist or if --no-cache is used
if [[ "$IGNORE_CHECKPOINTS" == true ]] || ! docker image inspect "$PATCHED_IMAGE" >/dev/null 2>&1; then
  echo "Building patched VDSM image..."
  docker build -t "$PATCHED_IMAGE" -f "$BASEDIR/Dockerfile" "$BASEDIR"
  echo "✓ Patched image built: $PATCHED_IMAGE"
fi

# Check if flattened image already exists - if so, we're done
if [[ "$IGNORE_CHECKPOINTS" == false ]] && docker image inspect "$FULL_IMAGE_NAME" >/dev/null 2>&1; then
  echo "Found existing flattened image!"

  echo ""
  echo "============================================"
  echo "  Build Already Complete!"
  echo "============================================"
  echo ""
  echo "Image: $FULL_IMAGE_NAME"
  echo ""
  echo "To test locally:"
  echo "  docker run --rm -p 5000:5000 --cap-add NET_ADMIN --name vdsm-test $FULL_IMAGE_NAME"
  echo "  # Visit http://localhost:5000 (ready in a few seconds from snapshot)"
  echo "  # Login with: $DSM_ADMIN_USER / $DSM_ADMIN_PASS"
  echo ""
  echo "To push to registry:"
  echo "  docker push $FULL_IMAGE_NAME"
  echo ""
  echo "To rebuild from scratch: $0 --no-cache"
  echo ""
  exit 0
fi

# Determine where to start
START_AT="boot"

# If --from-checkpoint specified, use it
if [[ -n "$START_FROM_CHECKPOINT" ]]; then
  # Strip ckpt- prefix if provided
  START_FROM_CHECKPOINT="${START_FROM_CHECKPOINT#ckpt-}"

  # Map checkpoint name to starting step
  case "$START_FROM_CHECKPOINT" in
    start-ready)
      START_AT="configure"
      ;;
    final)
      START_AT="flatten"
      ;;
    *)
      echo "ERROR: Invalid checkpoint name: $START_FROM_CHECKPOINT" >&2
      echo "Valid checkpoints: start-ready, final" >&2
      exit 1
      ;;
  esac

  echo "Starting from checkpoint: $START_FROM_CHECKPOINT (forced via --from-checkpoint)"
  start_from_checkpoint "$START_FROM_CHECKPOINT"

# Otherwise, auto-detect checkpoints
elif [[ "$IGNORE_CHECKPOINTS" == false ]]; then
  if checkpoint_exists "final"; then
    START_AT="flatten"
    echo "Found checkpoint: final"
    echo "Resuming from final state (use --no-cache to rebuild from scratch)"
  elif checkpoint_exists "start-ready"; then
    START_AT="configure"
    echo "Found checkpoint: start-ready"
    echo "Resuming from start-ready state (use --no-cache to rebuild from scratch)"
    start_from_checkpoint "start-ready"
  fi
fi

if [[ "$START_AT" == "boot" ]]; then
  echo "No checkpoints found, starting from scratch"
  echo ""
fi

# If --explore flag is set, exit here
if [[ "$EXPLORE_ONLY" == true ]]; then
  echo ""
  echo "============================================"
  echo "  Explore Mode"
  echo "============================================"
  echo ""
  echo "Container is running and ready for exploration"
  echo "DSM web interface: http://localhost:5000"
  echo ""
  echo "To stop the container:"
  echo "  docker stop $CONTAINER_NAME && docker rm $CONTAINER_NAME"
  echo ""
  echo "To view logs:"
  echo "  docker logs -f $CONTAINER_NAME"
  echo ""
  exit 0
fi

# Run steps from starting point to end
if [[ "$START_AT" == "boot" ]]; then
  boot_vdsm
  copy_scripts
  wait_for_web
  wait_for_start_button
  if [[ "$ENABLE_CHECKPOINTS" == true ]]; then
    save_checkpoint "start-ready"
  fi
fi

if [[ "$START_AT" =~ ^(boot|configure)$ ]]; then
  configure_admin
  post_wizard
  configure_system
  if [[ "$ENABLE_CHECKPOINTS" == true ]]; then
    save_checkpoint "final"
  else
    # Create a QEMU snapshot even when not checkpointing
    # (required for qcow2 images to boot properly)
    echo ""
    echo "Creating QEMU snapshot..."
    create_qemu_snapshot "final"
  fi
fi

# Flattening happens for all paths (boot, configure, flatten)

# Prepare source image for flattening
echo ""
if [[ "$ENABLE_CHECKPOINTS" == true ]]; then
  SOURCE_IMAGE="$(checkpoint_image_name "final")"
else
  echo "Committing container..."
  SOURCE_IMAGE="${IMAGE_NAME}:temp-build"
  stop_and_commit "$SOURCE_IMAGE" "final"
fi

UNFLATTENED_SIZE=$(docker images "$SOURCE_IMAGE" --format "{{.Size}}")

# Flatten the image to reduce size
echo "Flattening image to reduce size..."

# Use empty context since Dockerfile.flatten only copies from other images
docker build \
  --build-arg CHECKPOINT_IMAGE="$SOURCE_IMAGE" \
  --build-arg QEMU_CPU_FLAGS="$QEMU_CPU_FLAGS" \
  --build-arg VARIANT="$ACCEL_MODE" \
  -t "$FULL_IMAGE_NAME" - < Dockerfile.flatten

# Clean up temp image if created
if [[ "$ENABLE_CHECKPOINTS" == false ]]; then
  docker rmi "$SOURCE_IMAGE" >/dev/null 2>&1 || true
fi

FLATTENED_SIZE=$(docker images "$FULL_IMAGE_NAME" --format "{{.Size}}")
echo "Image size: $UNFLATTENED_SIZE → $FLATTENED_SIZE"

tag_with_version "$FULL_IMAGE_NAME"

echo ""
echo "Running smoke test..."
"$BASEDIR/smoke-test.sh" "$FULL_IMAGE_NAME"
echo "✓ Smoke test passed"

echo ""
echo "============================================"
echo "  Build Complete!"
echo "============================================"
echo ""
echo "Image: $FULL_IMAGE_NAME"
echo ""

# List videos if any were created
if ls "$PWD/videos"/*.webm >/dev/null 2>&1; then
  echo "Videos saved to $PWD/videos/:"
  find "$PWD/videos" -name "*.webm" -exec basename {} \;
  echo ""
fi

echo "To test locally:"
echo "  docker run --rm -p 5000:5000 --cap-add NET_ADMIN --name vdsm-test $FULL_IMAGE_NAME"
echo "  # Visit http://localhost:5000 (ready in a few seconds from snapshot)"
echo "  # Login with: $DSM_ADMIN_USER / $DSM_ADMIN_PASS"
echo ""
echo "To push to registry:"
echo "  docker push $FULL_IMAGE_NAME"
echo ""
