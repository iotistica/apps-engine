# syntax=docker/dockerfile:1

# Embedded-friendly Docker build - optimized for size while keeping essential functionality
# Keeps: containerd, runc, tini, dockercli, compose
# Removes: buildx, dev tools, test infrastructure, debug tools, advanced features
# Architectures: amd64, arm64, arm only (removes ppc64le, s390x, riscv64, 386, windows)

ARG GO_VERSION=1.24.7
ARG BASE_DEBIAN_DISTRO="bookworm"
ARG GOLANG_IMAGE="golang:${GO_VERSION}-${BASE_DEBIAN_DISTRO}"
ARG DOCKER_BUILDTAGS="apparmor seccomp no_btrfs no_cri no_devmapper no_zfs exclude_disk_quota exclude_graphdriver_btrfs exclude_graphdriver_devicemapper exclude_graphdriver_zfs"


# XX_VERSION specifies the version of the xx utility to use.
ARG XX_VERSION=1.7.0

# DOCKERCLI_VERSION is the version of the CLI to install.
ARG DOCKERCLI_VERSION=v28.3.2
ARG DOCKERCLI_REPOSITORY="https://github.com/docker/cli.git"

# COMPOSE_VERSION is the version of compose to install.
ARG COMPOSE_VERSION=v2.38.2

ARG DOCKER_STATIC=1

# cross compilation helper
FROM --platform=$BUILDPLATFORM tonistiigi/xx:${XX_VERSION} AS xx

# dummy stage for unsupported architectures
FROM --platform=$BUILDPLATFORM busybox AS build-dummy
RUN mkdir -p /build
FROM scratch AS binary-dummy
COPY --from=build-dummy /build /build

# base
FROM --platform=$BUILDPLATFORM ${GOLANG_IMAGE} AS base
COPY --from=xx / /
# Disable collecting local telemetry
RUN go telemetry off && [ "$(go telemetry)" = "off" ] || { echo "Failed to disable Go telemetry"; exit 1; }
RUN echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache
RUN apt-get update && apt-get install --no-install-recommends -y file
ENV GOTOOLCHAIN=local

