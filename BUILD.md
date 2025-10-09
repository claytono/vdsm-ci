# Building Pre-configured VDSM Image

This document is for people who want to build, modify, or debug VDSM CI images.

**For usage instructions:** See [README.md](README.md) for how to use pre-built images.

This directory contains a bash-based build system for creating pre-configured Virtual DSM images with QEMU snapshot checkpointing.

## Quick Start

```bash
# Build KVM variant (default - fast, requires KVM)
./build-image.sh

# Build TCG variant (portable, works everywhere including Mac)
./build-image.sh --tcg
```

**Build times:**

- KVM variant: Fast (hardware acceleration)
- TCG variant: Slower (software emulation)

Checkpoint-based rebuilds are much faster for both variants.

## Build Workflow

The build uses **bash orchestration** with **QEMU snapshots** for checkpointing, not a multi-stage Dockerfile:

1. **Boot VDSM** (~10 min)
   - Downloads DSM PAT file (cached in `./cache/`)
   - Starts VDSM container
   - Converts disk to qcow2 format for snapshot support
   - Waits for DSM start button to appear
   - **Saves checkpoint:** `ckpt-start-ready`

2. **Configure DSM** (~3 min)
   - Configures admin account
   - Handles post-wizard dialog screens
   - Enables NFS service in Control Panel
   - **Saves checkpoint:** `latest` (final)

Each checkpoint is saved as a Docker image with QEMU snapshots embedded in `/storage/*.qcow2` files.

## Image Variants

### KVM vs TCG

We build two variants of each image:

**KVM Variant** (default):

- Uses hardware virtualization (KVM acceleration)
- Fast: Hardware-accelerated execution
- Requires: Linux system with `/dev/kvm` access
- Best for: CI/CD, production testing on Linux

**TCG Variant** (`--tcg` flag):

- Uses software emulation (QEMU TCG)
- Portable: Works on all platforms including macOS
- Slower: Software emulation (no hardware acceleration)
- Best for: Development on Mac, cross-platform compatibility

**Important:** Snapshots from KVM builds are incompatible with TCG and vice versa. Build with `--tcg` if you need to run on systems without KVM support.

### Platform Compatibility

| Platform | KVM Variant | TCG Variant |
|----------|-------------|-------------|
| Linux x86_64 with KVM | ✅ Fast | ✅ Slow |
| Linux x86_64 no KVM | ❌ | ✅ Slow |
| macOS (ARM64) | ❌ | ✅ Slow |

## Checkpoint System

### How Checkpoints Work

When you save a checkpoint:

1. QEMU creates a snapshot using `savevm <name>`
2. Container is committed to a new image with `ARGUMENTS="-loadvm <name>"`
3. When that image starts, QEMU automatically restores the snapshot

This allows instant restoration of DSM state without re-running automation.

### Checkpoint Images

The build creates these checkpoint images (for development/debugging):

**KVM variant:**

- `ghcr.io/claytono/vdsm-ci-kvm:ckpt-start-ready` - DSM booted, ready for setup
- `ghcr.io/claytono/vdsm-ci-kvm:latest` - Fully configured with NFS

**TCG variant:**

- `ghcr.io/claytono/vdsm-ci-tcg:ckpt-start-ready` - DSM booted, ready for setup
- `ghcr.io/claytono/vdsm-ci-tcg:latest` - Fully configured with NFS

### Resuming from Checkpoints

Speed up iteration by starting from a checkpoint:

```bash
# Resume from start-ready and continue build
./build-image.sh --from-checkpoint start-ready

# Explore DSM state at checkpoint (no automation)
./build-image.sh --from-checkpoint start-ready --explore
# Then visit http://localhost:5000
```

The `--from-checkpoint` flag automatically updates the automation script in the container, so you can iterate on `provision-dsm.py` without rebuilding from scratch.

## Video Recording

All Playwright automation steps record video to `./videos/` for troubleshooting:

- `wait-for-boot.webm` - Waiting for start button
- `configure-admin.webm` - Admin account setup
- `post-wizard.webm` - Wizard dialog handling
- `configure-system.webm` - NFS configuration

## Build Options

### Development Flags

```bash
# Keep container running after build (for inspection)
./build-image.sh --keep

# Preserve intermediate Docker images (don't cleanup)
./build-image.sh --disable-image-cleanup

# Force rebuild without cache
./build-image.sh --no-cache
```

