# Base image, pinned by digest. `just build` reads the digest from pins.toml
# (written by `just pin-deps`) and passes it as --build-arg BASE_IMAGE, freezing
# the Fedora base so the Terra layer and the base never drift apart. The plain
# tag is only a fallback so this file parses standalone; a real build always
# overrides it with the pinned digest. Declared GLOBALLY (before any FROM) so it
# is visible to the main FROM below — a stage-scoped ARG cannot feed a FROM.
ARG BASE_IMAGE=ghcr.io/ublue-os/silverblue-main:44

# Homebrew: official uBlue image (Bluefin pattern) — merged into the ctx stage
FROM ghcr.io/ublue-os/brew:latest AS brew

# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files
COPY vendored_rpms /vendored_rpms
COPY pins.toml /pins.toml
COPY pins.sha256 /pins.sha256
COPY --from=brew /system_files /system_files

# Base Image — pinned by digest (see the global ARG BASE_IMAGE at the top)
FROM ${BASE_IMAGE}

### MODIFICATIONS
## make modifications desired in your image and install packages by modifying the build.sh script
## the following RUN directive does all the things required to run "build.sh" as recommended.

RUN --mount=type=bind,from=ctx,source=/,target=/ctx     --mount=type=cache,dst=/var/cache     --mount=type=cache,dst=/var/log     --mount=type=tmpfs,dst=/tmp     /ctx/build.sh

### LINTING
## Verify final image and contents are correct.
RUN bootc container lint
