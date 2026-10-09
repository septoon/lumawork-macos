#!/usr/bin/env python3
"""Check the staged tree and optionally all reachable history without printing secrets."""
import argparse
import pathlib
import re
import subprocess
import sys


def git(*args):
    return subprocess.check_output(["git", *args])


def forbidden_path(path, *, allow_markdown=False):
    parts = pathlib.PurePosixPath(path).parts
    name = parts[-1].lower()
    return (
        name.endswith(".md") and not allow_markdown
        or any(p.lower() in {"secrets", "localdata", "snapshots", "xcuserdata"} for p in parts)
        or name == ".env" or name.startswith(".env.")
        or name.startswith("secrets") and name.endswith(".xcconfig")
        or name.endswith((".local.xcconfig", ".local.plist", ".pem", ".key", ".p8", ".p12", ".pfx", ".keystore", ".jks", ".mobileprovision", ".provisionprofile", ".sqlite", ".db"))
        or name.startswith(("credentials", "session")) and name.endswith(".json")
    )


PATTERNS = {
    "private key": rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----",
    "GitHub token": rb"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})\b",
    "API key": rb"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{32,}\b",
    "AWS access key": rb"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b",
    "JWT": rb"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b",
    "URL credentials": rb"https?://[^\s/:\"']+:[^\s/@\"']+@",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--history", action="store_true")
    args = parser.parse_args()
    objects = {}
    index_paths = set()
    for entry in git("ls-files", "--stage", "-z").split(b"\0"):
        if entry:
            metadata, path = entry.split(b"\t", 1)
            objects.setdefault(metadata.split()[1].decode(), set()).add(path.decode())
            index_paths.add(path.decode())
    if args.history:
        for line in git("rev-list", "--objects", "--all").decode().splitlines():
            oid, _, path = line.partition(" ")
            if path:
                objects.setdefault(oid, set()).add(path)
    failures = 0
    blobs = 0
    for oid, paths in objects.items():
        if git("cat-file", "-t", oid).strip() != b"blob":
            continue
        blobs += 1
        data = git("cat-file", "blob", oid)
        for path in sorted(paths):
            # Previously published Markdown remains in history by explicit user choice.
            if forbidden_path(path, allow_markdown=path not in index_paths):
                print(f"BLOCKED {path}: excluded file path")
                failures += 1
            for label, pattern in PATTERNS.items():
                for match in re.finditer(pattern, data):
                    line = data[:match.start()].count(b"\n") + 1
                    print(f"BLOCKED {path}:{line}: {label} (value redacted)")
                    failures += 1
    print(f"Checked {blobs} Git blobs; {failures} findings. Heuristic scan; review staged diff as well.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
