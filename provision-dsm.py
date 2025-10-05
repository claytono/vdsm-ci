#!/usr/bin/env python3
"""DSM automation tool for VDSM setup and configuration.

This script runs inside the Docker container and automates DSM setup via Playwright.
"""

import asyncio
import argparse
import ipaddress
import os
import sys
import time
import urllib.request
import urllib.error

from playwright.async_api import (
    Page,
    TimeoutError as PlaywrightTimeoutError,
    async_playwright,
)

# Video recording directory (mounted from host's ./videos directory)
VIDEO_DIR = "/tmp/playwright-videos"


def wait_for_http(url: str, timeout: int = 600) -> None:
    """Wait for HTTP port to respond."""
    print(f"[dsm] Waiting for {url} to respond...", flush=True)
    start = time.time()
    last_print = 0
    while time.time() - start < timeout:
        try:
            urllib.request.urlopen(url, timeout=1)
            print(f"[dsm] ✓ {url} is responding", flush=True)
            return
        except (urllib.error.URLError, OSError):
            elapsed = int(time.time() - start)
            if elapsed - last_print >= 10:
                print(f"[dsm] Still waiting... ({elapsed}s/{timeout}s)", flush=True)
                last_print = elapsed
            time.sleep(1)

    raise TimeoutError(f"Timeout waiting for {url} to respond after {timeout}s")


async def wait_for_boot(page: Page, base_url: str) -> None:
    """Wait for DSM to boot and show the start button."""
    print(f"[dsm] wait-for-boot: Connecting with Playwright to {base_url}", flush=True)

    await page.goto(base_url, wait_until="domcontentloaded", timeout=180_000)
    print(f"[dsm] wait-for-boot: Navigated to {base_url}", flush=True)

    await page.wait_for_load_state("networkidle", timeout=180_000)
    print(f"[dsm] wait-for-boot: Current URL: {page.url}", flush=True)

    # Wait for start button to appear
    start_selector = "button.welcome-page-btn"
    print("[dsm] wait-for-boot: Waiting for start button...", flush=True)

    await page.wait_for_function(
        "selector => document.querySelector(selector) !== null",
        arg=start_selector,
        timeout=600_000,  # 10 minutes for initial boot
    )

    print("[dsm] wait-for-boot: ✓ Start button detected - DSM is ready!", flush=True)


async def click_start_button(page: Page) -> None:
    """Click the initial start button."""
    print("[dsm] configure-admin: Clicking start button", flush=True)
    await page.wait_for_selector(
        "button.welcome-page-btn", state="visible", timeout=120_000
    )
    await page.click("button.welcome-page-btn")
    print("[dsm] configure-admin: ✓ Start button clicked", flush=True)


async def fill_admin_form(
    page: Page, *, server_name: str, admin_user: str, admin_pass: str
) -> None:
    """Fill in the administrator form."""
    print("[dsm] configure-admin: Filling administrator form", flush=True)

    # Wait for and identify the admin form
    admin_form_identifier = page.locator(
        "div.welcome-step-title >> text=/Get started with your VirtualDSM/"
    )
    await admin_form_identifier.wait_for(state="visible", timeout=120_000)

    await page.wait_for_selector("#syno-0", state="visible", timeout=120_000)

    await page.fill("#syno-0", server_name)
    await page.fill("#syno-1", admin_user)
    await page.fill("#syno-2", admin_pass)
    await page.fill("#syno-3", admin_pass)

    await page.wait_for_selector("button.v-btn-main", state="visible", timeout=10_000)
    await page.click("button.v-btn-main")
    print("[dsm] configure-admin: ✓ Administrator form submitted", flush=True)

    # Wait for the admin form to disappear (DSM has processed and saved the config)
    print("[dsm] configure-admin: Waiting for configuration to be saved...", flush=True)
    await admin_form_identifier.wait_for(state="hidden", timeout=180_000)
    print("[dsm] configure-admin: ✓ Configuration saved", flush=True)


