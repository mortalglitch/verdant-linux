#!/usr/bin/env python3
"""
Verdant Linux release changelog generator.

Compares the two most recent published date-indexed tags of the default
stream (e.g. 44-20261104.1 vs 44-20261028.3) and writes a GitHub Release
body that lists:

  * major package versions (kernel, Umbriel, Noctalia, ...)
  * every RPM added / changed / removed between the two images (SBOM diff)
  * the commits between the two builds (from the OCI revision label)

Adapted from ublue-os/aurora's .github/changelogs.py (Apache-2.0),
simplified for a single image and a single stream.

Usage:
  python3 .github/changelogs.py <target> <output.env> <changelog.md> \
      [--pretty TEXT] [--workdir DIR] [--handwritten TEXT]

Requires: skopeo, oras, zstd, and a git checkout of this repo (for commits).
The SBOM must already be attached to the pushed image (see `just attach-sbom`).
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from collections import defaultdict

REGISTRY = "ghcr.io/mortalglitch/"
IMAGE = "verdant-linux"
REPO = "https://github.com/mortalglitch/verdant-linux"

RETRIES = 3
RETRY_WAIT = 5
EPOCH_PATTERN = re.compile(r"^\d+:")
FEDORA_PATTERN = re.compile(r"\.fc\d\d")

# (display name, rpm name) — shown in the "Major packages" table
MAJOR_PACKAGES = [
    ("Kernel", "kernel-core"),
    ("Umbriel", "umbriel-nightly"),
    ("Noctalia", "noctalia"),
    ("Noctalia Greeter", "noctalia-greeter"),
    ("greetd", "greetd"),
    ("Ghostty", "ghostty"),
    ("Podman", "podman"),
    ("Bootc", "bootc"),
    ("Flatpak", "flatpak"),
    ("OSTree", "ostree"),
    ("RPM-OSTree", "rpm-ostree"),
]

# Packages whose changes are only reported in the "Major packages" table,
# so they don't also show up in the long package list.
BLACKLIST_VERSIONS = [pkg for _, pkg in MAJOR_PACKAGES] + ["kernel"]

PATTERN_ADD = "\n| ✨ | {name} | | {version} |"
PATTERN_CHANGE = "\n| 🔄 | {name} | {prev} | {new} |"
PATTERN_REMOVE = "\n| ❌ | {name} | {version} | |"
PATTERN_PKGREL_CHANGED = "{prev} ➡️ {new}"
PATTERN_PKGREL = "{version}"

PACKAGES_FORMAT = "### Packages\n| | Name | Previous | New |\n| --- | --- | --- | --- |{changes}\n\n"
COMMITS_FORMAT = "### Commits\n| Hash | Subject | Author |\n| --- | --- | --- |{commits}\n\n"
COMMIT_FORMAT = f"\n| **[{{short}}]({REPO}/commit/{{githash}})** | {{subject}} | {{author}} |"

CHANGELOG_TITLE = "{tag}: {pretty}"

REBASE_SECTION = """\
### How to rebase
If you are already running Verdant, a normal upgrade picks this release up:
```bash
sudo bootc upgrade
```