### Environment Variables

Customize the build:

```bash
# Change image name/tag
DSM_IMAGE_NAME=ghcr.io/claytono/vdsm-ci \
DSM_IMAGE_TAG=v1.0 \
./build-image.sh

# Change DSM configuration
DSM_SERVER_NAME=my-dsm \
DSM_ADMIN_USER=admin \
DSM_ADMIN_PASS=MySecurePass123 \
./build-image.sh

# Use different DSM version (edit dsm-version.sh file)
# DSM_VERSION and DSM_BUILD are sourced from dsm-version.sh
```

## Iteration Workflow

When developing wizard automation:

```bash
# 1. Build to first checkpoint (one-time, ~10 min)
./build-image.sh --from-checkpoint start-ready

# 2. Edit provision-dsm.py

# 3. Rebuild from checkpoint (~3 min)
./build-image.sh --from-checkpoint start-ready

# 4. Check videos/ for what happened

# 5. Repeat steps 2-4 until working
```

The checkpoint is restored in a few seconds, and the updated script is automatically copied into the container.

## Playwright Automation

The build uses a single unified script: `provision-dsm.py`

### Commands

- `wait-for-boot` - Wait for DSM start button (~10 min)
- `configure-admin` - Set up admin account (~1 min)
- `post-wizard` - Handle wizard dialogs (~1 min)
- `configure-system` - Enable NFS service (~1 min)

### Running Commands Manually

```bash
# Start container from checkpoint
./build-image.sh --from-checkpoint start-ready --explore --keep

# Run automation steps manually
docker exec vdsm-config \
  /opt/venv/bin/python /tmp/provision-dsm.py configure-admin \
  --vm-ip 20.20.20.21

# Check video
ls -lh videos/configure-admin.webm
```

## Troubleshooting

### Build fails at boot stage

The boot stage waits up to 10 minutes for the start button. If it times out:

1. Check DSM PAT URL is valid and accessible
2. Ensure adequate CPU/memory allocated to Docker (4GB+ RAM recommended)
3. Check container logs: `docker logs vdsm-config`
4. Look for QEMU errors in build output

### Post-wizard step fails

Wizard screens can change between DSM versions. If automation fails:

1. Build to `start-ready` checkpoint
2. Run with `--explore` to manually inspect DSM
3. Check `videos/post-wizard.webm` to see where it failed
4. Update selectors in `provision-dsm.py`
5. Rebuild from checkpoint to test fix

### Checkpoint not found

If you see "Checkpoint 'X' does not exist":

```bash
# List available checkpoints
docker images ghcr.io/claytono/vdsm-ci --format "{{.Tag}}" | grep ckpt-

# Checkpoint names don't include the "ckpt-" prefix in --from-checkpoint
./build-image.sh --from-checkpoint start-ready  # Correct
./build-image.sh --from-checkpoint ckpt-start-ready  # Wrong
```

### Container exits immediately

Check if QEMU snapshot is valid:

```bash
# Start container
docker run -d --name vdsm-test --privileged -p 5000:5000 \
  ghcr.io/claytono/vdsm-ci-kvm:ckpt-start-ready

# Check logs
docker logs vdsm-test

# Connect to QEMU monitor and check snapshots
docker exec -it vdsm-test nc localhost 7100
# In monitor: info snapshots
```

## Testing the Image

After building, test the final image:

```bash
docker run -d \
  -p 5000:5000 \
  --cap-add NET_ADMIN \
  --name vdsm-test \
  ghcr.io/claytono/vdsm-ci-kvm:latest

# Wait ~30 seconds for QEMU snapshot restore
sleep 30

# Visit http://localhost:5000
# Login: ciadmin / F4k3Pass1!

# Verify NFS is enabled
# Control Panel > File Services > NFS tab

# Clean up
docker stop vdsm-test && docker rm vdsm-test
```

## Requirements

- **Docker** with at least 20GB available disk space
- **x86_64 architecture** (ARM64 works but is very slow without KVM)
- **Internet connection** for DSM PAT file download (~350MB)

## Image Size

The final flattened image is ~3GB, primarily due to QEMU qcow2 disk images in `/storage/`.
