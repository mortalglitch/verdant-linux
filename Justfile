# Some ideas in this file are derived from Aurora (https://getaurora.dev) —
# a delightful KDE desktop experience for end-users looking for reliability
# and developers looking for the most hassle-free setup. Thanks, Aurora!
set dotenv-filename := "image-template.env"
set dotenv-load
# Pass recipe arguments as shell positional parameters ($1, $2, ...) —
# required by `pin-deps latest` and `release <version>`, which read $1.
set positional-arguments

# Path to the `just` executable, for recursive `just` invocations (used by
# `generate-point` from `generate-build-tags`)
just := just_executable()

export image_name := env_var("IMAGE_NAME")
export repo_organization := env_var("REPO_ORGANIZATION")
export image_desc := env_var("IMAGE_DESC")
export image_keywords := env_var("IMAGE_KEYWORDS")
export image_logo_url := env_var("IMAGE_LOGO_URL")
export default_tag := env_var("DEFAULT_TAG")
export bib_image := env_var("BIB_IMAGE")

alias build-vm := build-qcow2
alias rebuild-vm := rebuild-qcow2
alias run-vm := run-vm-qcow2

[private]
default:
    @just --list

# Verify all Justfile syntax (Justfile + *.just fragments)
[group('Just')]
check:
    #!/usr/bin/env bash
    find . -type f -name "*.just" | while read -r file; do
    	echo "Checking syntax: $file"
    	just --unstable --fmt --check -f $file
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt --check -f Justfile

# Reformat all Justfile syntax (Justfile + *.just fragments)
[group('Just')]
fix:
    #!/usr/bin/env bash
    find . -type f -name "*.just" | while read -r file; do
    	echo "Checking syntax: $file"
    	just --unstable --fmt -f $file
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt -f Justfile || { exit 1; }

# Remove build artifacts (output/, manifests, changelogs).
[group('Utility')]
clean:
    #!/usr/bin/env bash
    set -eoux pipefail
    touch _build
    find *_build* -exec rm -rf {} \;
    rm -f previous.manifest.json
    rm -f changelog.md
    rm -f output.env
    rm -rf output/

# Sudo Clean Repo
[group('Utility')]
[private]
sudo-clean:
    just sudoif just clean