async def configure_admin(page: Page, base_url: str) -> None:
    """Configure DSM admin account."""
    server_name = os.getenv("DSM_SERVER_NAME", "vdsm-ci")
    admin_user = os.getenv("DSM_ADMIN_USER", "ciadmin")
    admin_pass = os.getenv("DSM_ADMIN_PASS", "F4k3Pass1!")

    print(f"[dsm] configure-admin: Connecting to {base_url}", flush=True)
    print(f"[dsm] configure-admin: Server name: {server_name}", flush=True)
    print(f"[dsm] configure-admin: Admin user: {admin_user}", flush=True)

    await page.goto(base_url, wait_until="domcontentloaded", timeout=180_000)
    await page.wait_for_load_state("networkidle", timeout=180_000)

    await click_start_button(page)
    await fill_admin_form(
        page, server_name=server_name, admin_user=admin_user, admin_pass=admin_pass
    )

    print("[dsm] configure-admin: ✓ Admin configuration complete", flush=True)


async def handle_post_wizard(page: Page, base_url: str) -> None:
    """Handle post-wizard dialogs and prompts using state machine approach."""

    async def configure_updates_screen(page: Page):
        """Click the 'notify me' radio button for manual updates."""
        radio = page.locator(
            "div.v-radio-wrapper[syno-id='welcome-app-select-update-radio-notify']"
        )
        await radio.click()
        await asyncio.sleep(0.5)  # Brief pause for UI to update

    async def close_notification_setup(page: Page):
        """Close the notification setup panel by clicking the close button."""
        # Find the notification panel with the "Notification Setup" title
        panel = page.locator(
            "div.v-notification-panel:has(div.v-notification-title:text('Notification Setup'))"
        )
        await panel.wait_for(state="visible", timeout=10_000)

        # Click the close button within this specific panel
        close_btn = panel.locator("i.close-btn.window-tool-close")
        await close_btn.click()
        await asyncio.sleep(0.5)  # Brief pause for UI to update

    # Define wizard screens with their identifiers and actions
    wizard_screens = [
        {
            "name": "Update Options",
            "identifier": "div.welcome-step-title >> text=/Select an update option/",
            "action": configure_updates_screen,  # Custom action before clicking button
            "button": "button.v-btn-main",  # Next button
        },
        {
            "name": "Synology Account",
            "identifier": "div.welcome-step-title >> text=/Create a Synology Account/",
            "button": "button[syno-id='welcome-app-wizard-fbar-back']",  # Skip button
        },
        {
            "name": "User Experience",
            "identifier": "div.welcome-step-title >> text=/Opt-in for a better user experience/",
            "button": "button[syno-id='welcome-app-wizard-fbar-next']",  # Submit button
        },
        {
            "name": "File Access Promotion",
            "identifier": "div.title >> text=/Securely Access and Share Files From Anywhere/",
            "button": "button[syno-id='syno-promotion-preinstall-btn-skip']",  # No, thanks button
        },
        {
            "name": "2FA Promotion",
            "identifier": "div.title >> text=/Enable 2-Factor Authentication \\(2FA\\)/",
            "button": "button[syno-id='syno-promotion-ss-btn-skip']",  # No, thanks button
        },
        {
            "name": "Adaptive MFA Promotion",
            "identifier": "div.title >> text=/Protect your account with Adaptive MFA/",
            "button": "button[syno-id='syno-promotion-manually-amfa-btn-give-up']",  # I don't want to secure my account
        },
        {
            "name": "MFA Warning Confirmation",
            "identifier": "div.dialog-content >> text=/We strongly recommend enabling 2FA or Adaptive MFA/",
            "button": "button[syno-id='promotion-app-window-msgbox-fbar-commit']",  # OK button
        },
        {
            "name": "Notification Setup",
            "identifier": "div.v-notification-title >> text=/Notification Setup/",
            "action": close_notification_setup,  # Custom action to click close button
        },
        {
            "name": "Notification Setup Reminder",
            "identifier": "div.dialog-content >> text=/You can enable notifications later/",
            "button": "button[syno-id='window-manager-msg-box-fbar-commit']",  # OK button
        },
    ]

    print(f"[dsm] post-wizard: Connecting to {base_url}", flush=True)

    # Retry page navigation to handle network changes
    max_retries = 5
    for retry in range(max_retries):
        try:
            await page.goto(base_url, wait_until="domcontentloaded", timeout=180_000)
            await page.wait_for_load_state("networkidle", timeout=180_000)
            break
        except Exception as e:
            if retry < max_retries - 1:
                wait_time = 5 * (retry + 1)  # Linear backoff: 5s, 10s, 15s, 20s
                print(
                    f"[dsm] post-wizard: Navigation failed ({e.__class__.__name__}), waiting {wait_time}s before retry {retry + 1}/{max_retries}...",
                    flush=True,
                )
                await asyncio.sleep(wait_time)
            else:
                print(
                    f"[dsm] post-wizard: Navigation failed after {max_retries} attempts",
                    flush=True,
                )
                raise

    print("[dsm] post-wizard: Handling post-wizard screens", flush=True)

    all_screen_names = {screen["name"] for screen in wizard_screens}
    screens_seen = set()
    timeout_seconds = 300  # 5 minutes
    start_time = time.time()
    consecutive_no_match = 0

    while True:
        elapsed = time.time() - start_time
        if elapsed > timeout_seconds:
            unseen = all_screen_names - screens_seen
            print(
                f"[dsm] post-wizard: FATAL - Timeout after {timeout_seconds}s",
                flush=True,
            )
            print(
                f"[dsm] post-wizard: Screens seen: {', '.join(sorted(screens_seen))}",
                flush=True,
            )
            print(
                f"[dsm] post-wizard: Screens NOT seen: {', '.join(sorted(unseen))}",
                flush=True,
            )
            raise TimeoutError(
                f"Post-wizard automation timed out after {timeout_seconds}s. Missing screens: {', '.join(sorted(unseen))}"
            )

        # Check if we've seen all screens
        if screens_seen == all_screen_names:
            print(
                f"[dsm] post-wizard: All {len(all_screen_names)} expected screens handled",
                flush=True,
            )
            break

        await asyncio.sleep(1)  # Brief pause between checks

        # Check each known screen
        screen_found = False
        for screen in wizard_screens:
            try:
                # Check if this screen's identifier is visible
                identifier = page.locator(screen["identifier"])
                if await identifier.is_visible():
                    screen_found = True
                    screen_name = screen["name"]

                    # Skip if we've already processed this screen
                    if screen_name in screens_seen:
                        continue

                    screens_seen.add(screen_name)
                    print(
                        f"[dsm] post-wizard: Detected screen: {screen_name} ({len(screens_seen)}/{len(all_screen_names)})",
                        flush=True,
                    )

                    # Execute custom action if defined
                    if "action" in screen:
                        await screen["action"](page)
                        print(
                            f"[dsm] post-wizard: Executed action for {screen_name}",
                            flush=True,
                        )

                    # Click the button for this screen (if defined)
                    if "button" in screen:
                        button = page.locator(screen["button"])
                        # Use first() to handle cases where multiple matching elements exist
                        await button.first.wait_for(state="visible", timeout=10_000)
                        await button.first.click()
                        print(
                            f"[dsm] post-wizard: Clicked button for {screen_name}",
                            flush=True,
                        )

                    # Wait for the identifier to disappear (screen changed)
                    await identifier.wait_for(state="hidden", timeout=30_000)
                    print(
                        f"[dsm] post-wizard: Screen changed from {screen_name}",
                        flush=True,
                    )

                    # Wait for navigation to settle
                    await page.wait_for_load_state("networkidle", timeout=30_000)
                    break

            except PlaywrightTimeoutError:
                # This screen's identifier not found or action timed out
                continue
            except Exception as e:
                print(
                    f"[dsm] post-wizard: FATAL ERROR handling screen {screen['name']}: {e.__class__.__name__}: {e}",
                    flush=True,
                )
                raise

        if not screen_found:
            consecutive_no_match += 1
            # If we haven't found any screens for 30 seconds (30 iterations), we're probably done
            if consecutive_no_match >= 30:
                print(
                    "[dsm] post-wizard: No screens detected for 30 seconds, finishing",
                    flush=True,
                )
                break
        else:
            consecutive_no_match = 0

    # Report which screens we saw and which we didn't
    all_screen_names = {screen["name"] for screen in wizard_screens}
    unseen_screens = all_screen_names - screens_seen

    print(
        f"[dsm] post-wizard: Screens encountered: {', '.join(sorted(screens_seen)) if screens_seen else 'none'}",
        flush=True,
    )

    if unseen_screens:
        print(
            f"[dsm] post-wizard: Screens not encountered: {', '.join(sorted(unseen_screens))}",
            flush=True,
        )
        print(
            "[dsm] post-wizard: Note - Different DSM versions/configs may show different wizard screens",
            flush=True,
        )
    else:
        print(
            "[dsm] post-wizard: All expected wizard screens were encountered",
            flush=True,
        )

    print("[dsm] post-wizard: ✓ Post-wizard handling complete", flush=True)
    await asyncio.sleep(2)  # Brief pause before next steps


