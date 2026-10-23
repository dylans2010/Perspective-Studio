#!/usr/bin/env python3
"""
scripts/fetch_tools.py

Downloads Swift tool files from the GitHub repository:
https://github.com/dylans2010/SwiftCode-Mac/tree/main/SwiftCode/Backend/Assist/Tools

Usage:
    python3 scripts/fetch_tools.py [options]

Options:
    --output-dir DIR        Target output directory (default: Locally/Tools)
    --limit N               Maximum number of tool files to download
    --filter PATTERN        Filter tools matching regex pattern or substring
    --tools LIST            Comma-separated list of tool filenames or ids
    --list                  List available tools in repository and exit
    --token TOKEN           GitHub API token (or set GITHUB_TOKEN env var)
    --dry-run               Preview files to download without saving them
    --verbose               Enable debug logging
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REPO_OWNER = "dylans2010"
REPO_NAME = "SwiftCode-Mac"
REPO_BRANCH = "main"
REPO_TOOLS_PATH = "SwiftCode/Backend/Assist/Tools"

GITHUB_API_CONTENTS_URL = f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}/contents/{REPO_TOOLS_PATH}?ref={REPO_BRANCH}"
GITHUB_API_TREE_URL = f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}/git/trees/{REPO_BRANCH}?recursive=1"
RAW_BASE_URL = f"https://raw.githubusercontent.com/{REPO_OWNER}/{REPO_NAME}/{REPO_BRANCH}/{REPO_TOOLS_PATH}"


def make_request(url: str, token: str = None, retries: int = 3, backoff: float = 1.0) -> bytes:
    """Performs HTTP GET with error handling, retries, and optional GitHub auth."""
    headers = {
        "User-Agent": "Perspective-Studio-Tool-Fetcher/1.0",
        "Accept": "application/vnd.github.v3+json",
    }
    if token:
        headers["Authorization"] = f"token {token}"

    req = urllib.request.Request(url, headers=headers)
    last_err = None

    for attempt in range(1, retries + 1):
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                return response.read()
        except urllib.error.HTTPError as e:
            last_err = e
            if e.code in (403, 429):
                # Rate limited or forbidden
                reset_header = e.headers.get("X-RateLimit-Reset")
                if reset_header:
                    wait_time = max(0, int(reset_header) - int(time.time()))
                    if wait_time > 0 and wait_time < 60:
                        print(f"[!] Rate limit reached. Waiting {wait_time}s for reset...", file=sys.stderr)
                        time.sleep(wait_time + 1)
                        continue
            if attempt < retries and e.code >= 500:
                time.sleep(backoff * (2 ** (attempt - 1)))
                continue
            raise
        except (urllib.error.URLError, TimeoutError) as e:
            last_err = e
            if attempt < retries:
                time.sleep(backoff * (2 ** (attempt - 1)))
                continue
            raise

    if last_err:
        raise last_err
    raise RuntimeError(f"Failed to request {url}")


def fetch_file_list(token: str = None, verbose: bool = False) -> list[str]:
    """Fetches list of Swift tool filenames from the GitHub repository."""
    # 1. Try Contents API
    try:
        if verbose:
            print(f"[*] Querying GitHub Contents API: {GITHUB_API_CONTENTS_URL}")
        data = make_request(GITHUB_API_CONTENTS_URL, token=token)
        items = json.loads(data.decode("utf-8"))
        files = [
            item["name"]
            for item in items
            if item.get("type") == "file" and item.get("name", "").endswith(".swift")
        ]
        if files:
            return sorted(files)
    except Exception as e:
        if verbose:
            print(f"[!] Contents API failed: {e}. Falling back to Git Trees API...")

    # 2. Try Git Tree API
    try:
        if verbose:
            print(f"[*] Querying GitHub Git Trees API: {GITHUB_API_TREE_URL}")
        data = make_request(GITHUB_API_TREE_URL, token=token)
        tree = json.loads(data.decode("utf-8")).get("tree", [])
        prefix = REPO_TOOLS_PATH + "/"
        files = [
            item["path"][len(prefix):]
            for item in tree
            if item.get("path", "").startswith(prefix)
            and item.get("path", "").endswith(".swift")
            and "/" not in item.get("path", "")[len(prefix):]
        ]
        if files:
            return sorted(files)
    except Exception as e:
        if verbose:
            print(f"[!] Git Trees API failed: {e}.")

    raise RuntimeError("Could not retrieve tool list from GitHub API.")


def download_tool_file(filename: str, output_dir: str, token: str = None) -> tuple[bool, int, str]:
    """Downloads an individual tool file and writes it to disk."""
    url = f"{RAW_BASE_URL}/{urllib.parse.quote(filename)}"
    try:
        content = make_request(url, token=token)
        dest_path = os.path.join(output_dir, filename)
        os.makedirs(os.path.dirname(dest_path), exist_ok=True)
        with open(dest_path, "wb") as f:
            f.write(content)
        return True, len(content), ""
    except Exception as e:
        return False, 0, str(e)


def main():
    parser = argparse.ArgumentParser(
        description="Fetch Swift Assist tools from dylans2010/SwiftCode-Mac repository."
    )
    parser.add_argument(
        "--output-dir",
        default="Locally/Tools",
        help="Target directory to store fetched tools (default: Locally/Tools)",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Maximum number of tools to download",
    )
    parser.add_argument(
        "--filter",
        default=None,
        help="Filter tools by substring or regex pattern (case-insensitive)",
    )
    parser.add_argument(
        "--tools",
        default=None,
        help="Comma-separated list of specific tool filenames to download",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="List available tools and exit without downloading",
    )
    parser.add_argument(
        "--token",
        default=os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN"),
        help="GitHub Personal Access Token for higher rate limits",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be downloaded without actually downloading",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Enable detailed diagnostic logging",
    )

    args = parser.parse_args()

    print("==================================================")
    print("  Perspective-Studio Assist Tool Fetcher")
    print("==================================================")

    # 1. Fetch tool listings
    print("[*] Discovering available tools from GitHub...")
    try:
        all_tools = fetch_file_list(token=args.token, verbose=args.verbose)
    except Exception as e:
        print(f"[!] Error fetching tool catalog: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"[+] Found {len(all_tools)} tool files in repository.")

    if args.list:
        print("\nAvailable tools:")
        for tool in all_tools:
            print(f"  - {tool}")
        sys.exit(0)

    # 2. Filter tools
    selected_tools = all_tools

    if args.tools:
        requested = [
            t.strip() if t.strip().endswith(".swift") else f"{t.strip()}.swift"
            for t in args.tools.split(",")
            if t.strip()
        ]
        # Match case-insensitively or exact
        normalized_map = {t.lower(): t for t in all_tools}
        matched = []
        for req in requested:
            if req.lower() in normalized_map:
                matched.append(normalized_map[req.lower()])
            else:
                # Substring matching
                sub = [t for t in all_tools if req.lower().replace(".swift", "") in t.lower()]
                if sub:
                    matched.extend(sub)
                else:
                    print(f"[?] Warning: Requested tool '{req}' not found in remote repository.")
        selected_tools = sorted(list(set(matched)))

    if args.filter:
        regex = re.compile(args.filter, re.IGNORECASE)
        selected_tools = [t for t in selected_tools if regex.search(t)]

    if args.limit and args.limit > 0:
        selected_tools = selected_tools[: args.limit]

    print(f"[*] Selected {len(selected_tools)} tools for download into '{args.output_dir}'.")

    if not selected_tools:
        print("[!] No tools matched criteria. Exiting.")
        sys.exit(0)

    if args.dry_run:
        print("\n[Dry Run] Tools that would be downloaded:")
        for t in selected_tools:
            print(f"  - {t}")
        sys.exit(0)

    # 3. Download tools
    os.makedirs(args.output_dir, exist_ok=True)
    success_count = 0
    fail_count = 0
    total_bytes = 0

    print("\nStarting downloads...")
    for idx, tool in enumerate(selected_tools, 1):
        print(f"  [{idx}/{len(selected_tools)}] Fetching {tool}...", end="", flush=True)
        ok, byte_count, err = download_tool_file(tool, args.output_dir, token=args.token)
        if ok:
            success_count += 1
            total_bytes += byte_count
            print(f" OK ({byte_count / 1024:.1f} KB)")
        else:
            fail_count += 1
            print(f" FAILED: {err}")

    print("\n--------------------------------------------------")
    print(f"Finished! Successfully downloaded {success_count}/{len(selected_tools)} tools ({total_bytes / 1024:.1f} KB).")
    if fail_count > 0:
        print(f"[!] Warning: {fail_count} files failed to download.")
        sys.exit(1)


if __name__ == "__main__":
    main()
