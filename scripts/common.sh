#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

load_env_defaults() {
  local env_file="$1"
  local line key value

  [[ -f "${env_file}" ]] || return

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^[[:space:]]*$ ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue

    if [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"

      if [[ "${value}" =~ ^\"(.*)\"$ ]]; then
        value="${BASH_REMATCH[1]}"
      elif [[ "${value}" =~ ^\'(.*)\'$ ]]; then
        value="${BASH_REMATCH[1]}"
      fi

      if [[ -z "${!key+x}" ]]; then
        printf -v "${key}" '%s' "${value}"
      fi
    fi
  done < "${env_file}"
}

if [[ -f "${REPO_ROOT}/.env" ]]; then
  load_env_defaults "${REPO_ROOT}/.env"
elif [[ -f "${REPO_ROOT}/.env.example" ]]; then
  load_env_defaults "${REPO_ROOT}/.env.example"
fi

export AOSP_MANIFEST_URL="${AOSP_MANIFEST_URL:-https://android.googlesource.com/platform/manifest}"
export AOSP_BRANCH="${AOSP_BRANCH:-android16-release}"
export AOSP_ROOT="${AOSP_ROOT:-${REPO_ROOT}/work/aosp}"
export TARGET_PRODUCT="${TARGET_PRODUCT:-aosp_trout_arm64}"
export TARGET_RELEASE="${TARGET_RELEASE:-trunk_staging}"
export TARGET_VARIANT="${TARGET_VARIANT:-userdebug}"
export JOBS="${JOBS:-0}"
export CCACHE_DIR="${CCACHE_DIR:-${REPO_ROOT}/work/ccache}"
export CCACHE_SIZE="${CCACHE_SIZE:-100G}"
export DIST_DIR="${DIST_DIR:-${REPO_ROOT}/artifacts/dist}"
export ARTIFACTS_DIR="${ARTIFACTS_DIR:-${REPO_ROOT}/artifacts}"
export ARTIFACT_NAME="${ARTIFACT_NAME:-}"
export REPO_SYNC_JOBS="${REPO_SYNC_JOBS:-8}"
export REPO_SYNC_PROJECTS="${REPO_SYNC_PROJECTS:-}"
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
  if [[ -n "${TARGET_RELEASE}" ]]; then
    printf 'android16-%s-%s-%s-qemu-utm\n' "${TARGET_PRODUCT}" "${TARGET_RELEASE}" "${TARGET_VARIANT}"
    return
  fi

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

lunch_combo() {
  if [[ -n "${TARGET_RELEASE}" ]]; then
    printf '%s-%s-%s\n' "${TARGET_PRODUCT}" "${TARGET_RELEASE}" "${TARGET_VARIANT}"
    return
  fi

  printf '%s-%s\n' "${TARGET_PRODUCT}" "${TARGET_VARIANT}"
}
