# TODO

## Current Status

The VDSM CI image build system is functional and can create pre-configured Virtual DSM images with:

- ✅ QEMU snapshot-based checkpointing for fast rebuilds
- ✅ Automated admin account configuration via Playwright
- ✅ Bash-based checkpoint workflow (no multi-stage Dockerfile)
- ✅ qcow2 disk format conversion for snapshot support
- ✅ Two checkpoint stages: start-ready, final
- ✅ Video recording of all Playwright automation steps
- ✅ Post-wizard automation with 8 wizard screens handled
- ✅ NFS service enabled in configure-system step
- ✅ Session persistence across Playwright steps
- ✅ Auto-update of automation script when resuming from checkpoints
- ✅ Image flattening with 52% size reduction (8.6GB → 4.1GB)

## Pre-PR Work (Must Complete Before Opening PR)

### Critical Fixes

- [x] **Fix flattening skip logic** - When ckpt-final exists and --no-cache is not specified, script exits before flattening step, returning 8.6GB unflattened image instead of 5.6GB flattened image. Should check if 'latest' tag exists (flattened image), not just ckpt-final.

- [x] **Verify videos/ not tracked in git** - Check if video files are accidentally committed to git repository (would bloat history)

### Code Cleanup

- [x] **Remove legacy Playwright files** - Delete orphaned Python scripts that are no longer used (replaced by dsm_automation.py): setup_admin.py (345 lines), configure_admin.py, handle_post_wizard.py, verify_desktop.py, wait_for_boot.py, and run.sh

- [x] **Remove unused error_occurred variable** - Dead code in dsm_automation.py error handling (line 423, 442-444)

- [x] **Hardcode IMAGE_NAME instead of git derivation** - Replace complex git remote parsing with static value: `ghcr.io/vdsm-ci/vdsm-configured`

- [x] **Add EXPOSE ports to Dockerfile.flatten** - Restore port metadata documentation that was lost during flattening (5000, 3260, 445, 2049)

- [x] **Remove duplicate "Helper Functions" header** - Line 223 in build-image.sh duplicates line 32

### Quality Improvements

- [x] **Run apt-get update in Dockerfile** - Base image packages may be outdated; add `apt-get update` before package installation

- [x] **Add smoke test after flattening** - Run quick test (docker run + curl check) to verify flattened image actually boots before tagging as latest

### Critical Bugs (Found in Deep Analysis)

- [x] **Fix video path race condition in dsm_automation.py** - Line 446-447: Calling `await page.video.path()` after `await page.close()` causes race condition. Get video path before closing page.

- [x] **Add -f flag to curl in build-image.sh** - Line 416: `curl -L` without `-f` returns 0 even on HTTP errors (404/500), would write error HTML to PAT file. Change to `curl -fL`.

- [x] **Remove legacy docker-compose workflow files** - docker-compose.yml, start.sh, stop.sh are not used in main build workflow (not referenced in README/BUILD.md). Remove to avoid confusion.

### Final Steps

- [ ] **Squash all commits** - Clean up commit history before opening the first PR

## While PR is Open (Easier to Test in CI)

### CI/CD Enhancements

- [ ] **Expose videos as GitHub Actions artifacts** - Upload playwright videos from CI runs with 7-day retention for debugging CI failures

- [ ] **Add CI test to verify image starts and reaches desktop** - CI should start final image, wait for DSM to be accessible, and verify it reaches the desktop/login screen (not just that container starts)

### Testing & Reliability

- [ ] **Test checkpoint restore reliability** - Verify QEMU snapshots restore correctly and consistently across different environments

- [ ] **Verify QEMU snapshots after savevm** - Use `qemu-img snapshot -l` to confirm snapshot was created, not just check stderr

- [ ] **Checkpoint restore tests** - Automated tests that verify each checkpoint can be restored successfully

## Follow-Up PRs (Future Work)

### Code Quality

- [x] **Remove pointless exception re-raise** - dsm_automation.py line 441-442: `except Exception: raise` does nothing useful, just remove the except block

- [x] **Add directory existence check before shutil.move** - dsm_automation.py line 452: Verify `/tmp/playwright-videos` exists before moving video file

- [ ] **Replace fixed sleeps with polling** - Multiple `asyncio.sleep(2)` calls (lines 329, 339, 349, 377) should use wait_for with condition checks instead of arbitrary delays

- [x] **Extract hardcoded video path to constant** - `/tmp/playwright-videos` appears in 5+ places across build-image.sh and dsm_automation.py

- [x] **Remove debug output from build-image.sh** - Line 106: `echo "DEBUG: Checking /storage contents..."` left in production code

- [ ] **Document pre-commit setup in BUILD.md** - Config file exists but setup instructions are missing

### Feature Additions

- [ ] **Define versioning strategy** - Determine how to version images (git SHA? semantic versioning? DSM version-based?)

- [ ] **Add health checks** - Implement proper Docker health checks for the running container

- [ ] **Add CI/CD integration examples** - Show how to use these images in GitHub Actions, GitLab CI, etc.

- [ ] **Document video debugging workflow** - Add section on using recorded videos to troubleshoot wizard automation issues

### Advanced Testing

- [ ] **Automated integration tests** - Test that the final image can actually serve NFS and handle CSI operations

- [ ] **Performance benchmarks** - Document build times and compare checkpoint vs full rebuild

### Platform Support

- [ ] **Multi-architecture support** - Currently ARM64 without KVM is very slow; document x86_64 requirements

## Known Issues

- Build fails on systems with less than 20GB available Docker disk space
- ARM64 without KVM acceleration is ~10x slower (expected behavior)
- Wizard screens may vary by DSM version (current automation tested on 7.2.2-72806)
- NFS checkbox click requires clicking the styled icon div, not the input element