To switch to Verdant, or to pin this exact build:
```bash
sudo bootc switch --image {registry}{image}:{curr}
```
"""


def get_manifests(target: str) -> dict:
    """Inspect the published image for a stream tag (e.g. 44)."""
    image = f"docker://{REGISTRY}{IMAGE}:{target}"
    print(f"Getting {IMAGE}:{target} manifest.")
    for i in range(RETRIES):
        try:
            output = subprocess.run(
                ["skopeo", "inspect", image], check=True, stdout=subprocess.PIPE
            ).stdout
            return json.loads(output)
        except subprocess.CalledProcessError:
            print(f"Failed to get {image}, retrying in {RETRY_WAIT}s ({i + 1}/{RETRIES})")
            time.sleep(RETRY_WAIT)
    print(f"Failed to get {image}")
    sys.exit(1)


def get_tags(target: str, manifest: dict) -> tuple:
    """Return the two newest date-indexed tags (prev, curr) for a stream.

    The date-indexed tag format (<stream>-YYYYMMDD[.N]) is produced by
    `just generate-build-tags` / `just generate-point`.

    >>> get_tags("44", {"RepoTags": ["44", "44-20261104", "44-20261104.1", "44-20261104.2"]})
    ('44-20261104.1', '44-20261104.2')
    >>> get_tags("44", {"RepoTags": ["44-20261103.1", "44-20261104.1"]})
    ('44-20261103.1', '44-20261104.1')
    """
    tag_pattern = re.compile(rf"^{target}-(\d{{8}})(?:\.(\d+))?$")

    def parse_tag(tag):
        m = tag_pattern.match(tag)
        return (m.group(1), int(m.group(2) or 0)) if m else None

    all_tags = set()
    for tag in manifest["RepoTags"]:
        if tag.endswith(".0"):
            continue
        if parse_tag(tag):
            all_tags.add(tag)

    by_date = defaultdict(list)
    for tag in all_tags:
        date, idx = parse_tag(tag)
        by_date[date].append((idx, tag))

    # Keep every indexed tag (index > 0), then sort by (date, index)
    flattened = [tag for entries in by_date.values() for idx, tag in entries if idx > 0]
    tags = sorted(flattened, key=parse_tag)

    if len(tags) < 2:
        if len(tags) == 1:
            print("Only one indexed tag found; generating a first-release changelog")
            return None, tags[-1]
        print("No current and previous tags found")
        sys.exit(1)

    return tags[-2], tags[-1]


def get_image_digest(image: str, tag: str) -> str:
    """Get image digest using skopeo."""
    result = subprocess.run(
        ["skopeo", "inspect", f"docker://{image}:{tag}"],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)["Digest"]


def get_sbom(image: str, digest: str) -> dict:
    """Fetch the SPDX JSON SBOM referrer attached to an image using ORAS."""
    full_ref = f"{image}@{digest}"

    # Find the SBOM referrer attached to this image
    result = subprocess.run(
        ["oras", "discover", "--format", "json", full_ref],
        capture_output=True,
        text=True,
        check=True,
    )
    discovered = json.loads(result.stdout)

    sbom_digest = None
    for referrer in discovered.get("referrers", []):
        if "spdx+json" in referrer.get("artifactType", ""):
            sbom_digest = referrer["digest"]
            break

    if sbom_digest is None:
        raise RuntimeError(f"No SBOM referrer found for {full_ref}")

    sbom_ref = f"{image}@{sbom_digest}"

    with tempfile.TemporaryDirectory() as tmpdir:
        subprocess.run(
            ["oras", "pull", sbom_ref],
            capture_output=True,
            check=True,
            cwd=tmpdir,
        )

        for fname in os.listdir(tmpdir):
            fpath = os.path.join(tmpdir, fname)
            if fname.endswith(".zst"):
                result = subprocess.run(
                    ["zstd", "-d", fpath, "--stdout"],
                    capture_output=True,
                    check=True,
                )
                return json.loads(result.stdout)
            elif fname.endswith(".json"):
                with open(fpath) as f:
                    return json.load(f)

    raise RuntimeError(f"No SBOM file found after pulling {sbom_ref}")


def parse_sbom_packages(sbom: dict) -> dict:
    """Map rpm package name -> version from an SPDX JSON SBOM."""
    packages = {}
    for artifact in sbom.get("artifacts", []):
        # Only process RPM packages
        if artifact.get("type") != "rpm":
            continue
        name = artifact.get("name")
        version = artifact.get("version")
        if name and version:
            # If we see the same package, keep the one with epoch (more specific)
            if name not in packages or (":" in version and ":" not in packages[name]):
                packages[name] = version
    return packages


def get_packages(tag: str) -> dict:
    """Get the rpm name -> version map for a published tag via its SBOM."""
    print(f"Getting packages for {IMAGE}:{tag} via SBOM")
    full_image = f"{REGISTRY}{IMAGE}"
    digest = get_image_digest(full_image, tag)
    sbom = get_sbom(full_image, digest)
    packages = parse_sbom_packages(sbom)
    print(f"  Found {len(packages)} packages")
    return packages


def get_versions(packages: dict) -> dict:
    """Strip epoch prefix and Fedora suffix from versions (e.g. 1:25.2.7-1.fc44 -> 25.2.7-1)."""
    versions = {}
    for pkg, v in packages.items():
        v = re.sub(EPOCH_PATTERN, "", v)
        v = re.sub(FEDORA_PATTERN, "", v)
        versions[pkg] = v
    return versions


def calculate_changes(prev: dict, curr: dict) -> str:
    """Markdown table rows for packages added / changed / removed."""
    added = []
    changed = []
    removed = []

    blacklist_ver = set([curr.get(v, None) for v in BLACKLIST_VERSIONS])

    for pkg in sorted(set(curr) | set(prev)):
        # Clean up changelog by removing mentioned packages
        if pkg in BLACKLIST_VERSIONS:
            continue
        if pkg in curr and curr.get(pkg, None) in blacklist_ver:
            continue
        if pkg in prev and prev.get(pkg, None) in blacklist_ver:
            continue

        if pkg not in prev:
            added.append(pkg)
        elif pkg not in curr:
            removed.append(pkg)
        elif prev[pkg] != curr[pkg]:
            changed.append(pkg)

        blacklist_ver.add(curr.get(pkg, None))
        blacklist_ver.add(prev.get(pkg, None))

    out = ""
    for pkg in added:
        out += PATTERN_ADD.format(name=pkg, version=curr[pkg])
    for pkg in changed:
        out += PATTERN_CHANGE.format(name=pkg, prev=prev[pkg], new=curr[pkg])
    for pkg in removed:
        out += PATTERN_REMOVE.format(name=pkg, version=prev[pkg])
    return out


def major_packages_table(versions: dict, prev_versions: dict) -> str:
    rows = ["### Major packages", "| Name | Version |", "| --- | --- |"]
    for label, pkg in MAJOR_PACKAGES:
        curr_v = versions.get(pkg, "")
        prev_v = prev_versions.get(pkg, "")
        if not curr_v and not prev_v:
            continue
        if prev_v and prev_v != curr_v:
            rows.append(f"| **{label}** | {PATTERN_PKGREL_CHANGED.format(prev=prev_v, new=curr_v)} |")
        else:
            rows.append(f"| **{label}** | {curr_v or '—'} |")
    return "\n".join(rows) + "\n\n"


def get_commits(prev_manifest, manifest, workdir: str) -> str:
    """Commits between the two builds, from the OCI revision labels."""
    try:
        start = prev_manifest["Labels"]["org.opencontainers.image.revision"]
        finish = manifest["Labels"]["org.opencontainers.image.revision"]
        if not start or not finish or start == "deadbeef" or finish == "deadbeef":
            return ""

        commits = subprocess.run(
            [
                "git",
                "-C",
                workdir,
                "log",
                "--pretty=format:%H|%h|%an|%s",
                f"{start}..{finish}",
            ],
            check=True,
            stdout=subprocess.PIPE,
        ).stdout.decode("utf-8")

        out = ""
        for commit in commits.split("\n"):
            if not commit:
                continue
            parts = commit.split("|")
            if len(parts) < 4:
                continue
            githash, short, author, subject = parts

            if subject.lower().startswith("merge"):
                continue
            if subject.lower().startswith("chore"):
                continue

            out += (
                COMMIT_FORMAT.replace("{short}", short)
                .replace("{subject}", subject)
                .replace("{githash}", githash)
                .replace("{author}", author)
            )

        if out:
            return COMMITS_FORMAT.format(commits=out)
        return ""
    except Exception as e:
        print(f"Failed to get commits:\n{e}")
        return ""


def generate_pretty(target: str, curr: str, manifest: dict, pretty: str) -> str:
    """e.g. 44-20261104.1 -> Verdant 44.20261104.1 (#b1b2d87)"""
    if pretty:
        return pretty

    try:
        finish = manifest["Labels"]["org.opencontainers.image.revision"]
    except Exception as e:
        print(f"Failed to get finish hash:\n{e}")
        finish = ""

    curr_pretty = curr.replace(f"{target}-", "", 1)
    result = f"Verdant {target}.{curr_pretty}"
    if finish and finish != "deadbeef":
        result += f" (#{finish[:7]})"
    return result


def generate_changelog(
    handwritten: str,
    target: str,
    pretty: str,
    workdir: str,
    prev: str,
    curr: str,
    prev_manifest,
    manifest,
) -> tuple:
    curr_packages = get_packages(curr)
    versions = get_versions(curr_packages)

    changes = ""
    prev_packages = None
    if prev:
        # The very first indexed release diffs against an image built before
        # SBOMs were attached — degrade to a major-packages-only changelog
        # instead of failing the release job.
        try:
            prev_packages = get_packages(prev)
        except Exception as e:
            print(f"Could not fetch SBOM for {prev} ({e}); skipping package diff.")
    if prev and prev_packages is not None:
        prev_versions = get_versions(prev_packages)
        changes = get_commits(prev_manifest, manifest, workdir)
        pkg_changes = calculate_changes(prev_versions, versions)
        if pkg_changes:
            changes += PACKAGES_FORMAT.format(changes=pkg_changes)
    else:
        prev_versions = {}

    pretty = generate_pretty(target, curr, manifest, pretty)
    title = CHANGELOG_TITLE.format_map(defaultdict(str, tag=curr, pretty=pretty))

    if prev and prev_packages is not None:
        intro = (
            f"From previous `{target}` version `{prev}` there have been the "
            f"following changes. **One package per new version shown.**"
        )
    elif prev:
        intro = (
            f"Previous version `{prev}` has no attached SBOM, so package-level "
            f"changes could not be computed."
        )
    else:
        intro = "This is the first indexed release of this stream; there is no previous version to compare against."

    changelog = (
        (handwritten if handwritten else "This is an automatically generated changelog.")
        + "\n\n"
        + intro
        + "\n\n"
        + major_packages_table(versions, prev_versions)
        + changes
        + REBASE_SECTION.format(registry=REGISTRY, image=IMAGE, curr=curr)
    )

    return title, changelog


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("target", help="Target tag")
    parser.add_argument("output", help="Output environment file")
    parser.add_argument("changelog", help="Output changelog file")
    parser.add_argument("--pretty", help="Subject for the changelog")
    parser.add_argument("--workdir", help="Git directory for commits")
    parser.add_argument("--handwritten", help="Handwritten changelog")
    args = parser.parse_args()

    # Remove refs/tags, refs/heads, refs/remotes e.g.
    # Tags cannot include / anyway.
    target = args.target.split("/")[-1]

    manifest = get_manifests(target)
    prev, curr = get_tags(target, manifest)
    print(f"Previous tag: {prev}")
    print(f" Current tag: {curr}")

    prev_manifest = get_manifests(prev) if prev else None
    title, changelog = generate_changelog(
        args.handwritten,
        target,
        args.pretty,
        args.workdir,
        prev,
        curr,
        prev_manifest,
        manifest,
    )

    print(f"Changelog:\n# {title}\n{changelog}")
    print(f"\nOutput:\nTITLE=\"{title}\"\nTAG={curr}")

    with open(args.changelog, "w") as f:
        f.write(changelog)

    with open(args.output, "w") as f:
        f.write(f'TITLE="{title}"\nTAG={curr}\n')


if __name__ == "__main__":
    main()