# Run a command as root, escalating via sudo only when needed.
[group('Utility')]
[private]
sudoif command *args:
    #!/usr/bin/env bash
    function sudoif(){
        if [[ "${UID}" -eq 0 ]]; then
            "$@"
        elif [[ "$(command -v sudo)" && -n "${SSH_ASKPASS:-}" ]] && [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
            sudo --askpass "$@" || exit 1
        elif [[ "$(command -v sudo)" ]]; then
            sudo "$@" || exit 1
        else
            exit 1
        fi
    }
    sudoif {{ command }} {{ args }}

# Build the Verdant container image with podman.
#
# Arguments:
#   $target_image - image name to tag the build as (default: $image_name).
#   $tag - tag to apply (default: $default_tag).
#
# With a clean git tree the image is also labeled with the HEAD commit —
# short SHA in org.opencontainers.image.version, full SHA in
# org.opencontainers.image.revision — so release changelogs can attribute
# commits to the exact build.
#
# Usage: just build [image] [tag]
build $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash

    set -euox pipefail

    # --- pinned base image (written by 'just pin-deps') -------------------
    # The build is only reproducible if the base is frozen by digest, so a
    # build without a pin fails loudly instead of silently tracking the live
    # silverblue-main:45 tag.
    if [[ ! -f pins.toml ]]; then
      echo "ERROR: pins.toml not found. Run 'just pin-deps' to create the pin." >&2
      exit 1
    fi
    BASE_DIGEST="$(python3 -c 'import tomllib;print(tomllib.load(open("pins.toml","rb"))["base"]["digest"])' 2>/dev/null || true)"
    if [[ -z "$BASE_DIGEST" ]]; then
      echo "ERROR: pins.toml has no base.digest. Run 'just pin-deps' to create the pin." >&2
      exit 1
    fi
    # A fresh clone without 'git lfs pull' has LFS *pointer* files in
    # vendored_rpms/, not RPMs. Fail loudly instead of baking a broken image.
    if grep -rlq "git-lfs.github.com/spec/v1" vendored_rpms/ 2>/dev/null; then
      echo "ERROR: vendored_rpms/ contains git-lfs pointer files. Run 'git lfs pull' first." >&2
      exit 1
    fi
    BASE_IMAGE="ghcr.io/ublue-os/silverblue-main@${BASE_DIGEST}"
    echo ">> pinned base: ${BASE_IMAGE}"

    BUILD_ARGS=()
    LABELS=()
    if [[ -z "$(git status -s)" ]]; then
        GIT_SHA=$(git rev-parse --short HEAD)
        LABELS+=("--label" "io.artifacthub.package.readme-url=https://raw.githubusercontent.com/{{ repo_organization }}/{{ image_name }}/${GIT_SHA}/README.md")
        LABELS+=("--label" "org.opencontainers.image.documentation=https://raw.githubusercontent.com/{{ repo_organization }}/{{ image_name }}/${GIT_SHA}/README.md")
        LABELS+=("--label" "org.opencontainers.image.source=https://github.com/{{ repo_organization }}/{{ image_name }}/blob/${GIT_SHA}/Containerfile")
        LABELS+=("--label" "org.opencontainers.image.url=https://github.com/{{ repo_organization }}/{{ image_name }}/tree/${GIT_SHA}")
        LABELS+=("--label" "org.opencontainers.image.version={{ default_tag }}.$(date +%Y%m%d)-${GIT_SHA}")
        # Full commit hash for changelog/commit attribution (see .github/changelogs.py)
        LABELS+=("--label" "org.opencontainers.image.revision=$(git rev-parse HEAD)")
    fi

    # ArtifactHub (https://artifacthub.io) metadata — optional, but it gets
    # the image indexed there. Adjust these labels if you want that.
    LABELS+=("--label" "io.artifacthub.package.deprecated=false")
    LABELS+=("--label" "io.artifacthub.package.keywords={{ image_keywords }}")
    LABELS+=("--label" "io.artifacthub.package.license=Apache-2.0")
    LABELS+=("--label" "io.artifacthub.package.logo-url={{ image_logo_url }}")
    LABELS+=("--label" "io.artifacthub.package.prerelease=false")
    LABELS+=("--label" "org.opencontainers.image.created=$(date -u +%Y\-%m\-%d\T%H\:%M\:%S\Z)")
    LABELS+=("--label" "org.opencontainers.image.description={{ image_desc }}")
    LABELS+=("--label" "org.opencontainers.image.title={{ image_name }}")
    LABELS+=("--label" "org.opencontainers.image.vendor={{ repo_organization }}")

    # Run the build.
    PODMAN_BUILD_ARGS=("${BUILD_ARGS[@]}" "${LABELS[@]}" --build-arg BASE_IMAGE="${BASE_IMAGE}" --pull=newer --tag "${target_image}:${tag}" --file Containerfile)

    podman build "${PODMAN_BUILD_ARGS[@]}" .

# Pin the Terra layer: download the current Terra closure into vendored_rpms/
# and record it in pins.toml (+ pins.sha256). This is the ONLY recipe that
# talks to the live Terra repo — everything else builds from the pin.
#
# Run it to adopt a new Umbriel/Noctalia nightly, then `just build && just
# validate-config` before committing the pin.
#
# The download set is computed INSIDE a container based on the pinned base
# image, so "what dnf downloads" == "what build.sh needs" exactly: the closure
# of the Terra packages minus everything the base already provides. The set is
# the Umbriel/Noctalia/greeter stack plus ghostty — a Terra-only convenience
# package build.sh installs that has no Fedora equivalent, so it must be pinned
# too or the build can't install it with the live Terra repo disabled.
#
# Usage:
#   just pin-deps         # pin against the base digest already in pins.toml
#                         # (first run: uses the live silverblue-main:45 tag)
#   just pin-deps latest  # re-pin the base from the live tag (adopt a new base)
#
# Requires: podman (rootless) + python3. To COMMIT the pin you also need
# git-lfs (one-time: `sudo dnf install git-lfs && git lfs install`).
pin-deps *args:
    #!/usr/bin/env bash
    set -euo pipefail
    MODE="${1:-pinned}"
    BASE_TAG="ghcr.io/ublue-os/silverblue-main:45"   # keep in sync with Containerfile ARG
    if [[ "$MODE" == "latest" ]]; then
      BASE_IMAGE="$BASE_TAG"
      echo ">> re-pinning base from live tag: $BASE_IMAGE"
    elif [[ -f pins.toml ]] && [[ -n "$(python3 -c 'import tomllib;print(tomllib.load(open("pins.toml","rb"))["base"]["digest"])' 2>/dev/null || true)" ]]; then
      PINNED_DIGEST="$(python3 -c 'import tomllib;print(tomllib.load(open("pins.toml","rb"))["base"]["digest"])')"
      BASE_IMAGE="ghcr.io/ublue-os/silverblue-main@${PINNED_DIGEST}"
      echo ">> pinning against pinned base: $BASE_IMAGE"
    else
      BASE_IMAGE="$BASE_TAG"
      echo ">> first-time pin: using live tag $BASE_IMAGE"
    fi
    podman pull "$BASE_IMAGE"
    BASE_DIGEST="$(podman image inspect "$BASE_IMAGE" --format json | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["Digest"])')"
    echo ">> base digest: $BASE_DIGEST"
    OUT="$(mktemp -d)"
    trap 'rm -rf "$OUT"' EXIT
    podman run --rm --entrypoint bash \
      -v "$OUT":/out:z \
      -v "$PWD/build_files/pin-terra.repo":/etc/yum.repos.d/verdant-pin-terra.repo:ro,z \
      "$BASE_IMAGE" \
      -c 'set -euo pipefail
          ARCH=$(uname -m)
          dnf5 clean all >/dev/null 2>&1 || true
          dnf5 -y download --resolve --arch="$ARCH" --destdir=/out umbriel-nightly noctalia-nightly noctalia-greeter greetd ghostty
         '
    # collect into the repo (wipe stale pins first)
    mkdir -p vendored_rpms
    find vendored_rpms -name '*.rpm' -delete
    mv "$OUT"/*.rpm vendored_rpms/
    # --- generate pins.toml + pins.sha256 ---
    PINS="pins.toml"; SHAFILE="pins.sha256"
    declare -a FILES NAMES VERSIONS RELEASES ARCHES SHAS
    for f in $(ls vendored_rpms/*.rpm 2>/dev/null | sort); do
      b="$(basename "$f")"
      read -r n v r a < <(rpm -qp --qf '%{NAME} %{VERSION} %{RELEASE} %{ARCH}\n' "$f")
      FILES+=("$b"); NAMES+=("$n"); VERSIONS+=("$v"); RELEASES+=("$r"); ARCHES+=("$a")
      SHAS+=("$(sha256sum "$f" | cut -d' ' -f1)")
    done
    [[ ${#FILES[@]} -gt 0 ]] || { echo "ERROR: no RPMs downloaded into vendored_rpms/" >&2; exit 1; }
    : > "$SHAFILE"
    {
      echo "# Verdant dependency pin — generated by \`just pin-deps\`. Do not edit by hand."
      echo "# The diff of this file between pins is the Terra changelog."
      echo ""
      echo "[base]"
      echo 'image = "ghcr.io/ublue-os/silverblue-main"'
      echo "digest = \"${BASE_DIGEST}\""
      echo "pinned_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
      echo ""
      echo "# Top-level (Terra) packages — the moving targets pinning exists for."
      echo "[top_level]"
    } > "$PINS"
    for i in "${!FILES[@]}"; do
      case "${NAMES[$i]}" in
        umbriel-nightly|noctalia-nightly|noctalia-greeter|greetd|ghostty)
          echo "${NAMES[$i]} = \"${VERSIONS[$i]}-${RELEASES[$i]}\"" >> "$PINS"
          ;;
      esac
    done
    echo "" >> "$PINS"
    for i in "${!FILES[@]}"; do
      echo "${SHAS[$i]}  ${FILES[$i]}" >> "$SHAFILE"
      {
        echo "[[packages]]"
        echo "file = \"${FILES[$i]}\""
        echo "name = \"${NAMES[$i]}\""
        echo "version = \"${VERSIONS[$i]}\""
        echo "release = \"${RELEASES[$i]}\""
        echo "arch = \"${ARCHES[$i]}\""
        echo "sha256 = \"${SHAS[$i]}\""
        echo ""
      } >> "$PINS"
    done
    echo ">> pinned ${#FILES[@]} packages into vendored_rpms/ + pins.toml + pins.sha256"
    echo ">> base: $BASE_DIGEST"
    echo ">> NEXT: just build && just validate-config, then commit pins.toml + vendored_rpms/"

# Cut a release: build a stable, digest-addressable image from the current pin
# and git-tag it. The release is reproducible because it points at a commit
# that carries pins.toml + vendored_rpms/ (LFS) + the base digest.
#
# Usage: just release 1.0.0
release *args:
    #!/usr/bin/env bash
    set -euo pipefail
    VERSION="${1:-}"
    [[ -n "$VERSION" ]] || { echo "usage: just release <version>" >&2; exit 1; }
    [[ -f pins.toml ]] || { echo "no pins.toml — run 'just pin-deps' first" >&2; exit 1; }
    just build "{{ image_name }}" "${VERSION}"
    git tag -a "verdant-${VERSION}" -m "Verdant ${VERSION} — pinned base + Terra layer"
    echo ">> built {{ image_name }}:${VERSION} and tagged verdant-${VERSION}"
    echo ">> push: git push origin ${VERSION} verdant-${VERSION}"

# Rechunk the image with chunkah for smaller incremental updates.
rechunk $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash

    set -xeuo pipefail

    # TODO: pin the chunkah image to a digest once it stabilizes.
    # Rechunking copies the whole image, so it needs roughly double the disk
    # space — on tight runners this can fail if /tmp is small.
    CHUNKAH_CONFIG_FILE="$(mktemp)"

    # Output goes under ./ (not /tmp) so it survives on runners with small
    # /tmp; drop the "./" if you know /tmp has room.
    CHUNKAH_OUTPUT_DIR="$(mktemp -d ./"${target_image}"_chunkah_XXXXXX)"

    trap 'rm -f "${CHUNKAH_CONFIG_FILE}"; rm -rf "${CHUNKAH_OUTPUT_DIR}"' EXIT
    podman inspect "${target_image}:${tag}" > "${CHUNKAH_CONFIG_FILE}"

    podman run --rm \
      --mount=type=image,src="${target_image}:${tag}",target=/chunkah \
      -v "${CHUNKAH_CONFIG_FILE}:/chunkah-config.json:ro,Z" \
      -v "${CHUNKAH_OUTPUT_DIR}:/run/out:Z" \
      quay.io/coreos/chunkah:latest \
      build \
      --verbose \
      --compressed \
      --max-layers 128 \
      --prune /sysroot/ \
      --label ostree.commit- --label ostree.final-diffid- \
      --config /chunkah-config.json \
      --output oci:/run/out/chunked

    CHUNKED_IMAGE="$(podman pull "oci:${CHUNKAH_OUTPUT_DIR}/chunked")"
    podman tag "${CHUNKED_IMAGE}" "${target_image}:${tag}"

# Rechunk the image with rpm-ostree for smaller incremental updates.
ostree-rechunk $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash

    set -xeuo pipefail

    # Use the already-built local image to avoid pulling from a remote registry
    RPM_OSTREE_CHUNKER_IMAGE="localhost/${target_image}:${tag}"

    GRAPHROOT="$(podman info --format '{{ '{{.Store.GraphRoot}}' }}')"

    podman run --rm --pull=never --privileged \
      --mount=type=image,src="${target_image}:${tag}",target=/rpm-ostree \
      --mount=type=bind,src=${GRAPHROOT},target=/run/host-container-storage,rw \
      --mount=type=tmpfs,target=/run/rpm-ostree-storage \
      --entrypoint /usr/bin/rpm-ostree \
      "${RPM_OSTREE_CHUNKER_IMAGE}" \
      compose build-chunked-oci \
      --max-layers 127 \
      --format-version=2 \
      --bootc \
      --rootfs /rpm-ostree \
      --output "containers-storage:[overlay@/run/host-container-storage+/run/rpm-ostree-storage]localhost/${target_image}:${tag}"

# Print the default tag.
[group('Utility')]
generate-default-tag $tag=default_tag:
    #!/usr/bin/env bash
    set -eoux pipefail

    echo "${tag}"

# Get the index point for multiple daily images (private helper)
# Queries the registry for existing <tag>-YYYYMMDD.N tags and returns the next
# index so same-day rebuilds get .2, .3, ... (consumed by `generate-build-tags`;
# the release changelog in .github/changelogs.py diffs the two newest of these).
[private]
generate-point $tag=default_tag:
    #!/usr/bin/env bash
    set -eoux pipefail

    TIMESTAMP="$(date +%Y%m%d)"
    tags="/tmp/{{ image_name }}-tags.json"

    if [[ ! -f ${tags} ]]; then
      skopeo list-tags docker://ghcr.io/{{ repo_organization }}/{{ image_name }} > "${tags}"
    fi

    if [[ $(jq --arg tag "${tag}" --arg timestamp "${TIMESTAMP}" 'any(.Tags[]; contains($tag + "-" + $timestamp))' < "${tags}") == "true" ]]; then
      POINT=$(jq -r --arg tag "${tag}" --arg timestamp "${TIMESTAMP}" \
        '($tag + "-" + $timestamp) as $base | [ .Tags[] | select(startswith($base + ".")) ] | sort_by(split(".")[-1] | tonumber) | .[-1] | if . == null then "1" else split(".")[-1] end' < "${tags}")
      ((POINT++))
    else
      POINT=1
    fi

    echo "${POINT}"

# Generate all tags for this build.
[group('Utility')]
generate-build-tags $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -eoux pipefail

    DATE=$(date +%Y%m%d)
    BUILD_TAGS=()
    if [[ -z "$(git status -s)" ]]; then
        GIT_SHA=$(git rev-parse --short HEAD)
        BUILD_TAGS+=("${tag}-${GIT_SHA}")
        BUILD_TAGS+=("${tag}-${DATE}-${GIT_SHA}")
        BUILD_TAGS+=("${DATE}-${GIT_SHA}")
    fi

    BUILD_TAGS+=("${DATE}")
    BUILD_TAGS+=("${tag}")
    BUILD_TAGS+=("${tag}-${DATE}")
    # Date-indexed tag (<tag>-YYYYMMDD.N) for release changelogs
    POINT=$({{ just }} generate-point "${tag}")
    BUILD_TAGS+=("${tag}-${DATE}.${POINT}")

    echo "${BUILD_TAGS[@]}"

# Apply the generated tags to the built image.
[group('Utility')]
tag-images $target_image=image_name $tag=default_tag tags="":
    #!/usr/bin/env bash
    set -eoux pipefail

    # Resolve the image ID and clear its existing tags.
    IMAGE=$(podman inspect ${target_image}:${tag} | jq -r .[].Id)
    podman untag ${IMAGE}

    # Apply the new tags.
    for tag in {{ tags }}; do
        podman tag $IMAGE "${target_image}:${tag}"
    done

    # Show the result.
    podman images

# Generate a GitHub release changelog by diffing the SBOMs of the two newest
# date-indexed tags (<tag>-YYYYMMDD.N) of the default stream (see
# .github/changelogs.py). Writes ./changelog.md and ./output.env (TITLE=/TAG=).
#
# Requires: skopeo, oras, zstd, python3, and a git checkout with history.
# The SBOM must already be attached to the pushed image (see `attach-sbom`).
#
# just changelogs "optional handwritten notes"
[group('Utility')]
changelogs $handwritten="":
    #!/usr/bin/env bash
    set -eou pipefail
    python3 ./.github/changelogs.py "{{ default_tag }}" ./output.env ./changelog.md --workdir . --handwritten "${handwritten}"

# Extract the built image and generate an SPDX JSON SBOM with syft.
# Run after build (and rechunk) so the SBOM matches the pushed image.
#
# just gen-sbom [image] [tag] [syft_cmd]
[group('Utility')]
gen-sbom $target_image=image_name $tag=default_tag $syft_cmd="syft":
    #!/usr/bin/env bash
    set -eoux pipefail

    OUT_DIR="sbom_out/${target_image}"
    mkdir -p "${OUT_DIR}"

    # Scan an exported rootfs instead of the image itself: scanning the image
    # directly OOMs on GitHub runners (anchore/syft#3800).
    podman container create --replace --name ${target_image} "localhost/${target_image}:${tag}"

    ROOTFS="${OUT_DIR}/rootfs"
    mkdir -p "${ROOTFS}"

    podman export ${target_image} | tar -C "${ROOTFS}" -xf -
    podman container rm ${target_image}

    SBOM="${OUT_DIR}/sbom.json"

    ${syft_cmd} --source-name "${target_image}:${tag}" "${OUT_DIR}" -o syft-json=${SBOM}
    du -sh "${SBOM}"

    rm -rf "${ROOTFS}"

# Attach the generated SBOM to the pushed image as an OCI artifact referrer.
# Run after push; the changelog generator reads it back with `oras discover`.
# Writes the SBOM digest to /tmp/sbom-digestfile.
#
# just attach-sbom [image] [tag] --registry ghcr.io/org --digest sha256:...
[arg("digest", long="digest")]
[arg("registry", long="registry")]
[group('Utility')]
attach-sbom $target_image=image_name $tag=default_tag $registry="" $digest="":
    #!/usr/bin/env bash
    set -eoux pipefail

    if [[ -z "${digest}" || -z "${registry}" ]]; then
        echo "usage: just attach-sbom --registry <registry> --digest <sha256:...>" >&2
        exit 1
    fi

    OUT_DIR="sbom_out/${target_image}"
    SBOM="sbom.json"
    if [[ ! -f "${OUT_DIR}/${SBOM}" ]]; then
        echo "ERROR: ${OUT_DIR}/${SBOM} not found. Run 'just gen-sbom' first." >&2
        exit 1
    fi
    IMAGE="${registry}/${target_image}@${digest}"

    # oras records paths relative to cwd, so run from the SBOM's directory to
    # keep the artifact flat.
    pushd "${OUT_DIR}"

    oras attach \
      --artifact-type application/vnd.spdx+json \
      --annotation filename="${SBOM}" \
      "${IMAGE}" \
      "${SBOM}"

    popd

    SBOM_DIGEST="$(oras discover --format json "${IMAGE}" | jq -r '.referrers[] | select(.artifactType == "application/vnd.spdx+json") | .digest')"

    echo "${SBOM_DIGEST}" > /tmp/sbom-digestfile
    echo "Attached SBOM ${SBOM_DIGEST} to ${IMAGE}"

# Echo the image name (helper for recipe defaults).
[group('Utility')]
[private]
image_name $target_image=image_name:
    #!/usr/bin/env bash
    set -eoux pipefail

    echo "${image_name}"

# Make the built image available in the rootful podman store, which is what
# bootc-image-builder (run via sudo) sees.
#
# - Already root or under sudo: nothing to do.
# - Image in both stores with the same ID: nothing to do.
# - Image in the user store (possibly newer): copy it down via `podman image scp`.
# - Not in the user store: pull it from the registry.
[private]
_rootful_load_image $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -eoux pipefail

    # Self-heal: a previously FAILED run leaves a root-owned ~12G /tmp/podman*
    # staging file in the /tmp tmpfs; the NEXT run then dies with "disk quota
    # exceeded" (tmpfs reports EDQUOT when full). Clear leftovers before any
    # staging, only while no rootful podman is running (the persistent
    # user-pod service is ignored on purpose).
    if [[ "${UID}" -eq 0 ]]; then
        bash -c 'if ! pgrep -x -u 0 podman; then rm -f /tmp/podman*; fi'
    else
        sudo bash -c 'if ! pgrep -x -u 0 podman; then rm -f /tmp/podman*; fi'
    fi

    # Check if already running as root or under sudo
    if [[ -n "${SUDO_USER:-}" || "${UID}" -eq 0 ]]; then
        echo "Already root or running under sudo, no need to load image from user podman."
        exit 0
    fi

    # If the image is already in the rootful store, nothing to load — but only
    # when it matches the user-store image (or the user store has none). A
    # rootful image with a DIFFERENT ID is stale: the user store holds a newer
    # build and must be synced down, or bib bakes the old image.
    ROOTFUL_IMG_ID=$(just sudoif podman images --filter reference="${target_image}:${tag}" --format "'{{ '{{.ID}}' }}'")
    USER_IMG_ID=$(podman images --filter reference="${target_image}:${tag}" --format "'{{ '{{.ID}}' }}'")
    if [[ -n "$ROOTFUL_IMG_ID" && ( -z "$USER_IMG_ID" || "$ROOTFUL_IMG_ID" == "$USER_IMG_ID" ) ]]; then
        echo "Image already present in rootful podman, skipping load."
        exit 0
    fi

    # Try to resolve the image tag using podman inspect
    set +e
    resolved_tag=$(podman inspect -t image "${target_image}:${tag}" | jq -r '.[].RepoTags.[0]')
    return_code=$?
    set -e

    if [[ $return_code -eq 0 ]]; then
        # If the image is found, load it into rootful podman
        ID=$(just sudoif podman images --filter reference="${target_image}:${tag}" --format "'{{ '{{.ID}}' }}'")
        if [[ "$ID" != "$USER_IMG_ID" ]]; then
            # If the image ID is not found or different from user, copy the
            # image from user podman to root podman. The rootful client stages
            # the full image (~12G) in its TMPDIR; a bare `TMPDIR=x` prefix on
            # the sudo line never reaches it, and the /tmp tmpfs is often too
            # small (50% of RAM on live systems) -> "disk quota exceeded".
            # Stage in an on-disk dir by exporting TMPDIR inside the rootful
            # shell (COPYTMP lives in the repo dir, so the repo must be on a
            # real disk).
            COPYTMP=$(mktemp -p "${PWD}" -d -t _build_podman_scp.XXXXXXXXXX)
            sudo bash -c "export TMPDIR='${COPYTMP}'; exec podman image scp ${UID}@localhost::\"${target_image}:${tag}\" root@localhost::\"${target_image}:${tag}\""
            rm -rf "${COPYTMP}"
        fi
    else
        # If the image is not found, pull it from the repository
        just sudoif podman pull "${target_image}:${tag}"
    fi

# Build a bootable disk with bootc-image-builder from a container image.
#
# Arguments:
#   $target_image - image to convert (e.g. localhost/verdant-linux)
#   $tag - image tag
#   $type - output format: qcow2, raw, or iso
# $config - disk config (default: disk_config/disk.toml)
_build-bib $target_image $tag $type $config: (_rootful_load_image target_image tag)
    #!/usr/bin/env bash
    set -euo pipefail

    args="--type ${type} "
    args+="--use-librepo=True "
    args+="--rootfs=btrfs"

    BUILDTMP=$(mktemp -p "${PWD}" -d -t _build-bib.XXXXXXXXXX)

    sudo podman run \
      --rm \
      -it \
      --privileged \
      --pull=newer \
      --net=host \
      --security-opt label=type:unconfined_t \
      -v "$(pwd)/${config}":/config.toml:ro \
      -v "${BUILDTMP}":/output \
      -v /var/lib/containers/storage:/var/lib/containers/storage \
      "${bib_image}" \
      ${args} \
      "${target_image}:${tag}"

    mkdir -p output
    sudo mv -f "${BUILDTMP}"/* output/
    sudo rmdir "${BUILDTMP}"
    sudo chown -R "${USER}:${USER}" output/

# Rebuild the container image, then build a bootable disk from it
# (same arguments as _build-bib).
_rebuild-bib $target_image $tag $type $config: (build target_image tag) && (_build-bib target_image tag type config)

# Build a QCOW2 virtual machine image
[group('Build Virtual Machine Image')]
build-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "qcow2" "disk_config/disk.toml")

# Build a RAW virtual machine image
[group('Build Virtual Machine Image')]
build-raw $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "raw" "disk_config/disk.toml")

# Build an ISO virtual machine image (then brand it as Verdant).
# The ISO is built from the GHCR reference (see _iso-bib) so installed
# systems record ghcr.io/<org>/<image>:<tag> -- not localhost/... -- as the
# update source for `bootc upgrade`.
[group('Build Virtual Machine Image')]
build-iso $target_image=("localhost/" + image_name) $tag=default_tag:
    #!/usr/bin/env bash
    set -euo pipefail

    just _iso-bib "${target_image}" "${tag}"

# Rebuild a QCOW2 virtual machine image
[group('Build Virtual Machine Image')]
rebuild-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: && (_rebuild-bib target_image tag "qcow2" "disk_config/disk.toml")

# Rebuild a RAW virtual machine image
[group('Build Virtual Machine Image')]
rebuild-raw $target_image=("localhost/" + image_name) $tag=default_tag: && (_rebuild-bib target_image tag "raw" "disk_config/disk.toml")

# Rebuild an ISO virtual machine image (then brand it as Verdant).
# Rebuilds the container image first, then builds the ISO from the GHCR
# reference (see _iso-bib) so installed systems update from the registry.
[group('Build Virtual Machine Image')]
rebuild-iso $target_image=("localhost/" + image_name) $tag=default_tag:
    #!/usr/bin/env bash
    set -euo pipefail

    just build "${target_image}" "${tag}"
    just _iso-bib "${target_image}" "${tag}"

# Tag the local image under its GHCR reference in the rootful store, then run
# bootc-image-builder against the GHCR reference. The installer records that
# reference in the ostree origin, which is where `bootc upgrade` on
# ISO-installed systems pulls from -- without this, fresh installs try to
# pull updates from localhost and fail.
_iso-bib $target_image $tag: (_rootful_load_image target_image tag)
    #!/usr/bin/env bash
    set -euo pipefail

    just sudoif podman tag "${target_image}:${tag}" "ghcr.io/${repo_organization}/${image_name}:${tag}"
    just _build-bib "ghcr.io/${repo_organization}/${image_name}" "${tag}" "iso" "disk_config/iso.toml"
    just brand-iso

# Brand the BIB installer ISO as Verdant: volume label + boot menu titles, and
# /IMAGES/PRODUCT.IMG (Anaconda welcome-screen product name + Verdant
# stylesheet/logo over Fedora's). Runs on output/bootiso/install.iso.
[private]
brand-iso:
    #!/usr/bin/env bash
    set -euo pipefail
    just sudoif bash build_files/brand-iso.sh output/bootiso/install.iso 45

# Run a virtual machine with the specified image type and configuration
_run-vm $target_image $tag $type $config:
    #!/usr/bin/env bash
    set -eoux pipefail

    # Determine the image file based on the type
    image_file="output/${type}/disk.${type}"
    if [[ $type == iso ]]; then
        image_file="output/bootiso/install.iso"
    fi

    # Build the image if it does not exist
    if [[ ! -f "${image_file}" ]]; then
        just "build-${type}" "$target_image" "$tag"
    fi

    # Determine an available port to use
    port=8006
    while grep -q :${port} <<< $(ss -tunalp); do
        port=$(( port + 1 ))
    done
    echo "Using Port: ${port}"
    echo "Connect to http://localhost:${port}"

    # Set up the arguments for running the VM
    run_args=()
    run_args+=(--rm --privileged)
    run_args+=(--pull=newer)
    run_args+=(--publish "127.0.0.1:${port}:8006")
    run_args+=(--env "CPU_CORES=4")
    run_args+=(--env "RAM_SIZE=8G")
    run_args+=(--env "DISK_SIZE=64G")
    run_args+=(--env "TPM=Y")
    run_args+=(--env "GPU=Y")
    run_args+=(--device=/dev/kvm)
    run_args+=(--volume "${PWD}/${image_file}":"/boot.${type}")
    run_args+=(docker.io/qemux/qemu)

    # Run the VM and open the browser to connect
    (sleep 30 && xdg-open http://localhost:"$port") &
    podman run "${run_args[@]}"

# Run a virtual machine from a QCOW2 image
[group('Run Virtual Machine')]
run-vm-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: && (_run-vm target_image tag "qcow2" "disk_config/disk.toml")

# Run a virtual machine from a RAW image
[group('Run Virtual Machine')]
run-vm-raw $target_image=("localhost/" + image_name) $tag=default_tag: && (_run-vm target_image tag "raw" "disk_config/disk.toml")

# Run a virtual machine from an ISO
[group('Run Virtual Machine')]
run-vm-iso $target_image=("localhost/" + image_name) $tag=default_tag: && (_run-vm target_image tag "iso" "disk_config/iso.toml")

# Run a virtual machine using systemd-vmspawn
[group('Run Virtual Machine')]
spawn-vm rebuild="0" type="qcow2" ram="6G":
    #!/usr/bin/env bash

    set -euo pipefail

    [ "{{ rebuild }}" -eq 1 ] && echo "Rebuilding the ISO" && just build-vm {{ rebuild }} {{ type }}

    systemd-vmspawn \
      -M "bootc-image" \
      --console=gui \
      --cpus=2 \
      --ram=$(echo {{ ram }}| numfmt --from=iec) \
      --network-user-mode \
      --vsock=false --pass-ssh-key=false \
      -i ./output/**/*.{{ type }}

# Runs shell check on all Bash scripts
lint:
    #!/usr/bin/env bash
    set -eoux pipefail
    # Check if shellcheck is installed
    if ! command -v shellcheck &> /dev/null; then
        echo "shellcheck could not be found. Please install it."
        exit 1
    fi
    # Run shellcheck on all Bash scripts
    find . -iname "*.sh" -type f -exec shellcheck "{}" ';'

# Runs shfmt on all Bash scripts
format:
    #!/usr/bin/env bash
    set -eoux pipefail
    # Check if shfmt is installed
    if ! command -v shfmt &> /dev/null; then
        echo "shfmt could not be found. Please install it."
        exit 1
    fi
    # Run shfmt on all Bash scripts
    find . -iname "*.sh" -type f -exec shfmt --write "{}" ';'

# Validate the shipped Umbriel config against the Umbriel binary inside the
# built image. umbriel-nightly is a moving target — a config-syntax change
# upstream (e.g. the 2026-10-30 switch from `action:arg` to `action arg`)
# otherwise only surfaces on an installed laptop. Run after `just build`.
[group('Utility')]
validate-config $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -euo pipefail

    CFG_DIR="$(pwd)/system_files/usr/share/verdant/configs/umbriel"
    VALIDATE_DIR=$(mktemp -d)
    trap 'rm -rf "${VALIDATE_DIR}"' EXIT
    cp -f "${CFG_DIR}"/*.toml "${VALIDATE_DIR}"/

    podman run --rm --pull=never \
      -v "${VALIDATE_DIR}:/tmp/cfg:ro,Z" \
      "localhost/${target_image}:${tag}" \
      umbriel config validate -c /tmp/cfg/config.toml
