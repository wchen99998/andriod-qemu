#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

if command -v sudo >/dev/null 2>&1; then
  SUDO=(sudo)
else
  SUDO=()
fi

APT_PACKAGES=(
  bc
  bison
  build-essential
  ccache
  curl
  dosfstools
  e2fsprogs
  file
  flex
  g++-multilib
  gcc-multilib
  gdisk
  git
  git-lfs
  gnupg
  gperf
  imagemagick
  jq
  lib32readline-dev
  lib32z1-dev
  libdw-dev
  libelf-dev
  libgl1-mesa-dev
  liblz4-tool
  libsdl1.2-dev
  libssl-dev
  libxml2
  libxml2-utils
  lzop
  openjdk-17-jdk
  pngcrush
  protobuf-compiler
  python-is-python3
  python3
  python3-protobuf
  qemu-utils
  rsync
  schedtool
  squashfs-tools
  unzip
  xz-utils
  xsltproc
  zip
  zlib1g-dev
  zstd
)

log "Installing host dependencies for native AOSP builds"
"${SUDO[@]}" apt-get update
"${SUDO[@]}" apt-get install -y "${APT_PACKAGES[@]}"

git lfs install
ensure_repo_tool

log "Host dependency installation complete"
