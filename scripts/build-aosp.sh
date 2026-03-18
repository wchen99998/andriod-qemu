#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

require_cmd bash
require_cmd ccache

[[ -d "${AOSP_ROOT}/build" ]] || die "AOSP checkout not found at ${AOSP_ROOT}. Run fetch-aosp.sh first."

BUILD_JOBS="$(determine_jobs)"
PRODUCT_OUT="$(product_out_dir)"
PRODUCT_DIST_DIR="$(dist_dir_for_product)"

ensure_dir "${CCACHE_DIR}"
ensure_dir "${PRODUCT_DIST_DIR}"

export USE_CCACHE=1
export CCACHE_EXEC="$(command -v ccache)"

ccache -M "${CCACHE_SIZE}" >/dev/null

cd "${AOSP_ROOT}"

log "Building ${TARGET_PRODUCT}-${TARGET_VARIANT} with ${BUILD_JOBS} jobs"

# DIST_DIR is scoped to the product so repeated runs with different products do
# not overwrite one another.
DIST_DIR="${PRODUCT_DIST_DIR}" \
  bash -lc "
    set -euo pipefail
    source build/envsetup.sh
    lunch ${TARGET_PRODUCT}-${TARGET_VARIANT}
    m -j${BUILD_JOBS} droid dist
  "

[[ -d "${PRODUCT_OUT}" ]] || die "Product output directory not found: ${PRODUCT_OUT}"

log "Build complete for ${TARGET_PRODUCT}-${TARGET_VARIANT}"
