# VDSM CI

Pre-configured Virtual DSM (Synology DSM) Docker images for CI/CD testing.

## Overview

This repository builds Docker images of Synology DSM with pre-configured admin accounts, suitable for automated testing in CI/CD pipelines. The images use QEMU snapshots for fast checkpoint/restore functionality.

**Primary use case:** Integration testing for the [Synology CSI driver](https://github.com/claytono/synology-csi) - provides ephemeral DSM instances with iSCSI and NFS services pre-configured for Kubernetes storage testing.

## Quick Start

Pull and run the pre-configured DSM image:

```bash
docker run -it --rm \
  --name vdsm-test \
  --device=/dev/kvm \
  --device=/dev/net/tun \
  --cap-add NET_ADMIN \
  -p 5000:5000 \
  ghcr.io/claytono/vdsm-ci-kvm:latest

# Wait ~30 seconds for QEMU snapshot restore
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

We provide two variants optimized for different use cases:

#### KVM Variant (Recommended for Linux)

Fast, hardware-accelerated variant for Linux systems with KVM support:

```bash
# Latest KVM variant
ghcr.io/claytono/vdsm-ci-kvm:latest

# Specific DSM version with KVM
ghcr.io/claytono/vdsm-ci-kvm:7.2.2
```

#### TCG Variant (For Mac and systems without KVM)

Portable variant using software emulation - works on all platforms:

```bash
# Latest TCG variant (uses QEMU user networking, no devices needed)
docker run -it --rm \
  --name vdsm-test \
  -p 5000:5000 \
  ghcr.io/claytono/vdsm-ci-tcg:latest

# Specific DSM version with TCG
ghcr.io/claytono/vdsm-ci-tcg:7.2.2
```

**Note:** TCG variant is slower (software emulation) but provides cross-platform compatibility, including macOS. Uses QEMU user-mode networking instead of TAP devices.

#### Development Checkpoints

```bash
# DSM booted but not configured (KVM)
ghcr.io/claytono/vdsm-ci-kvm:ckpt-start-ready

# DSM booted but not configured (TCG)
ghcr.io/claytono/vdsm-ci-tcg:ckpt-start-ready
```

### Building from Source

To build your own image:

```bash
# Build KVM variant (default)
./build-image.sh

# Build TCG variant (for cross-platform compatibility)
./build-image.sh --tcg
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
