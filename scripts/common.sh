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

export AOSP_MANIFEST_URL="${AOSP_MANIFEST_URL:-https://android.googlesource.com/platform/manifest}"
export AOSP_BRANCH="${AOSP_BRANCH:-android16-release}"
export AOSP_ROOT="${AOSP_ROOT:-/src/aosp}"
export TARGET_PRODUCT="${TARGET_PRODUCT:-aosp_cf_arm64_only_phone}"
export TARGET_VARIANT="${TARGET_VARIANT:-userdebug}"
export JOBS="${JOBS:-0}"
export CCACHE_DIR="${CCACHE_DIR:-/ccache}"
export CCACHE_SIZE="${CCACHE_SIZE:-100G}"
export DIST_DIR="${DIST_DIR:-${REPO_ROOT}/artifacts/dist}"
export ARTIFACTS_DIR="${ARTIFACTS_DIR:-${REPO_ROOT}/artifacts}"
export ARTIFACT_NAME="${ARTIFACT_NAME:-}"
export REPO_SYNC_JOBS="${REPO_SYNC_JOBS:-8}"
export QEMU_CPUS="${QEMU_CPUS:-8}"
export QEMU_MEMORY_MB="${QEMU_MEMORY_MB:-8192}"

readonly DEFAULT_REPO_BIN="${REPO_ROOT}/.cache/bin/repo"
export PATH="${REPO_ROOT}/.cache/bin:${PATH}"

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

ensure_dir() {
  mkdir -p "$1"
}

ensure_repo_tool() {
  if [[ -x "${DEFAULT_REPO_BIN}" ]]; then
    return
  fi

  ensure_dir "$(dirname "${DEFAULT_REPO_BIN}")"
  log "Downloading repo tool"
  curl --fail --location \
    "https://storage.googleapis.com/git-repo-downloads/repo" \
    --output "${DEFAULT_REPO_BIN}"
  chmod +x "${DEFAULT_REPO_BIN}"
}

determine_jobs() {
  if [[ "${JOBS}" =~ ^[0-9]+$ ]] && (( JOBS > 0 )); then
    printf '%s\n' "${JOBS}"
    return
  fi

  nproc
}

default_artifact_name() {
  printf 'android16-%s-%s-qemu-utm\n' "${TARGET_PRODUCT}" "${TARGET_VARIANT}"
}

artifact_name() {
  if [[ -n "${ARTIFACT_NAME}" ]]; then
    printf '%s\n' "${ARTIFACT_NAME}"
    return
  fi

  default_artifact_name
}

product_out_dir() {
  printf '%s/out/target/product/%s\n' "${AOSP_ROOT}" "${TARGET_PRODUCT}"
}

dist_dir_for_product() {
  printf '%s/%s\n' "${DIST_DIR}" "${TARGET_PRODUCT}"
}

normalize_text_file() {
  tr '\0' ' ' < "$1" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}
