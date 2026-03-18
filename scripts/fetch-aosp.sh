#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

require_cmd curl
require_cmd git

ensure_repo_tool
ensure_dir "${AOSP_ROOT}"
cd "${AOSP_ROOT}"

if [[ ! -d "${AOSP_ROOT}/.repo" ]]; then
  log "Initializing AOSP checkout at ${AOSP_ROOT}"
  repo init \
    -u "${AOSP_MANIFEST_URL}" \
    -b "${AOSP_BRANCH}" \
    --no-clone-bundle
else
  log "AOSP checkout already initialized at ${AOSP_ROOT}"
fi

log "Syncing Android source for branch ${AOSP_BRANCH}"
SYNC_ARGS=(
  -c
  -j "${REPO_SYNC_JOBS}"
  --current-branch
  --fail-fast
  --no-clone-bundle
)

if [[ -n "${REPO_SYNC_PROJECTS}" ]]; then
  read -r -a SYNC_PROJECTS <<< "${REPO_SYNC_PROJECTS}"
  log "Using partial repo sync for projects: ${REPO_SYNC_PROJECTS}"
  repo sync "${SYNC_ARGS[@]}" "${SYNC_PROJECTS[@]}"
else
  repo sync "${SYNC_ARGS[@]}"
fi

log "AOSP source sync complete"
