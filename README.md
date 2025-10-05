# VDSM CI

Pre-configured Virtual DSM (Synology DSM) Docker images for CI/CD testing.

## Overview

This repository builds Docker images of Synology DSM with pre-configured admin accounts, suitable for automated testing in CI/CD pipelines. The images use QEMU snapshots for fast checkpoint/restore functionality.

**Primary use case:** Integration testing for the [Synology CSI driver](https://github.com/claytono/synology-csi) - provides ephemeral DSM instances with iSCSI and NFS services pre-configured for Kubernetes storage testing.

## Quick Start

Pull and run the pre-configured DSM image:

```bash
docker run -d \
  --name vdsm-test \
  --privileged \
  -p 5000:5000 \
  ghcr.io/claytono/vdsm-ci:latest

# Wait ~30 seconds for QEMU snapshot restore
sleep 30

# Access DSM at http://localhost:5000
```

**Login credentials:**

- Username: `ciadmin`
- Password: `F4k3Pass1!`

**What's included:**

- ✅ Admin account pre-configured
- ✅ NFS, SMB and iSCSI services enabled
- ✅ All setup wizards completed
- ✅ Boots in ~30 seconds from QEMU snapshot

**Exposed ports:**

- `5000` - DSM web interface (HTTP)
- `2049` - NFS
- `3260` - iSCSI
- `445` - SMB

### Available Images

```bash
# Latest stable release
ghcr.io/claytono/vdsm-ci:latest

# Specific DSM version
ghcr.io/claytono/vdsm-ci:7.2.2

# Development checkpoint (DSM booted but not configured)
ghcr.io/vdsm-ci/vdsm-ci:ckpt-start-ready
```

### Building from Source

To build your own image:

```bash
./build-image.sh
```

See [BUILD.md](BUILD.md) for complete build documentation.

## How It Works

VDSM CI uses QEMU snapshots to create fast-booting DSM instances:

1. **Build time:** DSM is installed, configured, and a QEMU snapshot is saved
2. **Run time:** Container restores from snapshot and boots in ~30 seconds
3. **Result:** Fully configured DSM without waiting for installation

The images use qcow2 disk format to embed QEMU snapshots directly in the Docker image.

## Contributing

To build or modify the images, see [BUILD.md](BUILD.md).