# containerd
FROM base AS containerd-src
WORKDIR /usr/src/containerd
RUN git init . && git remote add origin "https://github.com/containerd/containerd.git"
ARG CONTAINERD_VERSION=v1.7.28
RUN git fetch -q --depth 1 origin "${CONTAINERD_VERSION}" +refs/tags/*:refs/tags/* && git checkout -q FETCH_HEAD

FROM base AS containerd-build
WORKDIR /go/src/github.com/containerd/containerd
ARG TARGETPLATFORM
RUN --mount=type=cache,sharing=locked,id=moby-containerd-aptlib,target=/var/lib/apt \
    --mount=type=cache,sharing=locked,id=moby-containerd-aptcache,target=/var/cache/apt \
        apt-get update && xx-apt-get install -y --no-install-recommends \
            gcc \
            pkg-config
ARG DOCKER_STATIC
RUN --mount=from=containerd-src,src=/usr/src/containerd,rw \
    --mount=type=cache,target=/root/.cache/go-build,id=containerd-build-$TARGETPLATFORM <<EOT
  set -e
  export CC=$(xx-info)-gcc
  export CGO_ENABLED=$([ "$DOCKER_STATIC" = "1" ] && echo "0" || echo "1")
  xx-go --wrap
  make $([ "$DOCKER_STATIC" = "1" ] && echo "STATIC=1") binaries
  xx-verify $([ "$DOCKER_STATIC" = "1" ] && echo "--static") bin/containerd
  xx-verify $([ "$DOCKER_STATIC" = "1" ] && echo "--static") bin/containerd-shim-runc-v2
  mkdir /build
  mv bin/containerd bin/containerd-shim-runc-v2 /build
EOT

FROM containerd-build AS containerd-linux
FROM binary-dummy AS containerd-windows
FROM containerd-${TARGETOS} AS containerd

# dockercli
FROM base AS dockercli
WORKDIR /go/src/github.com/docker/cli
ARG DOCKERCLI_REPOSITORY
ARG DOCKERCLI_VERSION
ARG TARGETPLATFORM
RUN --mount=source=hack/dockerfile/cli.sh,target=/download-or-build-cli.sh \
    --mount=type=cache,id=dockercli-git-$TARGETPLATFORM,sharing=locked,target=./.git \
    --mount=type=cache,target=/root/.cache/go-build,id=dockercli-build-$TARGETPLATFORM \
        rm -f ./.git/*.lock \
     && /download-or-build-cli.sh ${DOCKERCLI_VERSION} ${DOCKERCLI_REPOSITORY} /build \
     && /build/docker --version \
     && /build/docker completion bash >/completion.bash

# runc
FROM base AS runc-src
WORKDIR /usr/src/runc
RUN git init . && git remote add origin "https://github.com/opencontainers/runc.git"
ARG RUNC_VERSION=v1.3.0
RUN git fetch -q --depth 1 origin "${RUNC_VERSION}" +refs/tags/*:refs/tags/* && git checkout -q FETCH_HEAD

FROM base AS runc-build
WORKDIR /go/src/github.com/opencontainers/runc
ARG TARGETPLATFORM
RUN --mount=type=cache,sharing=locked,id=moby-runc-aptlib,target=/var/lib/apt \
    --mount=type=cache,sharing=locked,id=moby-runc-aptcache,target=/var/cache/apt \
        apt-get update && xx-apt-get install -y --no-install-recommends \
            gcc \
            libc6-dev \
            libseccomp-dev \
            pkg-config
ARG DOCKER_STATIC
RUN --mount=from=runc-src,src=/usr/src/runc,rw \
    --mount=type=cache,target=/root/.cache/go-build,id=runc-build-$TARGETPLATFORM <<EOT
  set -e
  xx-go --wrap
  CGO_ENABLED=1 make "$([ "$DOCKER_STATIC" = "1" ] && echo "static" || echo "runc")"
  xx-verify $([ "$DOCKER_STATIC" = "1" ] && echo "--static") runc
  mkdir /build
  mv runc /build/
EOT

FROM runc-build AS runc-linux
FROM binary-dummy AS runc-windows
FROM runc-${TARGETOS} AS runc

# tini
FROM base AS tini-src
WORKDIR /usr/src/tini
RUN git init . && git remote add origin "https://github.com/krallin/tini.git"
ARG TINI_VERSION=v0.19.0
RUN git fetch -q --depth 1 origin "${TINI_VERSION}" +refs/tags/*:refs/tags/* && git checkout -q FETCH_HEAD

FROM base AS tini-build
WORKDIR /go/src/github.com/krallin/tini
RUN --mount=type=cache,sharing=locked,id=moby-tini-aptlib,target=/var/lib/apt \
    --mount=type=cache,sharing=locked,id=moby-tini-aptcache,target=/var/cache/apt \
        apt-get update && apt-get install -y --no-install-recommends cmake
ARG TARGETPLATFORM
RUN --mount=type=cache,sharing=locked,id=moby-tini-aptlib,target=/var/lib/apt \
    --mount=type=cache,sharing=locked,id=moby-tini-aptcache,target=/var/cache/apt \
        xx-apt-get install -y --no-install-recommends \
            gcc \
            libc6-dev \
            pkg-config
RUN --mount=from=tini-src,src=/usr/src/tini,rw \
    --mount=type=cache,target=/root/.cache/go-build,id=tini-build-$TARGETPLATFORM <<EOT
  set -e
  CC=$(xx-info)-gcc cmake .
  make tini-static
  xx-verify --static tini-static
  mkdir /build
  mv tini-static /build/docker-init
EOT

FROM tini-build AS tini-linux
FROM binary-dummy AS tini-windows
FROM tini-${TARGETOS} AS tini

# compose (keep this for embedded use)
FROM docker/compose-bin:${COMPOSE_VERSION} AS compose

# embedded development stage - minimal but functional
FROM base AS dev-embedded
RUN groupadd -r docker
RUN useradd --create-home --gid docker unprivilegeduser \
 && mkdir -p /home/unprivilegeduser/.local/share/docker \
 && chown -R unprivilegeduser /home/unprivilegeduser

# Set dev environment as safe git directory
RUN git config --global --add safe.directory $GOPATH/src/github.com/docker/docker

# Install only essential packages for embedded environment
RUN --mount=type=cache,sharing=locked,id=moby-dev-aptlib,target=/var/lib/apt \
    --mount=type=cache,sharing=locked,id=moby-dev-aptcache,target=/var/cache/apt \
        apt-get update && apt-get install -y --no-install-recommends \
            bash-completion \
            iptables \
            iproute2 \
            jq \
            nano \
            pigz \
            sudo \
            vim-common \
            xfsprogs \
            xz-utils

# Install essential build dependencies
RUN --mount=type=cache,sharing=locked,id=moby-dev-aptlib,target=/var/lib/apt \
    --mount=type=cache,sharing=locked,id=moby-dev-aptcache,target=/var/cache/apt \
        apt-get update && apt-get install --no-install-recommends -y \
            gcc \
            pkg-config \
            libseccomp-dev

# Copy essential binaries only
COPY --link --from=tini          /build/ /usr/local/bin/
COPY --link --from=runc          /build/ /usr/local/bin/
COPY --link --from=containerd    /build/ /usr/local/bin/
COPY --link --from=dockercli     /build/ /usr/local/cli
COPY --link --from=dockercli     /completion.bash /etc/bash_completion.d/docker
COPY --link --from=compose       /docker-compose /usr/libexec/docker/cli-plugins/docker-compose

# Set up Docker configuration
COPY --link hack/dockerfile/etc/docker/  /etc/docker/

ENV PATH=/usr/local/cli:$PATH
ENV CONTAINERD_ADDRESS=/run/docker/containerd/containerd.sock
ENV CONTAINERD_NAMESPACE=moby
WORKDIR /go/src/github.com/docker/docker
VOLUME /var/lib/docker
VOLUME /home/unprivilegeduser/.local/share/docker

# Use docker-in-docker script for nested containers
ENTRYPOINT ["hack/dind"]

FROM base AS build
WORKDIR /go/src/github.com/docker/docker
ENV CGO_ENABLED=1
RUN --mount=type=cache,sharing=locked,id=moby-build-aptlib,target=/var/lib/apt \
    --mount=type=cache,sharing=locked,id=moby-build-aptcache,target=/var/cache/apt \
        apt-get update && apt-get install --no-install-recommends -y \
            clang \
            lld \
            llvm
ARG TARGETPLATFORM
RUN --mount=type=cache,sharing=locked,id=moby-build-aptlib,target=/var/lib/apt \
    --mount=type=cache,sharing=locked,id=moby-build-aptcache,target=/var/cache/apt \
        xx-apt-get install --no-install-recommends -y \
            gcc \
            libc6-dev \
            libseccomp-dev \
            pkg-config
ARG DOCKER_BUILDTAGS
ARG DOCKER_DEBUG
ARG DOCKER_GITCOMMIT=HEAD
ARG DOCKER_LDFLAGS
ARG DOCKER_STATIC
ARG VERSION
ARG PLATFORM
ARG PRODUCT
ARG DEFAULT_PRODUCT_LICENSE
ARG PACKAGER_NAME
ENV PREFIX=/tmp
RUN <<EOT
  # Configure linker for arm64
  if [ "$(xx-info arch)" = "arm64" ]; then
    XX_CC_PREFER_LINKER=ld xx-clang --setup-target-triple
  fi
EOT
RUN --mount=type=bind,target=.,rw \
    --mount=type=cache,target=/root/.cache/go-build,id=moby-build-$TARGETPLATFORM <<EOT
  set -e
  target=$([ "$DOCKER_STATIC" = "1" ] && echo "binary" || echo "dynbinary")
  xx-go --wrap
  PKG_CONFIG=$(xx-go env PKG_CONFIG) ./hack/make.sh $target
  xx-verify $([ "$DOCKER_STATIC" = "1" ] && echo "--static") /tmp/bundles/${target}-daemon/dockerd$([ "$(xx-info os)" = "windows" ] && echo ".exe")
  [ "$(xx-info os)" != "linux" ] || xx-verify $([ "$DOCKER_STATIC" = "1" ] && echo "--static") /tmp/bundles/${target}-daemon/docker-proxy
  mkdir /build
  mv /tmp/bundles/${target}-daemon/* /build/
EOT

# binary output
FROM scratch AS binary
COPY --from=build /build/ /

# embedded complete package - essential components only
FROM scratch AS embedded
COPY --link --from=tini          /build/ /
COPY --link --from=runc          /build/ /
COPY --link --from=containerd    /build/ /
COPY --link --from=build         /build/ /
COPY --link --from=compose       /docker-compose /docker-compose


# embedded development container - optimized for size but functional
FROM dev-embedded AS dev-embedded-final
COPY --link . .
