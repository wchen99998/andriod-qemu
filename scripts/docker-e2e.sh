#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"
elif [[ -f "${REPO_ROOT}/.env.example" ]]; then
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env.example"
fi

AOSP_ROOT="${AOSP_ROOT:-/src/aosp}"
CCACHE_DIR="${CCACHE_DIR:-/ccache}"
DIST_DIR="${DIST_DIR:-/workspace/artifacts/dist}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-/workspace/artifacts}"

IMAGE_NAME="android16-aosp-qemu-utm-builder"

mkdir -p "${REPO_ROOT}/work/aosp" "${REPO_ROOT}/work/ccache" "${REPO_ROOT}/artifacts"

docker build -t "${IMAGE_NAME}" -f "${REPO_ROOT}/docker/Dockerfile" "${REPO_ROOT}"

docker run --rm -it \
  -v "${REPO_ROOT}:/workspace" \
  -v "${REPO_ROOT}/work/aosp:${AOSP_ROOT}" \
  -v "${REPO_ROOT}/work/ccache:${CCACHE_DIR}" \
  -e AOSP_ROOT="${AOSP_ROOT}" \
  -e CCACHE_DIR="${CCACHE_DIR}" \
  -e DIST_DIR="${DIST_DIR}" \
  -e ARTIFACTS_DIR="${ARTIFACTS_DIR}" \
  -e AOSP_MANIFEST_URL="${AOSP_MANIFEST_URL:-https://android.googlesource.com/platform/manifest}" \
  -e AOSP_BRANCH="${AOSP_BRANCH:-android16-release}" \
  -e TARGET_PRODUCT="${TARGET_PRODUCT:-aosp_cf_arm64_only_phone}" \
  -e TARGET_VARIANT="${TARGET_VARIANT:-userdebug}" \
  -e JOBS="${JOBS:-0}" \
  -e REPO_SYNC_JOBS="${REPO_SYNC_JOBS:-8}" \
  -e CCACHE_SIZE="${CCACHE_SIZE:-100G}" \
  -e ARTIFACT_NAME="${ARTIFACT_NAME:-}" \
  -e QEMU_CPUS="${QEMU_CPUS:-8}" \
  -e QEMU_MEMORY_MB="${QEMU_MEMORY_MB:-8192}" \
  "${IMAGE_NAME}" \
  /workspace/scripts/e2e.sh
