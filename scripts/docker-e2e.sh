#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

IMAGE_NAME="android16-aosp-qemu-utm-builder"

mkdir -p "${REPO_ROOT}/work/aosp" "${REPO_ROOT}/work/ccache" "${REPO_ROOT}/artifacts"

docker build -t "${IMAGE_NAME}" -f "${REPO_ROOT}/docker/Dockerfile" "${REPO_ROOT}"

docker run --rm -it \
  -v "${REPO_ROOT}:/workspace" \
  -v "${REPO_ROOT}/work/aosp:/workspace/work/aosp" \
  -v "${REPO_ROOT}/work/ccache:/workspace/work/ccache" \
  -e AOSP_ROOT="/workspace/work/aosp" \
  -e CCACHE_DIR="/workspace/work/ccache" \
  -e DIST_DIR="/workspace/artifacts/dist" \
  -e ARTIFACTS_DIR="/workspace/artifacts" \
  -e AOSP_MANIFEST_URL="${AOSP_MANIFEST_URL:-https://android.googlesource.com/platform/manifest}" \
  -e AOSP_BRANCH="${AOSP_BRANCH:-android16-release}" \
  -e TARGET_PRODUCT="${TARGET_PRODUCT:-aosp_trout_arm64}" \
  -e TARGET_RELEASE="${TARGET_RELEASE:-trunk_staging}" \
  -e TARGET_VARIANT="${TARGET_VARIANT:-userdebug}" \
  -e JOBS="${JOBS:-0}" \
  -e REPO_SYNC_JOBS="${REPO_SYNC_JOBS:-8}" \
  -e CCACHE_SIZE="${CCACHE_SIZE:-100G}" \
  -e ARTIFACT_NAME="${ARTIFACT_NAME:-}" \
  -e QEMU_CPUS="${QEMU_CPUS:-8}" \
  -e QEMU_MEMORY_MB="${QEMU_MEMORY_MB:-8192}" \
  "${IMAGE_NAME}" \
  /workspace/scripts/e2e.sh
