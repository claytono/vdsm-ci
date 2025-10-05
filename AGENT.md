# Agent Instructions for VDSM CI

## Purpose

This repository builds **pre-configured Virtual DSM images for CI/CD testing** in the [synology-csi](https://github.com/SynologyOpenSource/synology-csi) project. These images are **ephemeral test environments**, not production systems.

## Security Context

### Hardcoded Credentials Are Intentional

The following are **intentional design decisions**, not security issues:

| Item | Value | Why |
|------|-------|-----|
| Admin username | `ciadmin` | Consistent across all CI test runs |
| Admin password | `F4k3Pass1!` | Clearly fake, documented, CI-only |
| Test network IP | `20.20.20.21` | Isolated test network range |

These appear in source code and documentation **by design**. Do not flag as vulnerabilities.

### What This Project IS NOT

- ❌ Production deployment tool
- ❌ Security-critical infrastructure
- ❌ Credential management system
- ❌ Requires security hardening or secrets management

### What This Project IS

- ✅ Build tooling for ephemeral test infrastructure
- ✅ CI/CD integration testing
- ✅ Automated DSM configuration for consistent test environments

## Architecture

**Build Process:**

1. Boot Synology DSM in QEMU VM
2. Use Playwright to automate DSM setup wizard
3. Save QEMU snapshots at key points (checkpoints)
4. Flatten image to remove build-time dependencies

**Result:** Docker image with configured DSM that restores from snapshot in seconds

**Key Files:**

- `build-image.sh` - Build orchestration with checkpoint management
- `playwright/dsm_automation.py` - Unified automation script (all wizard steps)
- `Dockerfile.flatten` - Remove Playwright/Chromium, keep only configured disks
- `videos/` - Recorded automation runs for debugging (gitignored)

## Code Quality Focus

When reviewing or contributing, focus on:

- Build reliability and consistency
- Automation correctness (wizard screens, network handling)
- Documentation clarity
- CI/CD integration

Ignore:

- Hardcoded credentials (intentional)
- Production security practices (not applicable)