async def configure_system(page: Page, base_url: str) -> None:
    """Configure DSM system settings."""
    screenshot_path = os.getenv("PLAYWRIGHT_SCREENSHOT", "/tmp/dsm-desktop.png")

    print(f"[dsm] configure-system: Connecting to {base_url}", flush=True)

    await page.goto(base_url, wait_until="domcontentloaded", timeout=60_000)
    await page.wait_for_load_state("networkidle", timeout=60_000)

    print("[dsm] configure-system: Waiting for DSM desktop...", flush=True)
    await page.wait_for_selector(
        "div[elementtiming='desktop-item-title'] >> text=/Package\\s*Center/",
        state="visible",
        timeout=60_000,
    )
    print("[dsm] configure-system: ✓ DSM desktop detected", flush=True)

    # Open Control Panel
    print("[dsm] configure-system: Opening Control Panel...", flush=True)
    control_panel = page.locator(
        "li[syno-id='SYNO.SDS.AdminCenter.Application'].icon-item"
    )
    await control_panel.wait_for(state="visible", timeout=30_000)
    await control_panel.click()
    print("[dsm] configure-system: Control Panel clicked", flush=True)

    # Wait for Control Panel to open
    await asyncio.sleep(2)

    # Open File Services
    print("[dsm] configure-system: Opening File Services...", flush=True)
    file_services = page.locator("div[fn='SYNO.SDS.AdminCenter.FileService.Main']")
    await file_services.wait_for(state="visible", timeout=30_000)
    await file_services.click()
    print("[dsm] configure-system: File Services opened", flush=True)

    # Wait for File Services to load
    await asyncio.sleep(2)

    # Switch to NFS tab
    print("[dsm] configure-system: Switching to NFS tab...", flush=True)
    nfs_tab = page.locator("span.x-tab-strip-text >> text=/^NFS$/")
    await nfs_tab.wait_for(state="visible", timeout=30_000)
    await nfs_tab.click()
    print("[dsm] configure-system: NFS tab clicked", flush=True)

    # Wait for tab to switch
    await asyncio.sleep(1)

    # Enable NFS service
    print("[dsm] configure-system: Enabling NFS service...", flush=True)

    # Click the styled checkbox icon div (the visual element that users actually click)
    nfs_icon = page.locator("input[name='enable_nfs'] + div.syno-ux-checkbox-icon")
    await nfs_icon.wait_for(state="visible", timeout=30_000)
    await nfs_icon.click()
    print("[dsm] configure-system: NFS service checkbox icon clicked", flush=True)

    # Wait a moment for the UI to update
    await asyncio.sleep(1)

    # Click Apply button
    print("[dsm] configure-system: Clicking Apply...", flush=True)
    apply_button = page.locator("button.x-btn-text >> text=/^Apply$/")
    await apply_button.wait_for(state="visible", timeout=30_000)
    await apply_button.click()
    print("[dsm] configure-system: Apply clicked", flush=True)

    # Wait for "Changes applied" message
    print("[dsm] configure-system: Waiting for changes to be applied...", flush=True)
    success_message = page.locator(
        "div.syno-ux-statusbar-success >> text=/Changes applied/"
    )
    await success_message.wait_for(state="visible", timeout=30_000)
    print("[dsm] configure-system: Changes applied successfully", flush=True)

    # Wait 5 more seconds
    await asyncio.sleep(5)

    # Take screenshot
    if screenshot_path:
        os.makedirs(os.path.dirname(screenshot_path), exist_ok=True)
        await page.screenshot(path=screenshot_path, full_page=True)
        print(
            f"[dsm] configure-system: Screenshot saved to {screenshot_path}", flush=True
        )

    print("[dsm] configure-system: ✓ System configuration complete", flush=True)


