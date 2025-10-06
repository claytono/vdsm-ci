#!/usr/bin/env python3
"""Scrape the latest DSM version for VirtualDSM from Synology API.

This script fetches the latest DSM version and build number from
Synology's release notes API by checking all available major.minor versions.
"""

import json
import os
import re
import sys
import urllib.request


def scrape_dsm_version():
    """Scrape the latest DSM version from Synology release notes API."""
    # First, get the list of available versions
    url = "https://www.synology.com/api/releaseNote/findChangeLog?identify=DSM&lang=en-us&model=VirtualDSM"

    print(f"Fetching {url}...", file=sys.stderr)

    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            data = json.loads(response.read().decode("utf-8"))
    except Exception as e:
        print(f"ERROR: Failed to fetch URL: {e}", file=sys.stderr)
        return None

    # Get available version series from verList
    try:
        ver_list = data["info"]["verList"]
        versions_dict = data["info"]["versions"]["DSM"]
    except (KeyError, TypeError) as e:
        print(f"ERROR: Unexpected API response format: {e}", file=sys.stderr)
        return None

    # Find the latest major.minor version (first in verList excluding "All versions")
    latest_series = None
    for ver in ver_list:
        if ver["value"] != "all_versions":
            latest_series = ver["value"]
            break

    if not latest_series:
        print("ERROR: No version series found", file=sys.stderr)
        return None

    print(f"Latest series: {latest_series}", file=sys.stderr)

    # Get the versions for this series
    try:
        versions = versions_dict[latest_series]
    except KeyError:
        print(f"ERROR: No versions found for series {latest_series}", file=sys.stderr)
        return None

    if not versions:
        print(f"ERROR: Empty version list for series {latest_series}", file=sys.stderr)
        return None

    # Get the first (latest) version
    # Format is like "7.2.2-72806 Update 4" or "7.2.2-72806"
    latest_version_str = versions[0]["version"]
    print(f"Found version string: {latest_version_str}", file=sys.stderr)

    # Extract version and build number
    match = re.search(r"(\d+\.\d+\.\d+)-(\d+)", latest_version_str)
    if not match:
        print(
            f"ERROR: Could not parse version from: {latest_version_str}",
            file=sys.stderr,
        )
        return None

    version = match.group(1)  # e.g., "7.2.2"
    build = match.group(2)  # e.g., "72806"

    print(f"Extracted version: {version}, build: {build}", file=sys.stderr)
    return {"version": version, "build": build}


def update_version_file(version: str, build: str, file_path: str = "dsm-version.sh"):
    """Update the dsm-version.sh file with new version and build."""
    content = f"""#!/usr/bin/env bash
# DSM version configuration
# These variables are sourced by build-image.sh and GitHub Actions
export DSM_VERSION="{version}"
export DSM_BUILD="{build}"
"""
    with open(file_path, "w") as f:
        f.write(content)
    print(f"Updated {file_path}: {version}-{build}", file=sys.stderr)


def main():
    """Main entry point."""
    import argparse

    parser = argparse.ArgumentParser(
        description="Scrape latest DSM version from Synology release notes"
    )
    parser.add_argument(
        "--update-file",
        action="store_true",
        help="Update dsm-version.sh file with scraped version",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output version info as JSON",
    )
    args = parser.parse_args()

    result = scrape_dsm_version()

    if result is None:
        sys.exit(1)

    version = result["version"]
    build = result["build"]

    if args.update_file:
        update_version_file(version, build)

    # Write to GitHub Actions output if running in GitHub Actions
    github_output = os.getenv("GITHUB_OUTPUT")
    if github_output:
        with open(github_output, "a") as f:
            f.write(f"version={version}\n")
            f.write(f"build={build}\n")
        print(
            f"Wrote to GITHUB_OUTPUT: version={version}, build={build}", file=sys.stderr
        )

    if args.json or not args.update_file:
        output = {
            "version": version,
            "build": build,
            "full_version": f"{version}-{build}",
        }
        print(json.dumps(output, indent=2))


if __name__ == "__main__":
    main()