async def run(command: str, vm_ip: str) -> int:
    """Run the specified automation command."""
    base_url = os.getenv("DSM_BASE_URL", f"http://{vm_ip}:5000")
    storage_state_file = "/tmp/dsm-storage-state.json"
    print(f"[dsm] Running command: {command} against {base_url}", flush=True)

    # For wait-for-boot, check HTTP first before starting Playwright
    if command == "wait-for-boot":
        wait_for_http(base_url, timeout=600)

    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=True,
            args=[
                "--disable-gpu",
                "--disable-software-rasterizer",
                "--use-gl=swiftshader",
            ],
        )

        # Load saved storage state if it exists
        context_options = {}
        if os.path.exists(storage_state_file):
            print(
                f"[dsm] Loading saved browser state from {storage_state_file}",
                flush=True,
            )
            context_options["storage_state"] = storage_state_file

        # Enable video recording for all commands
        context_options["record_video_dir"] = VIDEO_DIR
        context_options["record_video_size"] = {"width": 1280, "height": 720}

        context = await browser.new_context(**context_options)
        page = await context.new_page()

        # Set timeout based on command
        if command == "wait-for-boot":
            page.set_default_timeout(600_000)  # 10 minutes for boot
        else:
            page.set_default_timeout(180_000)  # 3 minutes for others

        try:
            if command == "wait-for-boot":
                await wait_for_boot(page, base_url)
            elif command == "configure-admin":
                await configure_admin(page, base_url)
                # Save browser state (cookies, localStorage, etc.) for subsequent steps
                await context.storage_state(path=storage_state_file)
                print(f"[dsm] Saved browser state to {storage_state_file}", flush=True)
            elif command == "post-wizard":
                await handle_post_wizard(page, base_url)
                # Update saved state after post-wizard
                await context.storage_state(path=storage_state_file)
                print(
                    f"[dsm] Updated browser state in {storage_state_file}", flush=True
                )
            elif command == "configure-system":
                await configure_system(page, base_url)
            else:
                print(
                    f"[dsm] ERROR: Unknown command: {command}",
                    file=sys.stderr,
                    flush=True,
                )
                return 1
        finally:
            # Save and rename video before closing (even if error occurred)
            try:
                # Get video path before closing page to avoid race condition
                video_path = await page.video.path()
                await page.close()

                # Rename video to include command name
                import shutil

                video_dir = os.path.dirname(video_path)
                os.makedirs(video_dir, exist_ok=True)
                new_video_path = os.path.join(video_dir, f"{command}.webm")
                shutil.move(video_path, new_video_path)
                print(f"[dsm] {command}: Video saved to {new_video_path}", flush=True)
            except Exception as e:
                print(
                    f"[dsm] Warning: Failed to save video: {e}",
                    file=sys.stderr,
                    flush=True,
                )

            await context.close()
            await browser.close()

    return 0


def main():
    parser = argparse.ArgumentParser(description="DSM automation tool")
    parser.add_argument(
        "command",
        choices=["wait-for-boot", "configure-admin", "post-wizard", "configure-system"],
        help="Automation command to run",
    )
    parser.add_argument(
        "--vm-ip", required=True, type=str, help="IPv4/IPv6 address of the VM"
    )
    args = parser.parse_args()

    # Validate IP early
    try:
        ipaddress.ip_address(args.vm_ip)
    except ValueError as e:
        print(f"[dsm] ERROR: invalid --vm-ip: {e}", file=sys.stderr, flush=True)
        sys.exit(2)

    try:
        exit_code = asyncio.run(run(args.command, args.vm_ip))
    except Exception as exc:
        print(f"[dsm] ERROR: {exc}", file=sys.stderr, flush=True)
        raise

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
